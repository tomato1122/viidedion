"""api/tests 共通のセットアップ。core/tests と同じ判定・同じDBに対して実行する。"""

from __future__ import annotations

import os
import unittest

_HAS_DB = bool(os.environ.get("DATABASE_URL") or os.environ.get("PGHOST"))

if _HAS_DB:
    from fastapi.testclient import TestClient

    from api.main import app
    from core import db as core_db


class ApiTestCase(unittest.TestCase):
    """テストごとに専用DB接続を持ち、投稿・スコア計算などの直接セットアップに使う。

    API呼び出しはリクエストごとに別接続でコミットされる（`api.deps.get_db` の設計。
    ロールバックでは消せないため、テストデータは乱数サフィックス付きの名前にして
    テスト同士が衝突しないようにする）。
    """

    def setUp(self) -> None:
        self.client = TestClient(app)
        self.setup_conn = core_db.connect()
        self.setup_cur = self.setup_conn.cursor()

    def tearDown(self) -> None:
        self.setup_conn.commit()
        self.setup_conn.close()

    def make_user(self) -> str:
        suffix = os.urandom(4).hex()
        self.setup_cur.execute(
            "INSERT INTO users (handle, display_name) VALUES (%s, %s) RETURNING id",
            (f"api-test-{suffix}", "APIテスト用"),
        )
        user_id = self.setup_cur.fetchone()[0]
        # APIリクエストは別接続で処理される（api/deps.py）ため、ここで確定させないと見えない
        self.setup_conn.commit()
        return str(user_id)

    def auth_headers(self, user_id: str) -> dict[str, str]:
        return {"X-User-Id": user_id}
