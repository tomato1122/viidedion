"""POST /uploads → POST /posts/{id}/commit（`docs/02 §1.1`）の検証。"""

from __future__ import annotations

import datetime
import unittest

from ._base import _HAS_DB, ApiTestCase


@unittest.skipUnless(_HAS_DB, "DATABASE_URL / PGHOST が未設定のためスキップ")
class UploadFlowTest(ApiTestCase):
    def test_uploadsは仮のcaptured_atでpendingの行を作る(self) -> None:
        user_id = self.make_user()

        resp = self.client.post("/uploads", headers=self.auth_headers(user_id))

        self.assertEqual(resp.status_code, 201, resp.text)
        body = resp.json()
        self.assertIn("post_id", body)
        self.assertTrue(body["upload_url"])  # storage未設定でもプレースホルダURLが返る

        self.setup_cur.execute(
            "SELECT author_id, status, captured_at FROM posts WHERE id = %s", (body["post_id"],)
        )
        author_id, status, captured_at = self.setup_cur.fetchone()
        self.assertEqual(str(author_id), user_id)
        self.assertEqual(status, "pending")
        self.assertIsNotNone(captured_at)  # NOT NULL 制約を満たす仮値が入っている

    def test_認証ヘッダが無いと401(self) -> None:
        resp = self.client.post("/uploads")
        self.assertEqual(resp.status_code, 401)

    def test_存在しないユーザーIDは401(self) -> None:
        fake_user_id = "00000000-0000-0000-0000-000000000000"
        resp = self.client.post("/uploads", headers=self.auth_headers(fake_user_id))
        self.assertEqual(resp.status_code, 401)

    def _create_pending_post(self, user_id: str) -> str:
        resp = self.client.post("/uploads", headers=self.auth_headers(user_id))
        return resp.json()["post_id"]

    def test_commitで位置と撮影時刻が確定する(self) -> None:
        user_id = self.make_user()
        post_id = self._create_pending_post(user_id)
        captured_at = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=1)).isoformat()

        resp = self.client.post(
            f"/posts/{post_id}/commit",
            headers=self.auth_headers(user_id),
            json={
                "lat": 35.6812,
                "lon": 139.7671,
                "gps_accuracy_m": 8.0,
                "bearing_deg": 90.0,
                "bearing_src": "true",
                "captured_at": captured_at,
                "location_privacy": "exact",
            },
        )

        self.assertEqual(resp.status_code, 200, resp.text)

        self.setup_cur.execute(
            """
            SELECT ST_Y(location::geometry), ST_X(location::geometry), gps_accuracy_m,
                   bearing_deg, bearing_src, location_privacy
              FROM posts WHERE id = %s
            """,
            (post_id,),
        )
        lat, lon, accuracy, bearing, bearing_src, privacy = self.setup_cur.fetchone()
        self.assertAlmostEqual(lat, 35.6812, places=4)
        self.assertAlmostEqual(lon, 139.7671, places=4)
        self.assertEqual(accuracy, 8.0)
        self.assertEqual(bearing, 90.0)
        self.assertEqual(bearing_src, "true")
        self.assertEqual(privacy, "exact")

    def test_他人の投稿はcommitできない(self) -> None:
        owner = self.make_user()
        intruder = self.make_user()
        post_id = self._create_pending_post(owner)

        resp = self.client.post(
            f"/posts/{post_id}/commit",
            headers=self.auth_headers(intruder),
            json={
                "lat": 35.0,
                "lon": 139.0,
                "captured_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            },
        )

        self.assertEqual(resp.status_code, 403)

    def test_pendingでない投稿はcommitできない(self) -> None:
        user_id = self.make_user()
        post_id = self._create_pending_post(user_id)
        self.setup_cur.execute("UPDATE posts SET status = 'uploaded' WHERE id = %s", (post_id,))
        self.setup_conn.commit()

        resp = self.client.post(
            f"/posts/{post_id}/commit",
            headers=self.auth_headers(user_id),
            json={
                "lat": 35.0,
                "lon": 139.0,
                "captured_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            },
        )

        self.assertEqual(resp.status_code, 409)

    def test_未来すぎるcaptured_atは拒否する(self) -> None:
        user_id = self.make_user()
        post_id = self._create_pending_post(user_id)
        future = (datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(days=1)).isoformat()

        resp = self.client.post(
            f"/posts/{post_id}/commit",
            headers=self.auth_headers(user_id),
            json={"lat": 35.0, "lon": 139.0, "captured_at": future},
        )

        self.assertEqual(resp.status_code, 422)

    def test_不正な方位の組み合わせはDB制約で422になる(self) -> None:
        user_id = self.make_user()
        post_id = self._create_pending_post(user_id)

        resp = self.client.post(
            f"/posts/{post_id}/commit",
            headers=self.auth_headers(user_id),
            json={
                "lat": 35.0,
                "lon": 139.0,
                "bearing_deg": 90.0,
                "bearing_src": None,  # posts_bearing_src_ck 違反
                "captured_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            },
        )

        self.assertEqual(resp.status_code, 422)


if __name__ == "__main__":
    unittest.main()
