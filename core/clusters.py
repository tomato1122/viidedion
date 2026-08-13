"""DBSCAN による独自スポットへの昇格（T-16）。

docs/01-spot-granularity.md §1.3 の実装。`kind='h3_cell'` の暫定スポットに投稿が
溜まったら、密度で固まっている部分を `kind='cluster'` の独自スポットに切り出す。

これが「無名の絶景を拾う」経路そのもの。POI に当たらない場所は §1.2 手順6 で
暫定セルに落ちるだけなので、ここで拾わないと永久に「この付近」のままになる。

## 距離の測り方

docs は「Haversine 距離」と書いているが、**近傍判定は PostGIS の `ST_DWithin`
（geography）で行う**。理由は2つ:

- 球面近似ではなく回転楕円体上の測地線距離になる。同じ80mでも判定が変わる
- `spots_centroid_gix` / `posts_location_gix` の GiST 索引が効く

DBSCAN 本体（コア点判定とクラスタの拡張）だけを Python で持つ。
numpy / scikit-learn を持ち込まないのは、**バッチ1本のためにイメージを重くしないため**。
1セル分の投稿はたかだか数百件で、密度計算はDB側に寄せてある。

## 昇格したスポットの永続ID

同一粒度バージョンの中では `spots (grain_version_id, identity_id)` が一意なので、
**昇格スポットは必ず新しい identity を持つ**（元のセルスポットのものは使えない）。
元のセルスポットとの関係は `spot_lineage` に `split` として残す。

元のセルスポットが空になった場合だけ `merge` に切り替え、旧 slug を昇格スポットへ
向ける。そうしないと、既に配布されていた「この付近」のURLが死ぬ。
"""

from __future__ import annotations

from dataclasses import dataclass
from uuid import UUID

import psycopg

from core import grain as grain_mod
from core import h3util
from core.spots import refresh_spot_counters

__all__ = ["Candidate", "Promotion", "dbscan", "promote_cell_spot", "promote_pending"]


@dataclass(frozen=True)
class Candidate:
    post_id: UUID
    author_id: UUID
    spot_id: UUID
    lat: float
    lon: float


@dataclass(frozen=True)
class Promotion:
    """1つのクラスタが昇格した結果。"""

    cluster_spot_id: UUID
    cluster_identity_id: UUID
    source_spot_ids: list[UUID]
    moved_post_count: int
    distinct_author_count: int
    #: 最多投稿者。「命名権」の通知先（docs/01 §1.3 手順6）。通知そのものは T-27
    top_contributor_id: UUID
    lineage_op: str


# ---------------------------------------------------------------------------
# DBSCAN 本体
# ---------------------------------------------------------------------------


def dbscan(
    candidates: list[Candidate],
    neighbours: dict[UUID, set[UUID]],
    min_points: int,
) -> list[list[Candidate]]:
    """近傍集合を与えて DBSCAN を回す。

    `min_points` は**自分自身を含めた**点数。「同じ場所で5回以上撮られた」
    （docs/01 §1.1）をそのまま数えたいので、scikit-learn の `min_samples` と同じ流儀。

    到達可能性の伝播はコア点からのみ行う。境界点（コア点の近傍だがそれ自体は
    コア点でない）はクラスタに入るが、そこから先へは広げない。これを緩めると
    まばらな点が数珠つなぎになり、峠一帯が1つのスポットになる。
    """
    by_id = {c.post_id: c for c in candidates}
    unassigned: set[UUID] = set(by_id)
    clusters: list[list[Candidate]] = []

    def is_core(pid: UUID) -> bool:
        # neighbours は自分自身を含まないので +1 する
        return len(neighbours.get(pid, ())) + 1 >= min_points

    visited: set[UUID] = set()

    for pid in by_id:
        if pid in visited or not is_core(pid):
            continue

        visited.add(pid)
        member_ids = {pid}
        frontier = list(neighbours.get(pid, ()))

        while frontier:
            qid = frontier.pop()
            if qid not in by_id:
                continue
            member_ids.add(qid)
            if qid in visited:
                continue
            visited.add(qid)
            if is_core(qid):
                frontier.extend(neighbours.get(qid, ()))

        # 既に別のクラスタに取られた点は重複させない（先に見つかったクラスタが勝つ）
        member_ids &= unassigned
        if not member_ids:
            continue
        unassigned -= member_ids
        clusters.append([by_id[m] for m in member_ids])

    return clusters


# ---------------------------------------------------------------------------
# 候補の収集と昇格
# ---------------------------------------------------------------------------


