"""DBSCAN昇格バッチ（T-16 / Container Apps Job）。

docs/01 §1.3 の夜間バッチ。暫定セルスポットに溜まった投稿を精査し、
密度で固まっている部分を独自スポットに切り出す。

    python -m jobs.promote_clusters
    python -m jobs.promote_clusters --limit 500 --dry-run
    python -m jobs.promote_clusters --spot-id <uuid>     # 1セルだけ

**張り替えた投稿の希少性②は古いままになる。** 同一粒度バージョン内でスポットが
変わるので、`post_rarity_scores` と `spot_facet_stats` が実態とずれる
（docs/01 §4.3）。再計算は T-21 の担当なので、ここでは対象件数を出力するだけにして、
黙って進めない。
"""

from __future__ import annotations

import argparse
import json
import sys

from core import clusters, db, grain


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="暫定セルスポットを独自スポットに昇格させる")
    parser.add_argument("--spot-id", default=None, help="指定した暫定セルだけを精査する")
    parser.add_argument("--limit", type=int, default=100, help="1回の実行で見るセルの数")
    parser.add_argument("--grain-version-id", type=int, default=None)
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="判定だけ行い、昇格は確定させない（ロールバックする）",
    )
    parser.add_argument("--dsn", default=None)
    args = parser.parse_args(argv)

    conn = db.connect(args.dsn)
    try:
        with conn.cursor() as cur:
            g = (
                grain.load(cur, args.grain_version_id)
                if args.grain_version_id is not None
                else grain.load_active(cur)
            )

            if args.spot_id:
                promotions = clusters.promote_cell_spot(cur, g, args.spot_id)
            else:
                promotions = clusters.promote_pending(cur, g, args.limit)

            payload = {
                "grain_version": g.code,
                "dry_run": args.dry_run,
                "promoted": [
                    {
                        "cluster_spot_id": str(p.cluster_spot_id),
                        "spot_identity_id": str(p.cluster_identity_id),
                        "moved_post_count": p.moved_post_count,
                        "distinct_author_count": p.distinct_author_count,
                        # 「命名権」の通知先。通知そのものは T-27
                        "naming_rights_user_id": str(p.top_contributor_id),
                        "lineage_op": p.lineage_op,
                    }
                    for p in promotions
                ],
                "promoted_count": len(promotions),
                # 張り替えた投稿は希少性②の再計算対象になる（T-21）
                "posts_needing_rarity_recalc": sum(p.moved_post_count for p in promotions),
            }

        if args.dry_run:
            conn.rollback()
        else:
            conn.commit()
    finally:
        conn.close()

    print(json.dumps(payload, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
