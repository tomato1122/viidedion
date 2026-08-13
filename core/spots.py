"""スポット解決フロー（T-15）。

docs/01-spot-granularity.md §1.2 の解決フローと §8.3 の系譜判定を、
実行可能な形に落としたもの。採点ワーカー（docs/02 §1.3 手順2）と
粒度再計算ジョブ（docs/01 §4.3 手順2）の両方がここを呼ぶ。

守っていること:

- **セルは候補を引くインデックスとしてだけ使う。** 最終判定は正規スポット重心からの
  実距離（docs/01 §1.2 手順4）。セル境界で同一展望台が割れるのを防ぐ
- **外部POI APIを呼ばない。** 自前に取り込んだ `poi_reference` を引く（ADR-001 / docs/06）
- **新しいスポットを作るときは必ず親 identity を判定してから作る**（不変条件 I-4）。
  判定を飛ばすと粒度変更のたびにURLと称号が切れる
- **冪等。** 同じ投稿を何度解決しても同じ結果になる。再計算ジョブは途中で落ちる前提
"""

from __future__ import annotations

from dataclasses import dataclass
from uuid import UUID

import psycopg

from core import grain as grain_mod
from core import h3util
from scoring.facets import bearing_sector as derive_bearing_sector

__all__ = [
    "SpotBinding",
    "Assignment",
    "find_parent_identity",
    "resolve",
    "bind_post",
    "refresh_spot_counters",
]


@dataclass(frozen=True)
class SpotBinding:
    """どのスポットに、どうやって結び付いたか。"""

    spot_id: UUID
    identity_id: UUID
    h3_index: int
    #: 'snap' | 'poi' | 'cell'（'cluster' は昇格バッチ T-16 が張り替えるときに使う）
    bind_method: str
    #: 吸着で決まったときの実距離。POI/CELL 経路では None
    bind_distance_m: float | None
    #: このスポットで方位分割が有効か（docs/01 §2.3）
    bearing_split_enabled: bool


@dataclass(frozen=True)
class Assignment:
    post_id: UUID
    grain_version_id: int
    binding: SpotBinding
    bearing_sector: int | None
    low_confidence: bool


# ---------------------------------------------------------------------------
# 系譜の判定（docs/01 §8.3）
# ---------------------------------------------------------------------------


def find_parent_identity(
    cur: psycopg.Cursor,
    target_grain_id: int,
    lat: float,
    lon: float,
    snap_radius_m: float,
    post_id: UUID | str | None = None,
) -> tuple[UUID | None, str]:
    """新しいスポットを作る前に「これは旧粒度のどのスポットの続きか」を決める。

    返り値は (親identity, 系譜の操作)。docs/01 §8.3 の規則:

        候補0件     → create      新しい identity を発行
        候補1件     → carry_over  その identity を引き継ぐ（slug も称号もそのまま）
        候補2件以上 → merge       投稿数が最大の親に寄せる

    **判定の一次情報は距離ではなく「その投稿が旧粒度でどのスポットに属していたか」。**
    docs/01 §8.3 は重心間の距離で書いてあるが、暫定セルスポットの重心はグリッド由来の
    人工物で、解像度が変わると同じ場所でも100m近くずれる（res9 と res10 のセル中心）。
    距離だけで判定すると、同じ場所なのに carry_over を取り逃して identity を作り直し、
    URLと称号が切れる。投稿の紐付けを見れば厳密に決まる。

    投稿の文脈が無い場合（再計算以外の経路）だけ距離にフォールバックする。

    **split はここでは判定しない。** 1つの親が2つに割れたかどうかは、投稿の分布を
    見ないと決まらない。粒度再計算ジョブ（T-21）が全件を処理し終えた後に、
    親ごとの子の数を数えて判定する。
    """
    # 比較対象は「今アクティブなバージョン」。自分自身がアクティブなら、
    # そもそも前のバージョンが無いので新規発行になる。
    cur.execute("SELECT id FROM spot_grain_versions WHERE status = 'active'")
    row = cur.fetchone()
    if row is None or row[0] == target_grain_id:
        return None, "create"

    reference_grain_id = row[0]

    if post_id is not None:
        cur.execute(
            """
            SELECT s.identity_id
              FROM post_spot_assignment a
              JOIN spots s ON s.id = a.spot_id
             WHERE a.post_id = %s AND a.grain_version_id = %s
            """,
            (post_id, reference_grain_id),
        )
        row = cur.fetchone()
        if row is not None:
            return row[0], "carry_over"

    cur.execute(
        """
        SELECT s.identity_id, s.post_count
          FROM spots s
         WHERE s.grain_version_id = %s
           AND ST_DWithin(s.centroid, ST_SetSRID(ST_MakePoint(%s, %s), 4326)::geography, %s)
         ORDER BY s.post_count DESC, s.created_at ASC
        """,
        (reference_grain_id, lon, lat, snap_radius_m),
    )
    candidates = cur.fetchall()

    if not candidates:
        return None, "create"
    if len(candidates) == 1:
        return candidates[0][0], "carry_over"
    # 複数の旧スポットが1つに収まる = 粒度を粗くした。投稿数が最大の親に寄せる。
    return candidates[0][0], "merge"


