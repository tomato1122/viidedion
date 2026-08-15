"""FastAPI の依存性注入。DB接続と「今のユーザー」の取り方をここに閉じ込める。"""

from __future__ import annotations

from collections.abc import Iterator
from uuid import UUID

import psycopg
from fastapi import Header, HTTPException

from core import db as core_db

from .config import get_settings


def get_db() -> Iterator[psycopg.Cursor]:
    """リクエスト1件 = 1トランザクション。

    `core.db.transaction` をそのまま使う。書き込みを含むエンドポイントで
    途中の例外がコミットされないようにするのが目的（スポット解決フローと同じ理由）。
    """
    settings = get_settings()
    with core_db.connect(settings.database_url) as conn:
        with core_db.transaction(conn) as cur:
            yield cur


def get_current_user_id(x_user_id: str | None = Header(default=None)) -> UUID:
    """認証済みユーザーのID。

    **T-31（認証・アカウント基盤）が未実装のための仮実装。** 本来は Entra External ID
    が発行した JWT を検証して `users.external_subject` などから引く
    （`docs/02 §1.1`「認証済み」の前提、`docs/07-agent-roles.md` §7 が禁じているのは
    この検証ロジックを Implementation Lead が独自に設計すること）。

    ここでは `X-User-Id` ヘッダーで `users.id` を直接受け取るだけの、**ローカル開発・
    結合テスト専用の踏み台**。認可判断（このユーザーがこの投稿の作者か等）は
    エンドポイント側で必ず行うこと——ここはユーザーが誰かを言うだけで、
    それが正しいと保証しない。

    T-31 が実装されたら、この関数の中身だけを差し替える
    （呼び出し側のシグネチャ = `UUID` はそのまま使えるように設計してある）。
    """
    if x_user_id is None:
        raise HTTPException(status_code=401, detail="認証されていません（X-User-Id が無い）")
    try:
        return UUID(x_user_id)
    except ValueError as exc:
        raise HTTPException(status_code=401, detail="X-User-Id が UUID ではない") from exc
