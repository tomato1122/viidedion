"""アップロード用 User Delegation SAS の発行（`docs/02 §1.1`）。

- アカウントキーではなく **User Delegation SAS**（Entra ID裏付け）を使う
- 書き込みのみ・有効期限は短く・パスは `raw/{post_id}.jpg` に固定する
- 実際のキー取得は Managed Identity 経由（`azure-identity` の `DefaultAzureCredential`）

Azure SDK はこのモジュールの内側でだけ import する。ローカル開発・CI では
Azure 資材（ストレージアカウント・Managed Identity）が無いのが通常なので、
モジュールの import 自体が失敗しないようにする。
"""

from __future__ import annotations

import datetime
from uuid import UUID

from .config import Settings


class BlobConfigurationError(RuntimeError):
    """本番相当のBlob設定が無いのに実際のSASを要求されたときに送出する。"""


def blob_path(post_id: UUID) -> str:
    return f"raw/{post_id}.jpg"


def issue_upload_sas(post_id: UUID, settings: Settings) -> str:
    """書き込み専用・短時間有効の User Delegation SAS 付き URL を返す。

    `settings.storage_account_url` が未設定のときは、**ローカル開発専用の
    プレースホルダURL**を返す（Azure ストレージが無い環境でも `POST /uploads`
    の呼び出し自体は完結させるため）。本番はこの分岐に絶対に入らないこと
    —— T-06/T-22（Azureプロビジョニング）が済めば `storage_account_url` が
    必ず設定されるので、設定漏れの検知にもなる。
    """
    if settings.storage_account_url is None:
        return f"http://localhost/dev-upload-placeholder/{blob_path(post_id)}"

    # 遅延import: azure-identity / azure-storage-blob が入っていない環境でも
    # このファイルの他の関数（blob_path 等）とAPI全体の起動を壊さない。
    from azure.identity import DefaultAzureCredential
    from azure.storage.blob import (
        BlobSasPermissions,
        BlobServiceClient,
        generate_blob_sas,
    )

    credential = DefaultAzureCredential()
    service = BlobServiceClient(account_url=settings.storage_account_url, credential=credential)

    now = datetime.datetime.now(datetime.timezone.utc)
    expiry = now + datetime.timedelta(minutes=settings.upload_sas_ttl_minutes)
    delegation_key = service.get_user_delegation_key(key_start_time=now, key_expiry_time=expiry)

    account_name = service.account_name
    if account_name is None:
        raise BlobConfigurationError("BlobServiceClient からアカウント名が取れない")

    sas_token = generate_blob_sas(
        account_name=account_name,
        container_name=settings.storage_raw_container,
        blob_name=blob_path(post_id),
        user_delegation_key=delegation_key,
        permission=BlobSasPermissions(write=True, create=True),
        expiry=expiry,
        start=now,
    )

    blob_url = (
        f"{settings.storage_account_url.rstrip('/')}/"
        f"{settings.storage_raw_container}/{blob_path(post_id)}"
    )
    return f"{blob_url}?{sas_token}"
