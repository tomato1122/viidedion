"""GET /me/personal-best の検証。生スコアが含まれないことも確認する。"""

from __future__ import annotations

import unittest

from ._base import _HAS_DB, ApiTestCase

if _HAS_DB:
    from core import grain as grain_mod
    from core import spots as spots_mod


@unittest.skipUnless(_HAS_DB, "DATABASE_URL / PGHOST が未設定のためスキップ")
class PersonalBestTest(ApiTestCase):
    def _published_post(self, user_id: str, lat: float, lon: float) -> str:
        self.setup_cur.execute(
            """
            INSERT INTO posts (author_id, status, captured_at, location, gps_accuracy_m, bearing_deg, bearing_src)
            VALUES (%s, 'published', now(),
                    ST_SetSRID(ST_MakePoint(%s, %s), 4326)::geography, 5.0, 10.0, 'true')
            RETURNING id
            """,
            (user_id, lon, lat),
        )
        post_id = self.setup_cur.fetchone()[0]
        grain = grain_mod.load_active(self.setup_cur)
        spots_mod.bind_post(self.setup_cur, post_id)
        self.setup_conn.commit()
        return str(post_id)

    def test_公開済みの投稿が自己ベストとして返る(self) -> None:
        user_id = self.make_user()
        post_id = self._published_post(user_id, 35.6581, 139.7414)  # 東京タワー付近

        resp = self.client.get("/me/personal-best", headers=self.auth_headers(user_id))

        self.assertEqual(resp.status_code, 200, resp.text)
        body = resp.json()
        self.assertEqual(len(body), 1)
        self.assertEqual(body[0]["best_post_id"], post_id)
        self.assertNotIn("total_score", body[0])
        self.assertNotIn("best_total_score", body[0])

    def test_投稿が無ければ空配列(self) -> None:
        user_id = self.make_user()
        resp = self.client.get("/me/personal-best", headers=self.auth_headers(user_id))
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(resp.json(), [])


if __name__ == "__main__":
    unittest.main()
