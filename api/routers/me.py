"""自分のマイページ用エンドポイント。

**生の合計点は返さない**（`v_user_personal_best` 経由。`docs/00 §3` 変更禁止 /
`docs/07-agent-roles.md` §7）。`v_user_personal_best_internal` は絶対に使わない。
"""

from __future__ import annotations

from uuid import UUID

import psycopg
from fastapi import APIRouter, Depends

from ..deps import get_current_user_id, get_db
from ..schemas import PersonalBestEntry

router = APIRouter(prefix="/me", tags=["me"])


@router.get("/personal-best", response_model=list[PersonalBestEntry])
def personal_best(
    cur: psycopg.Cursor = Depends(get_db),
    user_id: UUID = Depends(get_current_user_id),
) -> list[PersonalBestEntry]:
    cur.execute(
        """
        SELECT grain_version_id, best_post_id, achieved_at
          FROM v_user_personal_best
         WHERE author_id = %s
         ORDER BY grain_version_id DESC
        """,
        (user_id,),
    )
    return [
        PersonalBestEntry(grain_version_id=g, best_post_id=p, achieved_at=a)
        for g, p, a in cur.fetchall()
    ]