def _candidates(cur, grain, cell_ring: list[int]) -> list[Candidate]:
    """セル + 隣接セルの、まだ暫定セルに留まっている投稿（docs/01 §1.3 手順1）。

    `bind_method = 'cell'` に絞るのは、既に命名済みスポットへ吸着した投稿を
    奪い返さないため。測位が粗い投稿を外すのは、クラスタの重心がぶれるため。
    """
    cur.execute(
        """
        SELECT p.id, p.author_id, a.spot_id,
               ST_Y(p.location::geometry), ST_X(p.location::geometry)
          FROM post_spot_assignment a
          JOIN posts p ON p.id = a.post_id
         WHERE a.grain_version_id = %s
           AND a.h3_index = ANY(%s)
           AND a.bind_method = 'cell'
           AND p.location IS NOT NULL
           AND p.gps_accuracy_m IS NOT NULL
           AND p.gps_accuracy_m <= %s
        """,
        (grain.id, cell_ring, grain.gps_accuracy_reject_m),
    )
    return [Candidate(*row) for row in cur.fetchall()]


def _neighbours(cur, candidates: list[Candidate], eps_m: float) -> dict[UUID, set[UUID]]:
    """eps 以内の近傍を PostGIS に数えさせる（測地線距離 + GiST索引）。"""
    if not candidates:
        return {}

    ids = [c.post_id for c in candidates]
    cur.execute(
        """
        WITH cand AS (SELECT id, location FROM posts WHERE id = ANY(%s))
        SELECT a.id, b.id
          FROM cand a JOIN cand b ON a.id <> b.id
         WHERE ST_DWithin(a.location, b.location, %s)
        """,
        (ids, eps_m),
    )
    result: dict[UUID, set[UUID]] = {pid: set() for pid in ids}
    for left, right in cur.fetchall():
        result[left].add(right)
    return result


def _promote(cur, grain, members: list[Candidate]) -> Promotion:
    """1クラスタを `kind='cluster'` のスポットに切り出し、投稿を張り替える。"""
    member_ids = [m.post_id for m in members]

    # 重心は PostGIS に出させる。緯度経度の単純平均で済ませない。
    cur.execute(
        """
        SELECT ST_Y(c), ST_X(c) FROM (
            SELECT ST_Centroid(ST_Collect(location::geometry)) AS c
              FROM posts WHERE id = ANY(%s)
        ) t
        """,
        (member_ids,),
    )
    center_lat, center_lon = cur.fetchone()
    cell = h3util.cell_of(center_lat, center_lon, grain.h3_resolution)

    # 同一粒度では元セルの identity を再利用できない（spots_identity_uix）ので
    # 新規発行する。元セルとの関係は後段で spot_lineage に書く。
    cur.execute(
        """
        SELECT upsert_spot_with_identity(
            %s::smallint, 'cluster'::spot_kind, %s::bigint,
            ST_SetSRID(ST_MakePoint(%s, %s), 4326)::geography,
            NULL::text, NULL::spot_name_source, 'user'::text, NULL::text,
            NULL::uuid, 'create'::spot_lineage_op
        )
        """,
        (grain.id, cell, center_lon, center_lat),
    )
    cluster_spot_id = cur.fetchone()[0]

    cur.execute("SELECT identity_id FROM spots WHERE id = %s", (cluster_spot_id,))
    cluster_identity_id = cur.fetchone()[0]

    cur.execute(
        """
        UPDATE post_spot_assignment
           SET spot_id = %s, h3_index = %s, bind_method = 'cluster', assigned_at = now()
         WHERE grain_version_id = %s AND post_id = ANY(%s)
        """,
        (cluster_spot_id, cell, grain.id, member_ids),
    )

    authors = {m.author_id for m in members}
    top_contributor = max(authors, key=lambda a: sum(1 for m in members if m.author_id == a))

    return Promotion(
        cluster_spot_id=cluster_spot_id,
        cluster_identity_id=cluster_identity_id,
        source_spot_ids=sorted({m.spot_id for m in members}, key=str),
        moved_post_count=len(members),
        distinct_author_count=len(authors),
        top_contributor_id=top_contributor,
        lineage_op="split",
    )


