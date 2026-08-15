"""API エントリポイント（T-19）。

`docs/07-agent-roles.md` §16 の再開条件に従い、**投票・フォロー関連のエンドポイントは
含めない**（ADR-0004 の `pair_tier` 実装・自己投票拒否・T-31 認証が終わるまで）。
含めたのは地図クラスタ・スポット詳細・SAS発行・投稿コミット・自己ベストのみ。
"""

from __future__ import annotations

from fastapi import FastAPI

from .routers import me, spots, uploads

app = FastAPI(title="viidedion API")

app.include_router(spots.router)
app.include_router(uploads.router)
app.include_router(me.router)


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok"}