# ---------------------------------------------------------------------------
# 解決フロー（docs/01 §1.2）
# ---------------------------------------------------------------------------


def _snap(cur, grain, cell_ring: list[int], lat: float, lon: float) -> SpotBinding | None:
    """手順3〜4。命名済みの正規スポットに吸着できるか。

    セル所属ではなく重心からの実距離で判定するのがここの要点。
    """
    cur.execute(
        """
        SELECT s.id, s.identity_id, s.h3_index, s.bearing_split_enabled,
               ST_Distance(s.centroid, ST_SetSRID(ST_MakePoint(%s, %s), 4326)::geography)
          FROM spots s
         WHERE s.grain_version_id = %s
           AND s.h3_index = ANY(%s)
           AND s.kind IN ('poi', 'cluster')
         ORDER BY s.centroid <-> ST_SetSRID(ST_MakePoint(%s, %s), 4326)::geography
         LIMIT 1
        """,
        (lon, lat, grain.id, cell_ring, lon, lat),
    )
    row = cur.fetchone()
    if row is None:
        return None

    spot_id, identity_id, h3_index, split_enabled, distance = row
    if distance > grain.snap_radius_m:
        return None

    return SpotBinding(spot_id, identity_id, h3_index, "snap", distance, split_enabled)


def _match_poi(
    cur, grain, cell: int, lat: float, lon: float,
    extract_version_id: int | None, post_id: UUID | str | None,
) -> SpotBinding | None:
    """手順5。自前に取り込んだ景観POIに一致するか（ADR-001 で外部APIから置き換え）。"""
    # 型を明示するのは、抽出バージョン未指定（NULL）のときに
    # PostgreSQL が関数のオーバーロードを決められなくなるため
    cur.execute(
        """
        SELECT osm_type, osm_id, display_name
          FROM find_scenic_poi(%s::double precision, %s::double precision,
                               %s::real, %s::smallint)
        """,
        (lat, lon, grain.poi_match_radius_m, extract_version_id),
    )
    row = cur.fetchone()
    if row is None:
        return None

    osm_type, osm_id, display_name = row
    external_id = f"{osm_type}/{osm_id}"

    # 同じPOIのスポットが既にあれば作らない。
    # spots_poi_uix（grain × provider × external_id）を先に見ることで、
    # 同時投稿で同じPOIに2つのスポットが生えるのを防ぐ。
    cur.execute(
        """
        SELECT id, identity_id, h3_index, bearing_split_enabled
          FROM spots
         WHERE grain_version_id = %s AND kind = 'poi'
           AND poi_source = 'osm' AND poi_external_id = %s
        """,
        (grain.id, external_id),
    )
    row = cur.fetchone()
    if row is not None:
        return SpotBinding(row[0], row[1], row[2], "poi", None, row[3])

    parent_identity, lineage_op = find_parent_identity(
        cur, grain.id, lat, lon, grain.snap_radius_m, post_id
    )

    cur.execute(
        """
        SELECT upsert_spot_with_identity(
            %s::smallint, 'poi'::spot_kind, %s::bigint,
            ST_SetSRID(ST_MakePoint(%s, %s), 4326)::geography,
            %s::text, 'poi'::spot_name_source, 'osm'::text, %s::text,
            %s::uuid, %s::spot_lineage_op
        )
        """,
        (grain.id, cell, lon, lat, display_name, external_id, parent_identity, lineage_op),
    )
    spot_id = cur.fetchone()[0]

    cur.execute(
        "SELECT identity_id, h3_index, bearing_split_enabled FROM spots WHERE id = %s", (spot_id,)
    )
    identity_id, h3_index, split_enabled = cur.fetchone()
    return SpotBinding(spot_id, identity_id, h3_index, "poi", None, split_enabled)


