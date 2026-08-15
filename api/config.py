"""API の設定。環境変数から読む（`docs/02` の Managed Identity 前提と揃える）。

接続文字列やアカウント名をコードに埋めない。Azure では Container Apps の環境変数と
Managed Identity 経由のシークレットレス接続に差し替える（`docs/04 SEC-AUTH-04`）。
"""

from __future__ import annotations

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="", extra="ignore")

    database_url: str | None = None

    # Blob Storage（docs/02 §1.1 のアップロード先）。
    # 未設定のときは issue_upload_sas がローカル開発用のプレースホルダURLを返す
    # （api/blob.py のコメント参照）。本番は3つとも必須。
    storage_account_url: str | None = None
    storage_raw_container: str = "raw"
    upload_sas_ttl_minutes: int = 15


def get_settings() -> Settings:
    return Settings()