def _record_lineage(cur, grain, promotion: Promotion, source_spot_id: UUID) -> str:
    """元のセルスポットとの関係を残す。

    元セルが空になったなら `merge` にして旧 slug を昇格スポットへ向ける。
    残っているなら `split`。**どちらの場合も、既に配られたURLを死なせない**
    ことが目的（不変条件 I-4）。
    """
    cur.execute(
        "SELECT identity_id, post_count FROM spots WHERE id = %s", (source_spot_id,)
    )
    source_identity, remaining = cur.fetchone()

    total = remaining + promotion.moved_post_count
    share = promotion.moved_post_count / total if total else None

    # セルの投稿が全部移ったなら実質的な引っ越し。残っていれば分割。
    op = "merge" if remaining == 0 else "split"

    # upsert_spot_with_identity が書いた 'create' の行を、実際の関係で上書きする。
    # create のまま残すと「どこから生えたスポットか」が追えず、称号の継承判断
    # （T-25）ができなくなる。
    #
    # **merge_spot_identity より先に行う。** あちらも同じキーの系譜行を入れるので、
    # 後から UPDATE すると一意制約に当たる（あちらの INSERT は ON CONFLICT DO NOTHING
    # なので、こちらを先に済ませておけば無害に空振りする）。
    cur.execute(
        """
        UPDATE spot_lineage
           SET op = %s::spot_lineage_op,
               from_grain_version_id = %s::smallint,
               parent_identity_id = %s,
               post_share = %s,
               moved_post_count = %s
         WHERE to_grain_version_id = %s
           AND child_identity_id = %s
           AND op = 'create'
        """,
        (
            op,
            grain.id,
            source_identity,
            share,
            promotion.moved_post_count,
            grain.id,
            promotion.cluster_identity_id,
        ),
    )

    if op == "merge":
        # 旧 slug を昇格スポットに向ける。既に配られた「この付近」のURLを死なせない。
        cur.execute(
            "SELECT merge_spot_identity(%s, %s, %s::smallint)",
            (source_identity, promotion.cluster_identity_id, grain.id),
        )

    return op


def promote_cell_spot(
    cur: psycopg.Cursor,
    grain: grain_mod.GrainVersion,
    cell_spot_id: UUID | str,
) -> list[Promotion]:
    """暫定セルスポット1つを精査して、昇格できるクラスタを切り出す。"""
    cur.execute(
        "SELECT h3_index, kind FROM spots WHERE id = %s", (cell_spot_id,)
    )
    row = cur.fetchone()
    if row is None:
        raise LookupError(f"スポット {cell_spot_id} が無い")
    h3_index, kind = row
    if kind != "h3_cell":
        raise ValueError(f"暫定セルスポットではない: kind={kind}")

    ring = h3util.ring_of(h3_index, 1)
    candidates = _candidates(cur, grain, ring)
    if len(candidates) < grain.dbscan_min_points:
        return []

    neighbours = _neighbours(cur, candidates, grain.dbscan_eps_m)
    clusters = dbscan(candidates, neighbours, grain.dbscan_min_points)

    promotions: list[Promotion] = []
    for members in clusters:
        # 1人の連投でスポットが生えるのを防ぐ（docs/01 §1.1 dbscan_min_users）
        if len({m.author_id for m in members}) < grain.dbscan_min_users:
            continue

        promotion = _promote(cur, grain, members)
        refresh_spot_counters(cur, promotion.cluster_spot_id)

        ops = set()
        for source_spot_id in promotion.source_spot_ids:
            refresh_spot_counters(cur, source_spot_id)
            ops.add(_record_lineage(cur, grain, promotion, source_spot_id))

        promotions.append(
            Promotion(
                **{
                    **promotion.__dict__,
                    "lineage_op": "merge" if ops == {"merge"} else "split",
                }
            )
        )

    if promotions:
        # 昇格が起きたセルだけ印を付ける。クラスタが立たなかったセルは印を付けず、
        # 投稿が増えてから次回の走査で再評価する。
        cur.execute(
            "UPDATE spots SET promoted_at = now() WHERE id = %s", (cell_spot_id,)
        )

    return promotions


def promote_pending(
    cur: psycopg.Cursor,
    grain: grain_mod.GrainVersion | None = None,
    limit: int = 100,
) -> list[Promotion]:
    """昇格対象の暫定セルを走査する（docs/01 §1.3 の対象条件）。

    夜間バッチ（T-16 / Container Apps Job）の入口。
    """
    if grain is None:
        grain = grain_mod.load_active(cur)

    cur.execute(
        """
        SELECT id FROM spots
         WHERE grain_version_id = %s
           AND kind = 'h3_cell'
           AND post_count >= %s
           AND promoted_at IS NULL
         ORDER BY post_count DESC
         LIMIT %s
        """,
        (grain.id, grain.dbscan_min_points, limit),
    )
    targets = [row[0] for row in cur.fetchall()]

    promotions: list[Promotion] = []
    for spot_id in targets:
        # 先に処理したセルがこのセルの投稿を吸い上げている場合があるので、
        # まだ暫定セルとして残っているかを都度確かめる
        cur.execute("SELECT kind FROM spots WHERE id = %s", (spot_id,))
        row = cur.fetchone()
        if row is None or row[0] != "h3_cell":
            continue
        promotions.extend(promote_cell_spot(cur, grain, spot_id))

    return promotions