def _cell(
    cur, grain, cell: int, lat: float, lon: float, post_id: UUID | str | None
) -> SpotBinding:
    """手順6。POIに当たらなかったものは暫定セルスポットに落とす。

    「無名の絶景を拾えない」問題は、ここに落として DBSCAN昇格（T-16）で拾う。
    """
    cur.execute(
        """
        SELECT id, identity_id, h3_index, bearing_split_enabled
          FROM spots
         WHERE grain_version_id = %s AND kind = 'h3_cell' AND h3_index = %s
        """,
        (grain.id, cell),
    )
    row = cur.fetchone()
    if row is not None:
        return SpotBinding(row[0], row[1], row[2], "cell", None, row[3])

    # 暫定スポットの重心はセル中心にする。投稿の座標にすると、
    # 最初の1件がどこで撮られたかで以後の吸着判定がぶれる。
    center_lat, center_lon = h3util.center_of(cell)
    # 系譜の判定には投稿の実座標を渡す。セル中心は解像度が変わるとずれるため。
    parent_identity, lineage_op = find_parent_identity(
        cur, grain.id, lat, lon, grain.snap_radius_m, post_id
    )

    cur.execute(
        """
        SELECT upsert_spot_with_identity(
            %s::smallint, 'h3_cell'::spot_kind, %s::bigint,
            ST_SetSRID(ST_MakePoint(%s, %s), 4326)::geography,
            NULL::text, NULL::spot_name_source, NULL::text, NULL::text,
            %s::uuid, %s::spot_lineage_op
        )
        """,
        (grain.id, cell, center_lon, center_lat, parent_identity, lineage_op),
    )
    spot_id = cur.fetchone()[0]

    cur.execute(
        "SELECT identity_id, h3_index, bearing_split_enabled FROM spots WHERE id = %s", (spot_id,)
    )
    identity_id, h3_index, split_enabled = cur.fetchone()
    return SpotBinding(spot_id, identity_id, h3_index, "cell", None, split_enabled)


def resolve(
    cur: psycopg.Cursor,
    grain: grain_mod.GrainVersion,
    lat: float,
    lon: float,
    extract_version_id: int | None = None,
    post_id: UUID | str | None = None,
) -> SpotBinding:
    """docs/01 §1.2 の解決フロー。SNAP → POI → CELL の順に落とす。

    `post_id` は新しいスポットを作るときの系譜判定にだけ使う（docs/01 §8.3）。
    """
    cell = h3util.cell_of(lat, lon, grain.h3_resolution)
    ring = h3util.ring_of(cell, 1)

    binding = _snap(cur, grain, ring, lat, lon)
    if binding is not None:
        return binding

    binding = _match_poi(cur, grain, cell, lat, lon, extract_version_id, post_id)
    if binding is not None:
        return binding

    return _cell(cur, grain, cell, lat, lon, post_id)


# ---------------------------------------------------------------------------
# 投稿への適用
# ---------------------------------------------------------------------------


