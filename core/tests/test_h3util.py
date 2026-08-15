"""core.h3util の変換ロジックの検証。DBを使わない純粋なH3計算のみ。"""

from __future__ import annotations

import unittest

from core import h3util


class ParentOfTests(unittest.TestCase):
    def test_粗い解像度の祖先セルになる(self):
        cell = h3util.cell_of(35.6812, 139.7671, 10)  # 東京駅付近
        parent = h3util.parent_of(cell, 6)
        self.assertEqual(h3util.resolution_of(parent), 6)

    def test_同じセルに属する2点は同じ祖先セルに畳まれる(self):
        cell_a = h3util.cell_of(35.6812, 139.7671, 10)
        cell_b = h3util.cell_of(35.6813, 139.7672, 10)
        self.assertEqual(h3util.parent_of(cell_a, 6), h3util.parent_of(cell_b, 6))

    def test_遠い2点は違う祖先セルになる(self):
        tokyo = h3util.cell_of(35.6812, 139.7671, 9)
        osaka = h3util.cell_of(34.6937, 135.5023, 9)
        self.assertNotEqual(h3util.parent_of(tokyo, 4), h3util.parent_of(osaka, 4))


if __name__ == "__main__":
    unittest.main()
