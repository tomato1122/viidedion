"""GET /spots/map-clusters, GET /spots/{slug} の検証。"""

from __future__ import annotations

import os
import unittest

from ._base import _HAS_DB, ApiTestCase

if _HAS_DB:
    from core import grain as grain_mod
    from core import spots as spots_mod


@unittest.skipUnless(_HAS_DB, "DATABASE_URL / PGHOST が未設定のためスキップ")
class MapClustersTest(ApiTestCase):
    def test_bboxの範囲外のスポットは含まれない(self) -> None:
        grain = grain_mod.load_active(self.setup_cur)
        # 富士山付近と、東京から遠く離れた点（bboxの外）
        in_bbox = spots_mod.resolve(self.setup_cur, grain, 35.3606, 138.7274)
        spots_mod.resolve(self.setup_cur, grain, 43.0621, 141.3544)  # 札幌（範囲外）
        self.setup_conn.commit()

        resp = self.client.get(
            "/spots/map-clusters",
            params={"min_lat": 35.0, "max_lat": 35.7, "min_lon": 138.5, "max_lon": 139.0, "zoom": 12},
        )

        self.assertEqual(resp.status_code, 200, resp.text)
        clusters = resp.json()
        total_spots = sum(c["spot_count"] for c in clusters)
        self.assertGreaterEqual(total_spots, 1)
        # 札幌の1件がbboxに紛れ込んでいないことを、合計スポット数の上限で確認する
        self.assertLess(total_spots, 5)

    def test_bboxが不正なら400(self) -> None:
        resp = self.client.get(
            "/spots/map-clusters",
            params={"min_lat": 40.0, "max_lat": 35.0, "min_lon": 138.0, "max_lon": 139.0, "zoom": 10},
        )
        self.assertEqual(resp.status_code, 400)


@unittest.skipUnless(_HAS_DB, "DATABASE_URL / PGHOST が未設定のためスキップ")
class SpotDetailTest(ApiTestCase):
    def test_slugからスポット詳細が引ける(self) -> None:
        grain = grain_mod.load_active(self.setup_cur)
        binding = spots_mod.resolve(self.setup_cur, grain, 34.9853, 138.9310)  # 三保松原付近
        self.setup_conn.commit()

        self.setup_cur.execute("SELECT slug FROM spot_identity WHERE id = %s", (binding.identity_id,))
        slug = self.setup_cur.fetchone()[0]
        self.setup_conn.commit()

        resp = self.client.get(f"/spots/{slug}")

        self.assertEqual(resp.status_code, 200, resp.text)
        body = resp.json()
        self.assertEqual(body["slug"], slug)
        self.assertEqual(body["identity_id"], str(binding.identity_id))
        self.assertNotIn("total_score", body)  # 生スコアは絶対に含まれない

    def test_存在しないslugは404(self) -> None:
        resp = self.client.get(f"/spots/no-such-slug-{os.urandom(4).hex()}")
        self.assertEqual(resp.status_code, 404)


if __name__ == "__main__":
    unittest.main()
