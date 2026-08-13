"""粒度再計算ジョブ（T-21）。

docs/01-spot-granularity.md §4.3。新しい粒度バージョンに全投稿を通し直し、
最後に `active` ポインタを差し替えられる状態まで持っていく（Blue-Green の
「Green を作る」側）。差し替えそのものは運用の判断なので、ここではやらない。

## 途中で落ちる前提

`grain_recalc_runs` にフェーズとカーソルを永続化する。同じコマンドを再実行すれば
続きから進む。docs/01 §4.3 の「冪等性が要件」はこれで満たす。

## フェーズ

    assign  → promote → lineage → rarity → ranking → done

`lineage` と `rarity` を assign から分けているのは、**どちらも全件が揃わないと
確定できない**ため。

- `split`（1つの親が2つに割れたか）は投稿の分布を見ないと決まらない（§8.3）
- 「初」判定は撮影時刻順の逐次処理で、ファセット統計を作りながらでないと出せない
"""

from __future__ import annotations

from dataclasses import dataclass
from uuid import UUID

import psycopg

from core import clusters, grain as grain_mod, spots

__all__ = ["Run", "start_or_resume", "run_to_completion", "recompute_rarity"]

PHASES = ("assign", "promote", "lineage", "rarity", "ranking", "done")


@dataclass
class Run:
    id: int
    grain_version_id: int
    poi_extract_version_id: int | None
    phase: str
    cursor_post_id: UUID | None
    processed_count: int


def _load_run(cur: psycopg.Cursor, run_id: int) -> Run:
    cur.execute(
        """
        SELECT id, grain_version_id, poi_extract_version_id, phase,
               cursor_post_id, processed_count
          FROM grain_recalc_runs WHERE id = %s
        """,
        (run_id,),
    )
    return Run(*cur.fetchone())


def start_or_resume(
    cur: psycopg.Cursor,
    grain_version_id: int,
    poi_extract_version_id: int | None = None,
) -> Run:
    """未完了のランがあれば拾い、無ければ始める。

    多重起動しても1本しか走らない（`grain_recalc_open_uix`）。
    抽出バージョンを省略したときは、**開始時点の有効な抽出をランに焼き付ける**。
    途中で抽出が差し替わっても、同じランの中では同じPOIを見る（docs/06 §4.2）。
    """
    cur.execute(
        """
        SELECT id FROM grain_recalc_runs
         WHERE grain_version_id = %s AND completed_at IS NULL
        """,
        (grain_version_id,),
    )
    row = cur.fetchone()
    if row is not None:
        return _load_run(cur, row[0])

    if poi_extract_version_id is None:
        cur.execute("SELECT id FROM poi_extract_versions WHERE is_active")
        row = cur.fetchone()
        poi_extract_version_id = row[0] if row else None

    cur.execute(
        """
        INSERT INTO grain_recalc_runs (grain_version_id, poi_extract_version_id)
        VALUES (%s, %s) RETURNING id
        """,
        (grain_version_id, poi_extract_version_id),
    )
    return _load_run(cur, cur.fetchone()[0])


def _advance(cur: psycopg.Cursor, run: Run, phase: str) -> None:
    cur.execute(
        """
        UPDATE grain_recalc_runs
           SET phase = %s::recalc_phase, updated_at = now(),
               completed_at = CASE WHEN %s = 'done' THEN now() END
         WHERE id = %s
        """,
        (phase, phase, run.id),
    )
    run.phase = phase


# ---------------------------------------------------------------------------
# 各フェーズ
# ---------------------------------------------------------------------------


def _assign_batch(cur: psycopg.Cursor, run: Run, grain, batch_size: int) -> int:
    """手順2。投稿を id 昇順で解決してカーソルを進める。

    id 昇順にしているのは、途中で新しい投稿が入っても取りこぼさないため
    （撮影時刻順だと、後から古い写真が投稿されたときカーソルの後ろに現れる）。
    """
    cur.execute(
        """
        SELECT id FROM posts
         WHERE location IS NOT NULL
           AND (%s::uuid IS NULL OR id > %s::uuid)
         ORDER BY id
         LIMIT %s
        """,
        (run.cursor_post_id, run.cursor_post_id, batch_size),
    )
    post_ids = [row[0] for row in cur.fetchall()]
    if not post_ids:
        return 0

    for post_id in post_ids:
        spots.bind_post(
            cur,
            post_id,
            grain_version_id=grain.id,
            extract_version_id=run.poi_extract_version_id,
        )

    run.cursor_post_id = post_ids[-1]
    run.processed_count += len(post_ids)
    cur.execute(
        """
        UPDATE grain_recalc_runs
           SET cursor_post_id = %s, processed_count = %s, updated_at = now()
         WHERE id = %s
        """,
        (run.cursor_post_id, run.processed_count, run.id),
    )
    return len(post_ids)


