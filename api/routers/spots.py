"""地図・スポット詳細（P-02 地図ファースト）。

フィードAPIは作らない（`docs/05` P-02）。地図はH3集約クラスタ、
詳細は永続ID経由でのみ引く（`docs/01` 不変条件 I-4）。
"""

from __future__ import annotations

from collections import defaultdict

import psycopg
from fastapi import APIRouter, Depends, HTTPException, Query

from core import h3util

from ..deps import get_db
from ..schemas import MapCluster, SpotDetail

router = APIRouter(prefix="/spots", tags=["spots"])

# ズームレベル → 集約に使うH3解像度。粒度バージョンの同定用解像度（res9/10）とは別物。
# 大きいほど細かい。値は「地図として見やすいクラスタ数になるか」の暫定値であり、
# T-30（地図タイル配信方式）で実データを見て調整する前提（未確定）。
_ZOOM_TO_RESOLUTION = {
    3: 3, 4: 3, 5: 4, 6: 4, 7: 5, 8: 5, 9: 6, 10: 6,
    11: 7, 12: 7, 13: 8, 14: 8, 15: 9, 16: 9, 17: 10, 18: 10,
}
_MAX_CLUSTER_ROWS = 5000  # 誤ってビューポート全体を要求されても暴走しないための上限


def _resolution_for_zoom(zoom: int) -> int:
    if zoom <= min(_ZOOM_TO_RESOLUTION):
        return _ZOOM_TO_RESOLUTION[min(_ZOOM_TO_RESOLUTION)]
    if zoom >= max(_ZOOM_TO_RESOLUTION):
        return _ZOOM_TO_RESOLUTION[max(_ZOOM_TO_RESOLUTION)]
    return _ZOOM_TO_RESOLUTION[zoom]


@router.get("/map-clusters", response_model=list[MapCluster])
def map_clusters(
    min_lat: float = Query(..., ge=-90, le=90),
    max_lat: float = Query(..., ge=-90, le=90),
    min_lon: float = Query(..., ge=-180, le=180),
    max_lon: float = Query(..., ge=-180, le=180),
    zoom: int = Query(..., ge=0, le=22),
    cur: psycopg.Cursor = Depends(get_db),
) -> list[MapCluster]:
    """ビューポート内のスポットをH3セルに集約して返す。

    セルへの集約はPythonで行う（`core/h3util.py` の方針どおり、H3計算は
    アプリ層に閉じ込める。`h3-pg` 拡張は使わない）。ビューポートの絞り込みだけ
    PostGISの `centroid` GiSTインデックス（`spots_centroid_gix`）に任せる。
    """
    if min_lat > max_lat or min_lon > max_lon:
        raise HTTPException(status_code=400, detail="bboxの範囲が不正")

    resolution = _resolution_for_zoom(zoom)

    cur.execute(
        """
        SELECT s.h3_index, s.post_count, s.display_name
          FROM spots s
         WHERE s.grain_version_id = (SELECT id FROM spot_grain_versions WHERE status = 'active')
           AND ST_Intersects(s.centroid, ST_MakeEnvelope(%s, %s, %s, %s, 4326)::geography)
         LIMIT %s
        """,
        (min_lon, min_lat, max_lon, max_lat, _MAX_CLUSTER_ROWS),
    )
    rows = cur.fetchall()

    buckets: dict[int, dict] = defaultdict(
        lambda: {"spot_count": 0, "post_count": 0, "has_named_spot": False}
    )
    for h3_index, post_count, display_name in rows:
        parent = h3util.parent_of(h3_index, resolution)
        b = buckets[parent]
        b["spot_count"] += 1
        b["post_count"] += post_count
        b["has_named_spot"] = b["has_named_spot"] or display_name is not None

    clusters = []
    for cell, b in buckets.items():
        # クラスタの代表座標はメンバーの重心ではなくセル中心にする。
        # centroid平均だと解像度を変えるたびにクラスタ数と一緒に座標も揺れて、
        # ズームイン・アウトの体験が不安定になる。セル中心なら解像度だけで決まる。
        lat, lon = h3util.center_of(cell)
        clusters.append(
            MapCluster(
                h3_cell=h3util.to_str(cell),
                lat=lat,
                lon=lon,
                spot_count=b["spot_count"],
                post_count=b["post_count"],
                has_named_spot=b["has_named_spot"],
            )
        )
    return clusters


@router.get("/{slug}", response_model=SpotDetail)
def spot_detail(slug: str, cur: psycopg.Cursor = Depends(get_db)) -> SpotDetail:
    """永続ID（`spot_identity`）経由でスポット詳細を返す。

    slugは旧slug・統合先も `resolve_spot_slug()` が辿るため、リダイレクトの
    実装をAPI側に持たなくてよい（不変条件 I-4、`docs/01` §8）。
    """
    cur.execute("SELECT resolve_spot_slug(%s)", (slug,))
    identity_id = cur.fetchone()[0]
    if identity_id is None:
        raise HTTPException(status_code=404, detail="スポットが見つからない")

    cur.execute(
        """
        SELECT identity_id, slug, display_name, name_source, source_code, attribution_text,
               ST_Y(representative_point::geometry), ST_X(representative_point::geometry),
               spot_id, kind, post_count, distinct_user_count,
               bearing_split_enabled, first_post_at, last_post_at
          FROM v_spot_public
         WHERE identity_id = %s
        """,
        (identity_id,),
    )
    row = cur.fetchone()
    if row is None:
        # identity はあるがアクティブな粒度バージョンに実体が無い（理論上は起きない）
        raise HTTPException(status_code=404, detail="スポットが見つからない")

    (
        identity_id, slug_out, display_name, name_source, source_code, attribution_text,
        lat, lon, _spot_id, kind, post_count, distinct_user_count,
        bearing_split_enabled, first_post_at, last_post_at,
    ) = row

    return SpotDetail(
        identity_id=identity_id,
        slug=slug_out,
        display_name=display_name,
        name_source=name_source,
        source_code=source_code,
        attribution_text=attribution_text,
        lat=lat,
        lon=lon,
        kind=kind,
        post_count=post_count or 0,
        distinct_user_count=distinct_user_count or 0,
        bearing_split_enabled=bearing_split_enabled,
        first_post_at=first_post_at,
        last_post_at=last_post_at,
    )
