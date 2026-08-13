"""粒度再計算ジョブ（T-21 / Container Apps Job）。

docs/01 §4.3。新しい粒度バージョンに全投稿を通し直し、`active` を差し替えられる
状態まで持っていく。**差し替えそのものはやらない**（docs/01 §4.2 の検証を人が見て
から決めること）。

    # 新しい粒度バージョンを丸ごと作り直す（draft / shadow が対象）
    python -m jobs.recalc_grain --grain-version-id 2

    # 途中で切り上げる。状態は残るので、同じコマンドで続きから進む
    python -m jobs.recalc_grain --grain-version-id 2 --max-batches 10

    # 配信中バージョンの②だけ直す（DBSCAN昇格で紐付けが変わった後）
    python -m jobs.recalc_grain --rarity-only

`--rarity-only` は T-16 からの持ち越しを回収するためのもの。昇格が投稿を
張り替えると post_rarity_scores と spot_facet_stats が実態とずれるので、
昇格バッチの後にこれを回す。スポットは動かさないので配信中でも安全。
"""

from __future__ import annotations

import argparse
import json
import sys

from core import db, grain, recalc


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="粒度バージョンを再計算する")
    parser.add_argument(
        "--grain-version-id", type=int, default=None,
        help="対象の粒度バージョン。--rarity-only では省略すると active",
    )
    parser.add_argument("--batch-size", type=int, default=5000)
    parser.add_argument(
        "--max-batches", type=int, default=None,
        help="assign フェーズを途中で切り上げる。状態は残るので再開できる",
    )
    parser.add_argument("--poi-extract-version-id", type=int, default=None)
    parser.add_argument(
        "--rarity-only", action="store_true",
        help="②とファセット統計だけ作り直す（スポットは動かさない）",
    )
    parser.add_argument("--dsn", default=None)
    args = parser.parse_args(argv)

    conn = db.connect(args.dsn)
    try:
        with conn.cursor() as cur:
            if args.rarity_only:
                target = args.grain_version_id
                if target is None:
                    target = grain.load_active(cur).id
                payload = {
                    "mode": "rarity-only",
                    "grain_version_id": target,
                    "rarity_recomputed": recalc.recompute_rarity(cur, target),
                }
            else:
                if args.grain_version_id is None:
                    parser.error("--grain-version-id は必須（配信中の作り直しはできない）")
                payload = recalc.run_to_completion(
                    cur,
                    args.grain_version_id,
                    batch_size=args.batch_size,
                    max_batches=args.max_batches,
                    poi_extract_version_id=args.poi_extract_version_id,
                )
                payload["mode"] = "full"
        conn.commit()
    except Exception as exc:  # 失敗を状態に残してから落とす
        conn.rollback()
        if not args.rarity_only and args.grain_version_id is not None:
            with conn.cursor() as cur:
                cur.execute(
                    """
                    UPDATE grain_recalc_runs SET last_error = %s, updated_at = now()
                     WHERE grain_version_id = %s AND completed_at IS NULL
                    """,
                    (str(exc), args.grain_version_id),
                )
            conn.commit()
        raise
    finally:
        conn.close()

    print(json.dumps(payload, ensure_ascii=False, indent=2, default=str))

    if payload.get("phase") == "done":
        print(
            "\n次にやること: docs/01 §4.2 の差分レポートを確認してから "
            "active を差し替える。**このジョブは差し替えない。**",
            file=sys.stderr,
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