def _promote(cur: psycopg.Cursor, run: Run, grain) -> int:
    """手順4。全セルに対して DBSCAN 昇格を回す。

    昇格は紐付けを張り替えるので、**必ず rarity フェーズより前に済ませる**。
    順序を逆にすると、張り替え前のスポットで計算した②が残る。
    """
    total = 0
    while True:
        promotions = clusters.promote_pending(cur, grain, limit=200)
        if not promotions:
            break
        total += len(promotions)
    return total


def _finalize_lineage(cur: psycopg.Cursor, run: Run, grain) -> int:
    """`split` の確定（docs/01 §8.3）。比較元は現在の active。"""
    cur.execute("SELECT id FROM spot_grain_versions WHERE status = 'active'")
    row = cur.fetchone()
    if row is None or row[0] == grain.id:
        return 0

    cur.execute(
        "SELECT finalize_spot_lineage(%s::smallint, %s::smallint)", (grain.id, row[0])
    )
    return cur.fetchone()[0]


def recompute_rarity(
    cur: psycopg.Cursor, grain_version_id: int, ruleset_id: int | None = None
) -> int:
    """手順3・5。ファセット統計と②を作り直す。

    **再計算ラン以外からも呼ぶ。** DBSCAN昇格（T-16）が紐付けを張り替えた後の
    配信中バージョンを直すのがそれで、その場合はスポットを動かさないので
    `grain_recalc_runs` のガード（draft / shadow 限定）には掛からない。
    """
    cur.execute(
        "SELECT recompute_rarity_for_grain(%s::smallint, %s::smallint)",
        (grain_version_id, ruleset_id),
    )
    return cur.fetchone()[0]


def _rebuild_ranking(cur: psycopg.Cursor, grain) -> int:
    """手順6。進行中の週次期間に対して作り直す。"""
    cur.execute(
        """
        SELECT id FROM ranking_periods
         WHERE kind = 'weekly' AND ends_at > now()
         ORDER BY starts_at DESC LIMIT 1
        """
    )
    row = cur.fetchone()
    if row is None:
        cur.execute("SELECT open_next_ranking_period('weekly')")
        period_id = cur.fetchone()[0]
    else:
        period_id = row[0]

    cur.execute(
        "SELECT rebuild_ranking_entries(%s, %s::smallint)", (period_id, grain.id)
    )
    return cur.fetchone()[0]


# ---------------------------------------------------------------------------
# ドライバ
# ---------------------------------------------------------------------------


def run_to_completion(
    cur: psycopg.Cursor,
    grain_version_id: int,
    batch_size: int = 5000,
    max_batches: int | None = None,
    poi_extract_version_id: int | None = None,
) -> dict:
    """フェーズを順に進める。`max_batches` を指定すると assign を途中で切り上げる。

    切り上げても状態は永続化されているので、次回の呼び出しが続きから進む。
    """
    run = start_or_resume(cur, grain_version_id, poi_extract_version_id)
    grain = grain_mod.load(cur, grain_version_id)
    summary: dict = {"run_id": run.id, "grain_version_id": grain_version_id}

    if run.phase == "assign":
        batches = 0
        while True:
            moved = _assign_batch(cur, run, grain, batch_size)
            if moved == 0:
                _advance(cur, run, "promote")
                break
            batches += 1
            if max_batches is not None and batches >= max_batches:
                summary["stopped_in"] = "assign"
                summary["processed_count"] = run.processed_count
                summary["phase"] = run.phase
                return summary
    summary["assigned"] = run.processed_count

    if run.phase == "promote":
        summary["promoted"] = _promote(cur, run, grain)
        _advance(cur, run, "lineage")

    if run.phase == "lineage":
        summary["split_recorded"] = _finalize_lineage(cur, run, grain)
        _advance(cur, run, "rarity")

    if run.phase == "rarity":
        summary["rarity_recomputed"] = recompute_rarity(cur, grain_version_id)
        _advance(cur, run, "ranking")

    if run.phase == "ranking":
        summary["ranking_entries"] = _rebuild_ranking(cur, grain)
        _advance(cur, run, "done")

    summary["phase"] = run.phase
    return summary