def refresh_spot_counters(cur: psycopg.Cursor, spot_id: UUID | str) -> None:
    """`spots` の非正規化カウンタを紐付けから数え直す。

    加算ではなく数え直しにしているのは、この2つを同時に満たすため:

    - **冪等**: 同じ投稿を再解決しても二重に数えない（docs/01 §4.3 の要件）
    - **張り替えに強い**: DBSCAN昇格（T-16）が投稿を別スポットへ移しても整合する

    希少性②の対数逓減（`calc_rarity_score` の `p_spot_post_count`）と
    `v_grain_health` の指標がこの値を読むので、ずれると採点と監視が両方狂う。
    """
    cur.execute(
        """
        UPDATE spots s SET
            post_count          = COALESCE(c.n, 0),
            distinct_user_count = COALESCE(c.u, 0),
            first_post_at       = c.first_at,
            last_post_at        = c.last_at
          FROM (
            SELECT count(*) AS n, count(DISTINCT p.author_id) AS u,
                   min(p.captured_at) AS first_at, max(p.captured_at) AS last_at
              FROM post_spot_assignment a
              JOIN posts p ON p.id = a.post_id
             WHERE a.spot_id = %s
          ) c
         WHERE s.id = %s
        """,
        (spot_id, spot_id),
    )


def bind_post(
    cur: psycopg.Cursor,
    post_id: UUID | str,
    grain_version_id: int | None = None,
    extract_version_id: int | None = None,
    low_confidence: bool | None = None,
) -> Assignment:
    """投稿1件をスポットに結び付け、`post_spot_assignment` に書く。

    `low_confidence` を明示すると測位精度による判定を上書きする。
    T-13（ingest）が trust_score の帯域を見て渡す想定（docs/04 SEC-TRUST-02）。

    冪等。同じ投稿を何度呼んでも同じ行になる（docs/01 §4.3 の要件）。
    """
    cur.execute(
        """
        SELECT ST_Y(location::geometry), ST_X(location::geometry),
               gps_accuracy_m, bearing_deg
          FROM posts WHERE id = %s
        """,
        (post_id,),
    )
    row = cur.fetchone()
    if row is None:
        raise LookupError(f"投稿 {post_id} が無い")

    lat, lon, gps_accuracy_m, bearing_deg = row
    if lat is None or lon is None:
        raise ValueError(f"投稿 {post_id} に位置が無いのでスポットを解決できない")

    grain = (
        grain_mod.load(cur, grain_version_id)
        if grain_version_id is not None
        else grain_mod.load_active(cur)
    )

    # 再解決で別のスポットに移る場合、移動元のカウンタも数え直す必要がある
    cur.execute(
        "SELECT spot_id FROM post_spot_assignment WHERE post_id = %s AND grain_version_id = %s",
        (post_id, grain.id),
    )
    row = cur.fetchone()
    previous_spot_id = row[0] if row else None

    binding = resolve(cur, grain, lat, lon, extract_version_id, post_id)

    # 方位分割が無効なスポットでは、全投稿を「方位不明」と同じ単一バケットに寄せる
    # （docs/01 §2.3）。海岸線や一本道で椅子だけ増えるのを防ぐ。
    sector = (
        derive_bearing_sector(bearing_deg, grain.bearing_sector_count)
        if binding.bearing_split_enabled
        else None
    )

    if low_confidence is None:
        # 測位が粗い、または精度が取れていない投稿は「初」ボーナスの対象外にする
        low_confidence = gps_accuracy_m is None or gps_accuracy_m > grain.gps_accuracy_reject_m

    cur.execute(
        """
        INSERT INTO post_spot_assignment (
            post_id, grain_version_id, spot_id, h3_index,
            bearing_sector, bind_method, bind_distance_m, low_confidence
        ) VALUES (%s, %s, %s, %s, %s, %s, %s, %s)
        ON CONFLICT (post_id, grain_version_id) DO UPDATE SET
            spot_id         = EXCLUDED.spot_id,
            h3_index        = EXCLUDED.h3_index,
            bearing_sector  = EXCLUDED.bearing_sector,
            bind_method     = EXCLUDED.bind_method,
            bind_distance_m = EXCLUDED.bind_distance_m,
            low_confidence  = EXCLUDED.low_confidence,
            assigned_at     = now()
        """,
        (
            post_id,
            grain.id,
            binding.spot_id,
            binding.h3_index,
            sector,
            binding.bind_method,
            binding.bind_distance_m,
            low_confidence,
        ),
    )

    refresh_spot_counters(cur, binding.spot_id)
    if previous_spot_id is not None and previous_spot_id != binding.spot_id:
        refresh_spot_counters(cur, previous_spot_id)

    return Assignment(post_id, grain.id, binding, sector, low_confidence)
