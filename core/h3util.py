"""H3 の扱いをここ1箇所に閉じ込める。

CLAUDE.md の決定: **H3 はアプリ層で計算し `bigint` で保存する**
（`h3-pg` は Azure Database for PostgreSQL の対応拡張機能一覧に無い）。

h3-py は文字列表現（'892f5ba8c03ffff'）を返すが、**DBに入れるのは常に int**。
文字列とintが混ざると、同じセルなのに一致しない比較が生まれる。
変換はこのモジュールの外でやらないこと。
"""

from __future__ import annotations

import h3

__all__ = ["cell_of", "ring_of", "center_of", "resolution_of"]


def cell_of(lat: float, lon: float, resolution: int) -> int:
    """座標を H3 セル（bigint）に落とす。"""
    return h3.str_to_int(h3.latlng_to_cell(lat, lon, resolution))


def ring_of(cell: int, k: int = 1) -> list[int]:
    """自セル + 周囲 k リング。

    docs/01 §1.2 手順2。候補を引くためだけに使う。
    セル所属で最終判定はしない（境界で同一展望台が割れるため）。
    """
    return [h3.str_to_int(c) for c in h3.grid_disk(h3.int_to_str(cell), k)]


def center_of(cell: int) -> tuple[float, float]:
    """セル中心の (lat, lon)。

    表示座標のグリッドスナップ（docs/04 SEC-PRIV-02）にも使う。
    ここが決定的であることが、ジッター禁止の根拠になっている。
    """
    return h3.cell_to_latlng(h3.int_to_str(cell))


def resolution_of(cell: int) -> int:
    return h3.get_resolution(h3.int_to_str(cell))
