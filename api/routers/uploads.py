"""アップロード〜投稿コミット（`docs/02 §1.1`）。

`POST /uploads` → `PUT <SAS URL>`（クライアントから直接Blobへ）→ `POST /posts/{id}/commit`
の3段。画像本体はAPIコンテナを通さない。

**実装上の判断（DESIGN_DECISION_REQUIRED相当。Architecture Lead 未確認）**:
`posts.captured_at` は `NOT NULL` でデフォルトが無いが、`docs/02` の設計では
`POST /uploads` の時点（＝撮影時刻がまだ分からない時点）で `posts` 行を作成することに
なっている。スキーマとドキュメントのこの不整合は今回の実装で初めて踏んだ
（マイグレーション変更はImplementation Leadの権限外 — `docs/07` §6）。

**採った回避策**: 作成時は `captured_at = now()` を仮値として入れ、
`commit` で必ず実測値に上書きする。スキーマは一切変えていない。
`location` が NULL の間は `core.spots.bind_post` が呼ばれても例外になるため
（値を要求する）、commit前の行が誤って採点パイプラインに入ることはない。
**この判断はArchitecture Leadのレビュー待ち**（`docs/03` に記録済み）。
"""

from __future__ import annotations

import datetime
from uuid import UUID

import psycopg
from fastapi import APIRouter, Depends, HTTPException

from ..blob import issue_upload_sas
from ..config import get_settings
from ..deps import get_current_user_id, get_db
from ..schemas import PostCommitRequest, PostCommitResult, UploadCreated

router = APIRouter(tags=["uploads"])


@router.post("/uploads", response_model=UploadCreated, status_code=201)
def create_upload(
    cur: psycopg.Cursor = Depends(get_db),
    user_id: UUID = Depends(get_current_user_id),
) -> UploadCreated:
    settings = get_settings()

    try:
        cur.execute(
            """
            INSERT INTO posts (author_id, status, captured_at)
            VALUES (%s, 'pending', now())
            RETURNING id
            """,
            (user_id,),
        )
    except psycopg.errors.ForeignKeyViolation as exc:
        # get_current_user_id はヘッダーの値をそのまま信じるだけの仮実装（T-31待ち）なので、
        # 存在しないユーザーIDが渡ってくる経路がある。ここで確実に401へ変換する
        raise HTTPException(status_code=401, detail="ユーザーが存在しない") from exc
    post_id = cur.fetchone()[0]

    upload_url = issue_upload_sas(post_id, settings)

    cur.execute(
        "UPDATE posts SET raw_blob_path = %s WHERE id = %s",
        (f"raw/{post_id}.jpg", post_id),
    )

    return UploadCreated(post_id=post_id, upload_url=upload_url)


@router.post("/posts/{post_id}/commit", response_model=PostCommitResult)
def commit_post(
    post_id: UUID,
    body: PostCommitRequest,
    cur: psycopg.Cursor = Depends(get_db),
    user_id: UUID = Depends(get_current_user_id),
) -> PostCommitResult:
    cur.execute("SELECT author_id, status FROM posts WHERE id = %s", (post_id,))
    row = cur.fetchone()
    if row is None:
        raise HTTPException(status_code=404, detail="投稿が見つからない")

    author_id, status = row
    if author_id != user_id:
        # 存在は伏せない設計にはしていない（他人の post_id を推測しても404と409しか
        # 返らないため slug/idの探索コストを上げる必要が薄い）。ここは403で明示する。
        raise HTTPException(status_code=403, detail="この投稿の作者ではない")
    if status != "pending":
        raise HTTPException(status_code=409, detail=f"status={status} の投稿はコミットできない")

    if body.captured_at.tzinfo is None:
        raise HTTPException(status_code=422, detail="captured_at はタイムゾーン付きで送ること")
    if body.captured_at > datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(minutes=5):
        raise HTTPException(status_code=422, detail="captured_at が未来すぎる")

    try:
        cur.execute(
            """
            UPDATE posts SET
                location         = ST_SetSRID(ST_MakePoint(%s, %s), 4326)::geography,
                gps_accuracy_m   = %s,
                bearing_deg      = %s,
                bearing_src      = %s::bearing_source,
                captured_at      = %s,
                location_privacy = %s::location_privacy
            WHERE id = %s
            """,
            (
                body.lon,
                body.lat,
                body.gps_accuracy_m,
                body.bearing_deg,
                body.bearing_src,
                body.captured_at,
                body.location_privacy,
                post_id,
            ),
        )
    except (psycopg.errors.CheckViolation, psycopg.errors.InvalidTextRepresentation) as exc:
        raise HTTPException(status_code=422, detail=str(exc).splitlines()[0]) from exc

    return PostCommitResult(post_id=post_id, status=status)
