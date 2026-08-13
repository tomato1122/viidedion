"""接続の作り方だけを持つ。クエリはドメイン側のモジュールに置く。

接続先は libpq の標準環境変数（PGHOST / PGPORT / PGUSER / PGDATABASE）か
DATABASE_URL で指定する。scripts/test.sh と同じ流儀に揃えてある。

Azure では Managed Identity でのトークン認証に差し替えるが（docs/04 SEC-AUTH-04）、
その分岐もここに閉じ込める。呼び出し側に接続文字列を組み立てさせない。
"""

from __future__ import annotations

import contextlib
import os
from collections.abc import Iterator

import psycopg

__all__ = ["connect", "transaction"]


def connect(dsn: str | None = None) -> psycopg.Connection:
    """接続を1本開く。

    DSN を明示しなければ DATABASE_URL、それも無ければ libpq の環境変数に任せる。
    """
    return psycopg.connect(dsn or os.environ.get("DATABASE_URL") or "")


@contextlib.contextmanager
def transaction(conn: psycopg.Connection) -> Iterator[psycopg.Cursor]:
    """1トランザクション = 1カーソル。

    スポット解決は「候補を引く → 無ければ作る」の読み書きが混ざるので、
    途中でコミットされると同じスポットが二重に作られる。
    トランザクション境界を呼び出し側の書き方に委ねない。
    """
    with conn.transaction():
        with conn.cursor() as cur:
            yield cur
