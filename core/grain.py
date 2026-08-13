"""粒度バージョンのパラメータ読み出し。

パラメータは `spot_grain_versions` にある（docs/01 §1.1）。
**コードに既定値を書かない。** 書くと、どの投稿がどのパラメータで解決されたかが
追えなくなり、粒度バージョニング（不変条件 I-3）が意味を失う。
"""

from __future__ import annotations

from dataclasses import dataclass

import psycopg

__all__ = ["GrainVersion", "load_active", "load"]

_COLUMNS = """
    id, code, status,
    h3_resolution, snap_radius_m, poi_match_radius_m, bearing_sector_count,
    dbscan_eps_m, dbscan_min_points, dbscan_min_users, gps_accuracy_reject_m
"""


@dataclass(frozen=True)
class GrainVersion:
    id: int
    code: str
    status: str
    h3_resolution: int
    snap_radius_m: float
    poi_match_radius_m: float
    bearing_sector_count: int
    dbscan_eps_m: float
    dbscan_min_points: int
    dbscan_min_users: int
    gps_accuracy_reject_m: float


def _row_to_grain(row: tuple) -> GrainVersion:
    return GrainVersion(*row)


def load_active(cur: psycopg.Cursor) -> GrainVersion:
    """配信に使う唯一のバージョン。"""
    cur.execute(f"SELECT {_COLUMNS} FROM spot_grain_versions WHERE status = 'active'")
    row = cur.fetchone()
    if row is None:
        raise LookupError("active な粒度バージョンが無い")
    return _row_to_grain(row)


def load(cur: psycopg.Cursor, grain_version_id: int) -> GrainVersion:
    """再計算ジョブが「当時のバージョン」を指定して読むための入口。"""
    cur.execute(f"SELECT {_COLUMNS} FROM spot_grain_versions WHERE id = %s", (grain_version_id,))
    row = cur.fetchone()
    if row is None:
        raise LookupError(f"粒度バージョン {grain_version_id} が無い")
    return _row_to_grain(row)
