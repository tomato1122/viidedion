"""API のリクエスト/レスポンスモデル。

**生の合計点・Elo・trust_score・raw location はどのモデルにも入れない**
（`docs/04` SEC-API-03 / SEC-PRIV-02、`docs/07-agent-roles.md` §7）。
公開してよい列だけを持つ DB ビュー（`v_spot_public` 等）の列と1対1で揃える。
"""

from __future__ import annotations

import datetime
from uuid import UUID

from pydantic import BaseModel


class MapCluster(BaseModel):
    h3_cell: str  # h3-py の文字列表現で返す。bigintのままJSONに乗せると精度が壊れるため
    lat: float
    lon: float
    spot_count: int
    post_count: int
    has_named_spot: bool


class SpotDetail(BaseModel):
    identity_id: UUID
    slug: str
    display_name: str | None
    name_source: str | None
    source_code: str | None
    attribution_text: str | None
    lat: float
    lon: float
    kind: str | None
    post_count: int
    distinct_user_count: int
    bearing_split_enabled: bool | None
    first_post_at: datetime.datetime | None
    last_post_at: datetime.datetime | None


class UploadCreated(BaseModel):
    post_id: UUID
    upload_url: str


class PostCommitRequest(BaseModel):
    lat: float
    lon: float
    gps_accuracy_m: float | None = None
    bearing_deg: float | None = None
    bearing_src: str | None = None
    captured_at: datetime.datetime
    location_privacy: str = "exact"


class PostCommitResult(BaseModel):
    post_id: UUID
    status: str


class PersonalBestEntry(BaseModel):
    grain_version_id: int
    best_post_id: UUID
    achieved_at: datetime.datetime
