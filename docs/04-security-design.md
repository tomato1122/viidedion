# セキュリティ設計

> 残タスク T-03（不正対策の trust_score 化）・T-04（位置情報プライバシー）を含む、
> アプリ全体のセキュリティ設計。docs/02 §6 の骨子をここで正式化し、置き換える。
>
> **この文書は実装者（人間・AIを問わず）がこの文書だけを読んで実装できるように書いてある。**
> 各要件は `SEC-XX-nn` のIDを持ち、MUST（必須）/ SHOULD（推奨）を明記し、
> 受け入れ条件（どうなっていれば実装完了とみなすか)を付けている。
> 実装時は要件IDをコミットメッセージ・PRに引用すること。

---

## 0. 前提と全体方針

- 個人開発。運用者は1人。したがって「運用でカバー」は原則使えない —— **仕組みで守る**
- クラウドは Azure。構成は docs/02 の通り（Container Apps + Functions + Blob + PostgreSQL）
- 本アプリ固有のリスクは一般的なWebサービスと2点異なる:
  1. **位置情報が本質的なデータである**こと。漏らすと物理的な安全に直結する
  2. **スコアとランキングの信頼がプロダクト価値そのもの**であること。不正投稿・不正投票で
     ランキングが汚染されると、機能停止ではなく「価値の消滅」になる

### 0.1 守るべき資産（優先順）

| # | 資産 | 漏洩・毀損時の影響 |
|---|---|---|
| A1 | 原本画像のEXIF（撮影位置・時刻） | 自宅・行動パターンの特定。物理的安全への脅威 |
| A2 | ユーザーの位置履歴（posts.location の集合） | 同上。単発より集合のほうが危険 |
| A3 | 認証情報・セッション | アカウント乗っ取り |
| A4 | スコア・ランキングの完全性 | プロダクト価値の毀損（票の暴力・farming） |
| A5 | 生の合計点（表示ポリシー上の非公開情報） | 低スコア帯ユーザーの離脱（docs/00 §3） |
| A6 | インフラ資格情報（接続文字列・SASキー） | 全資産への横展開 |

### 0.2 想定する攻撃者

| 攻撃者 | 動機 | 主な経路 |
|---|---|---|
| 匿名の外部者 | スクレイピング、位置情報の収集、ストーカー行為 | 公開API・公開画像・推測可能なURL |
| 認証済みの不正ユーザー | スコアfarming、転載、位置偽装 | 投稿・投票API |
| 組織的な複数アカウント | 投票操作（ブリゲーディング） | 投票API・アカウント作成 |
| 攻撃的ボット | クレデンシャルスタッフィング、認証エンドポイントへの総当たり | 認証・API |
| 運用者自身のミス | 設定ミス・鍵の漏洩 | IaC・CI/CD・リポジトリ |

---

## 1. 認証・認可

### SEC-AUTH-01（MUST）ユーザー認証は Microsoft Entra External ID

コンシューマ向け認証は **Microsoft Entra External ID（外部テナント構成）** を使う。
自前のパスワード保存は行わない。

- Azure AD B2C は **2025年5月1日以降、新規顧客は購入不可**。新規はExternal ID一択
- サインイン方式: メール + パスワード、メールOTP、Apple / Google ソーシャルログイン
  （iOSアプリでソーシャルログインを出す場合、AppleのガイドラインによりSign in with Appleが実質必須）
- クライアントは MSAL を使い、Authorization Code Flow + PKCE。トークンをアプリが自前で保存する
  場合は OS のセキュア領域（Keychain / Keystore）のみ

**受け入れ条件**: パスワードに触れるコードがリポジトリに存在しない。トークン取得は MSAL 経由のみ。

### SEC-AUTH-02（MUST）APIのトークン検証

API（Container Apps 上の FastAPI）はすべてのリクエストで JWT アクセストークンを検証する。

検証項目（全部。1つでも欠けたら実装不備）:
1. 署名: External ID テナントの OIDC メタデータ（`/.well-known/openid-configuration`）から
   JWKS を取得して検証。**鍵はキャッシュし、kid 不一致時のみ再取得**（JWKSエンドポイントへの
   毎リクエスト問い合わせは禁止 = 可用性の自傷）
2. `iss`: 自テナントの issuer と完全一致
3. `aud`: 本APIのアプリケーションID と完全一致
4. `exp` / `nbf`: 時刻検証（clock skew 許容 300秒以内）
5. `scp` または `roles`: エンドポイントごとの要求スコープ

**受け入れ条件**: 上記5項目それぞれについて「不正なトークンが401になる」テストがある。

### SEC-AUTH-03（MUST）認可はリソース所有で判定する

- 投稿の編集・削除・公開範囲変更: `posts.author_id == token.sub` のときのみ許可
- **IDOR対策**: 全エンドポイントで「IDを知っていること」を認可と混同しない。
  UUIDは推測困難だが**共有・漏洩はする**ので、必ず所有チェックを通す
- 管理操作（レビューキュー処理、スポット統合、ユーザー凍結）は External ID の
  **アプリロール `moderator` / `admin`** で分離。個人開発でも自分の通常アカウントと
  管理ロールは分ける（普段使いのトークンで管理APIが呼べる状態にしない）

**受け入れ条件**: 「他人の投稿IDを指定した更新・削除が403になる」テストがある。

### SEC-AUTH-04（MUST）サービス間認証は Managed Identity に統一

docs/02 §6 の方針を要件化する。

| 経路 | 認証 | 無効化するもの |
|---|---|---|
| API / Functions / Worker → Blob | Managed Identity（RBAC: Storage Blob Data Contributor を必要コンテナに限定） | ストレージアカウントキー（`allowSharedKeyAccess=false`） |
| API / Functions / Worker → PostgreSQL | Managed Identity（Entra ID認証） | パスワード認証（`password_auth=off`） |
| API / Functions / Worker → Service Bus | Managed Identity | SASポリシー |
| CI/CD → Azure | GitHub OIDC フェデレーション | サービスプリンシパルのシークレット |

**受け入れ条件**: リポジトリ・環境変数・Key Vault のどこにも、上記経路の
接続文字列・キーが存在しない。IaC でキー無効化フラグが設定されている。

---

## 2. 画像アップロード経路

docs/02 §1.1 の SAS 直接アップロードをセキュリティ要件として固定する。

### SEC-UPL-01（MUST）SASの発行条件

- **User Delegation SAS のみ**（アカウントキーSASは物理的に発行不能 —— SEC-AUTH-04 でキー無効化済み）
- 権限: `create + write` のみ。read / list / delete は付けない
- 有効期限: **15分**
- 対象: `raw/{post_id}.jpg` の**単一Blobパス固定**（コンテナSASは発行しない）
- HTTPSのみ（`SasProtocol.HTTPS`）
- 発行は認証済みユーザーにつき **未commit の pending 投稿5件まで**。超過は 429

### SEC-UPL-02（MUST）アップロード内容の検証は ingest で行う

SASはサイズ・内容を制約できないため、検証は Event Grid → ingest Functions 側の責務とする。

1. サイズ: 25MB 超は拒否（Blob削除 + posts.status を失敗に）
2. マジックバイト検証: JPEG / HEIC / PNG 以外は拒否（**Content-Type ヘッダは信用しない**）
3. 画像としてデコード可能であること（デコーダはサンドボックス的に扱う —— 例外を握って失敗扱い。
   デコーダクラッシュで Functions ごと落ちるのを許容しない）
4. ピクセル爆弾対策: 解像度上限 12000×12000。超過は拒否
5. 検証通過後にのみ pHash・EXIF処理・採点キュー投入へ進む

### SEC-UPL-03（MUST）pending 投稿の掃除

commit されないまま 1時間経過した `posts.status='pending'` は行を失効させ、
対応する raw Blob があれば削除する（日次バッチ）。放置すると SAS発行枠の食い潰しと
ストレージのゴミが溜まる。

**受け入れ条件（§2全体）**: 「25MB超」「偽Content-Type」「非画像」「巨大解像度」の4ケースが
拒否されるテストがある。SAS発行APIに枠制限のテストがある。

---

## 3. ストレージとネットワーク

### SEC-STO-01（MUST）コンテナ構成とアクセスレベル

| コンテナ | 内容 | アクセス |
|---|---|---|
| `raw` | 原本（EXIF付き = A1資産） | 非公開。Managed Identity のみ。**匿名アクセス無効** |
| `derived` | 中間生成物 | 非公開。同上 |
| `public` | **EXIF除去済み**の配信用画像のみ | 配信経路からの read のみ |

- ストレージアカウント全体で `allowBlobPublicAccess=false` を基本とし、
  `public` の配信は Front Door（Private Link 経由）で行う
- **MVP期の暫定（Front Door 未導入の間）**: `public` コンテナのみ匿名 blob read を許可してよい。
  その場合の条件: (a) `public` に書けるのは ingest だけ（書き込みパスの一元化）、
  (b) EXIF除去の検証テスト（SEC-PRIV-01）が CI にあること、(c) コンテナの list は不可にする。
  これは**リスク受容として本文書に明記した上での暫定**であり、Front Door 導入時に閉じる

### SEC-STO-02（MUST）誤消去・改竄からの回復

- Blob の soft delete: 14日
- コンテナ soft delete: 14日
- `raw` はバージョニング有効（原本は再取得不能な一次データ）

### SEC-NET-01（MUST）データプレーンの閉域化

- PostgreSQL: プライベートエンドポイント。パブリックアクセス無効
- Service Bus / Storage（raw・derived）: プライベートエンドポイント、
  もしくは最低限サービスファイアウォールで Container Apps 環境のサブネットに限定
- Container Apps 環境は VNet 統合。API の ingress のみ外部公開

### SEC-NET-02（SHOULD）エッジ保護

- Front Door + WAF（マネージドルール + Bot Manager）。導入時期は T-29 の判断に従う
- **WAF が無い間も、レート制限は API 内で必ず実装する**（SEC-API-02）。
  エッジ保護の有無に依存する設計にしない

### SEC-NET-03（MUST）TLS

- 全エンドポイント TLS 1.2 以上。ストレージ・PostgreSQL の最小TLSバージョン設定を IaC で固定

**受け入れ条件（§3全体)**: IaC 上で各フラグ（匿名アクセス・soft delete・プライベート
エンドポイント・最小TLS）が明示されており、レビューで確認できる。

---

## 4. APIセキュリティ

### SEC-API-01（MUST）入力検証

- 全リクエストボディは Pydantic 等のスキーマで検証（未知フィールドは拒否 = mass assignment 対策）
- 座標: lat ∈ [-90,90], lon ∈ [-180,180]。方位: [0,360)。精度: ≥0
- 文字列長上限を全フィールドに設定（スポット命名 50字、プロフィール 300字 など）
- ページネーション: limit 上限 100。cursor ベース（offset の深掘りによる DB 負荷攻撃を防ぐ）

### SEC-API-02（MUST）レート制限

アプリ内で実装する（エッジに依存しない）。単位はユーザーID（未認証エンドポイントはIP）。

| 操作 | 制限（初期値） |
|---|---|
| 投稿 commit | 30件/日 |
| SAS発行 | 10回/時 + pending 5件（SEC-UPL-01） |
| 投票 | 200票/日、20票/分 |
| スポット命名提案 | 10件/日 |
| 読み取り系 | 60回/分 |

超過は 429 + Retry-After。制限値は設定で変えられるようにする（コード埋め込み禁止）。

### SEC-API-03（MUST）情報漏洩の防止

- エラー応答に内部情報（スタックトレース、SQL、内部ID構造）を含めない。
  本番は汎用メッセージ + 相関ID のみ
- **生の合計点・Elo・trust_score を返すエンドポイントを作らない**（docs/00 §3 表示ポリシー、
  および trust_score は攻撃者への正解フィードバックになるため）。
  APIが返してよいランキング情報は `v_post_display` ビュー由来のみ
- 存在推測対策: 他人の非公開投稿への GET は 403 ではなく **404** を返す（存在自体を秘匿）

### SEC-API-04（SHOULD）Webフロントエンドを持つ場合のヘッダ

`Content-Security-Policy`（default-src 'self' + 画像CDN）、`X-Content-Type-Options: nosniff`、
`Referrer-Policy: strict-origin-when-cross-origin`、Cookie は `HttpOnly; Secure; SameSite=Lax`。

**受け入れ条件（§4全体）**: レート制限とスキーマ検証の単体テストがある。
エラー応答のスタックトレース非含有が本番設定で保証されている。

---

## 5. 位置情報プライバシー（T-04 の設計）

**本アプリ最大の固有リスク。** 設計原則: **「スコア計算は正確な座標、表示は劣化した座標」**を
テーブル・ビューのレベルで分離し、アプリコードの気配りに依存させない。

### SEC-PRIV-01（MUST）EXIF除去の保証

- `public` コンテナに書き込む画像は、**EXIF・XMP・IPTC を全削除**した再エンコード品とする
- **CI テストで保証する**: GPS付きのテスト画像を ingest 相当の処理に通し、出力に
  Exifタグが1つも無いことを exiftool 等で検証するテストを必須にする
- 原本（raw）は削除しない（不正調査・再処理に必要）が、アクセスは SEC-STO-01 で閉じる

### SEC-PRIV-02（MUST）表示座標の劣化方式は「グリッドスナップ」

`location_privacy` の各レベルの実装を次で固定する:

| レベル | 表示座標 |
|---|---|
| `exact` | スポットの重心（**投稿の生座標は exact でも表示しない**。表示は常にスポット単位） |
| `coarse_500m` | 投稿地点を含む **H3 res8 セル（平均辺長531m）の中心** |
| `hidden` | 座標・スポット名とも非表示。ランキングにも地名を出さない |

**ランダムジッター（座標に乱数を足す方式）は禁止。** 同一地点の複数投稿を平均すると
元座標が復元できるため。グリッドスナップは決定的で、セル中心以上の精度に復元できない。

### SEC-PRIV-03（MUST）プライバシーゾーン（自宅保護）

Strava の privacy zone と同型の仕組みを実装する。

```sql
-- 0008 以降のマイグレーションで追加する（スキーマ仕様）
CREATE TABLE user_privacy_zones (
    id          bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    user_id     uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    center      geography(Point, 4326) NOT NULL,  -- ユーザーのみが知る。APIから読み返し不可
    radius_m    integer NOT NULL CHECK (radius_m BETWEEN 200 AND 2000),
    policy      location_privacy NOT NULL DEFAULT 'hidden',  -- 'exact' は不可（CHECKで禁止）
    created_at  timestamptz NOT NULL DEFAULT now()
);
```

- ユーザーは自宅・職場等に半径200m〜2kmのゾーンを最大5個設定できる
- **commit 時と publish 時の両方**で、投稿位置がゾーン内なら `location_privacy` を
  ゾーンの policy まで強制的に落とす（ユーザーが exact を選んでいても上書き）
- ゾーンを後から追加・拡大した場合、既存投稿に**遡及適用**するバッチを回す
- ゾーンの center / radius は**APIから読み返せない**（登録・削除のみ。一覧は「ゾーンあり」の
  真偽と作成日時だけ返す）。ゾーン自体が自宅位置の漏洩源になるため

### SEC-PRIV-04（MUST）保護地域・危険地点のブロックリスト

```sql
CREATE TABLE location_blocklist (
    id          bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    area        geography(Polygon, 4326) NOT NULL,
    reason      text NOT NULL,          -- 'protected_species' | 'hazard' | 'private_land' 等
    policy      text NOT NULL,          -- 'coarse' | 'hide_location' | 'reject'
    note        text,
    created_at  timestamptz NOT NULL DEFAULT now()
);
```

- 希少動植物の生息地・危険地点・立入禁止区域は運用者が手動登録（MVP）。
  データソースの選定（環境省データ等）は未決定事項として残す（§10）
- `reject` の区域は投稿自体を受け付けず、理由を返す（「この区域は保護のため投稿できません」）

### SEC-PRIV-05（MUST）保持・削除

- ユーザー削除（退会）: `users` 行削除で posts 以下 CASCADE。**Blob は夜間の突合バッチで削除**
  （DBに対応行の無い raw/derived/public Blob を削除）。完了まで最大24時間と規約に明記
- PostgreSQL の PITR バックアップ（7日）内には削除済みデータが残存する。
  規約に「削除後最大7日間バックアップに残存」と明記する
- ログに**生座標を書かない**（SEC-OPS-02）。位置のデバッグ情報が必要な場合は H3 res5
  （辺長約8.5km）までに落とす

### SEC-PRIV-06（SHOULD）写り込み対策

顔・車両ナンバーの検出を ingest に追加し、検出時は投稿者に公開前確認を出す
（自動ぼかしは Phase 2 以降。まず「検出 → 本人に確認」から始める）。
検出モデルは採点ワーカーと同じ ONNX ランタイムに同居可能。

**受け入れ条件（§5全体）**: SEC-PRIV-01 の CI テスト。ゾーン内投稿の強制ダウングレードと
遡及適用のテスト。「ジッター実装が存在しないこと」のコードレビュー項目化。

---

## 6. 投稿の信頼度 —— trust_score（T-03 の設計）

設計レビュー B-05 への回答。**「EXIFとハッシュで不正はほぼ潰せる」を放棄し、
複数シグナルの重み付き合成による段階判定に置き換える。**

### SEC-TRUST-01（MUST）シグナルと重み

trust_score ∈ [0.0, 1.0]。基準値 0.6 から各シグナルを加減算し clamp する。
重みは `trust_rulesets`（`scoring_rulesets` と同型のバージョン管理テーブル）に置き、
**コードに埋め込まない**。どの投稿がどのルールで判定されたか追跡可能にする。

| シグナル | 判定 | 加減算（初期値） |
|---|---|---|
| exif_present | GPS・撮影時刻のEXIFがある | +0.05 / 無し -0.05 |
| exif_location_match | EXIF位置と投稿位置の距離 ≤500m | +0.10 / 超過 **-0.25** |
| exif_time_match | EXIF時刻と投稿時刻の乖離 ≤7日 | +0.05 / 超過 -0.15 |
| duplicate_image | SHA-256完全一致 or pHashハミング距離≤6 が既存に存在 | **-0.60** |
| impossible_travel | 直前投稿との移動速度 >280m/s（≈1000km/h） | -0.30 |
| device_attestation | App Attest / Play Integrity 検証通過 | +0.15 / 失敗 **-0.40** / 未対応端末 0 |
| in_app_capture | アプリ内カメラで撮影された証跡 | +0.10 |
| account_age | 作成24時間未満 -0.10 / 30日以上 +0.05 | |
| user_history | ユーザー信頼度（下記EWMA）による ±0.10 | |

- **ユーザー信頼度**: 当該ユーザーの過去投稿の trust_score の指数移動平均（α=0.2）。
  投稿単位の判定にユーザーの履歴を薄く反映する
- impossible_travel は EXIF撮影時刻ベースで判定（投稿時刻ではない。旅行後のまとめ投稿を
  誤検知しないため）
- device_attestation はクライアント実装（T-20）後に有効化。それまでは重み0で表をそのまま使う

### SEC-TRUST-02（MUST）帯域と効果

| trust_score | 扱い |
|---|---|
| ≥ 0.70 | 通常。全機能 |
| 0.40 – 0.69 | **抑制**: 「初」ボーナス無効、希少性②×0.5（既存の `p_penalty_mult` を使用）、ランキング掲載は可 |
| < 0.40 | **保留**: 非公開 + レビューキュー行き。投稿者には「確認中」表示（不正の断定表現は使わない） |

- 既存スキーマとの接続: 帯域判定の結果を `calc_rarity_score(p_penalty_mult)` と
  `record_facet_post(p_eligible)` の引数に写す。**既存の関数シグネチャは変更不要**
- 誤検知への配慮: 抑制帯はユーザーに通知しない（サイレント抑制）。保留帯のみ通知する。
  抑制の透明性よりも、攻撃者に閾値を学習させないことを優先する（A4資産の保護）

### SEC-TRUST-03（MUST）スキーマ

```sql
-- 0008 以降のマイグレーションで追加する（スキーマ仕様）
CREATE TABLE trust_rulesets (            -- scoring_rulesets と同型
    id smallint PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    code text NOT NULL UNIQUE,
    is_active boolean NOT NULL DEFAULT false,
    weights jsonb NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE post_trust_scores (
    post_id     uuid PRIMARY KEY REFERENCES posts (id) ON DELETE CASCADE,
    ruleset_id  smallint NOT NULL REFERENCES trust_rulesets (id),
    trust_score real NOT NULL CHECK (trust_score BETWEEN 0 AND 1),
    signals     jsonb NOT NULL,   -- 各シグナルの生値と寄与。説明可能性のため必須
    band        text NOT NULL CHECK (band IN ('normal','restricted','held')),
    computed_at timestamptz NOT NULL DEFAULT now()
);
```

既存の `post_integrity_checks` は生シグナルの記録として残し、trust_score はその上の合成層とする。

**受け入れ条件（§6全体）**: 各シグナル単体のテスト + 帯域境界のテスト。
`signals` jsonb から寄与の内訳が復元できること。ルールセット差し替えで再計算が可能なこと。

---

## 7. 投票の完全性

### SEC-VOTE-01（MUST）ペアはサーバーが選ぶ

クライアントが比較ペアを指定できると、狙った投稿を持ち上げ/沈める攻撃が自明に成立する。

1. `GET /votes/next` がペアを選定し、**ペアトークン**（HMAC署名: voter_id + 両post_id + 発行時刻、
   TTL 10分）を返す
2. `POST /votes` はペアトークン必須。署名・TTL・voter一致を検証
3. 使用済みトークンの再利用は `votes` の既存ユニーク制約（voter × pair）が拒否する

### SEC-VOTE-02（MUST）票の重み制御

- 作成24時間未満のアカウントの票は **weight 0 で記録**（受け付けるが効かせない。
  拒否すると攻撃者に検知される —— シャドウバン方式）
- `users.vote_trust`（既存カラム）を投票の weight に乗算。異常パターン
  （特定ユーザーへの一方的連続投票、同一IPからの多アカウント投票）の検知で下げる
- 投票レート制限は SEC-API-02 の通り

### SEC-VOTE-03（SHOULD）検知

同一 post が短時間に受ける票の偏り（勝率が二項検定で p<0.01 の偏り + 投票者の
アカウント年齢分布の異常）を日次バッチで検出し、レビューキューに出す。自動処罰はしない。

**受け入れ条件**: ペアトークン無し/期限切れ/改竄の投票が拒否されるテスト。
新規アカウント票が Elo に影響しないテスト。

---

## 8. シークレット・設定・サプライチェーン

### SEC-OPS-01（MUST）シークレット管理

- 原則: **Managed Identity で「シークレットが存在しない」状態を目指す**（SEC-AUTH-04）
- どうしても残るもの（外部APIキー: Azure Maps 等）は Key Vault に置き、
  Container Apps / Functions からは Key Vault 参照で注入
- リポジトリに `.env` を含めない（`.gitignore` 済みであることを確認）。
  Push Protection（GitHub secret scanning）を有効化

### SEC-OPS-02（MUST）ログとPII

- 構造化ログ（Application Insights）。**生座標・EXIF値・トークン・メールアドレスをログに書かない**
- 位置のデバッグが必要な場合は H3 res5 までに丸めた値のみ
- 監査イベントとして必ず記録するもの: 認証失敗、認可失敗（403/404すり替え含む）、
  レート制限超過、trust_score 保留帯の発生、管理操作（レビュー処理・凍結・ブロックリスト変更）、
  SAS発行

### SEC-OPS-03（MUST）アラート（個人開発で現実的な最小セット）

| 条件 | 通知 |
|---|---|
| 認証失敗が 100回/5分 超 | 即時 |
| trust_score 保留帯が 10件/時 超 | 即時（攻撃 or 誤検知バグ） |
| レビューキュー滞留 > 48時間 | 日次 |
| 5xx率 > 1% | 即時 |

### SEC-OPS-04（SHOULD）依存関係・CI/CD

- Dependabot（または Renovate）有効化。コンテナベースイメージはダイジェスト固定
- CI から Azure へのデプロイは GitHub OIDC フェデレーション（シークレットレス）。
  デプロイ用IDの権限は対象リソースグループの Contributor までに限定
- main への直接 push 禁止、PR 必須（自分しかいなくても —— レビューは自分でやる、が
  CI のテスト通過を機械的なゲートにする）

---

## 9. インシデント対応（1人運用の現実解）

事前に「切る場所」を決めておく。インシデント時に考えることを最小化する。

| 事象 | 即時対応（順に実行） |
|---|---|
| 資格情報の漏洩疑い | ① 該当IDの無効化（Entra）→ ② Key Vault のキーローテート → ③ 監査ログで使用履歴確認 |
| 位置情報の漏洩疑い | ① `public` の該当Blobを削除 → ② CDN/Front Door キャッシュパージ → ③ 該当ユーザーへ通知 |
| スコア汚染（farming成立） | ① 該当アカウント凍結（vote_trust=0, 投稿非公開）→ ② 影響ファセットのランキング再生成（`rebuild_ranking_entries` は冪等）→ ③ trust_rulesets の重み修正 |
| API へのDoS的負荷 | ① レート制限値を設定で絞る → ② 必要なら ingress を一時停止（採点済みデータは無傷） |

- 汚染からの回復可能性はアーキテクチャで既に担保されている:
  **votes は生ログ、Elo は再計算可能、ランキング再生成は冪等**。
  「不正票を除外して全部作り直す」が最悪ケースの復旧手順として常に成立する

---

## 10. 未決定のまま残した点

| 論点 | 現状 | 判断に必要なもの |
|---|---|---|
| 保護地域データのソース | 手動ブロックリストで開始 | 環境省・自治体データの利用条件調査 |
| device attestation の導入時期 | 重み0で表だけ用意 | クライアント実装方式（T-11/T-20）の確定 |
| 顔・ナンバー検出のモデル | 未選定 | ONNX で動く軽量モデルの精度比較 |
| WAF導入時期 | API内レート制限で開始 | T-29（Front Door判断）と同時 |
| 通報機能 | 本設計には含めず | プロダクト仕様（Phase 3）side で設計 |

---

## 11. 実装チェックリスト（他モデル向けの入口）

実装を引き継ぐ際は、この順で着手すること。各項目は独立して PR にできる。

1. ~~**SEC-TRUST-03 のマイグレーション**（trust_rulesets / post_trust_scores /
   user_privacy_zones / location_blocklist）~~ **✅ 完了（`0011_trust_and_privacy.sql`）**
   - `calc_trust_score()` が閾値の適用まで行う（閾値も `trust_rulesets` に入れた）
   - `trust_penalty_mult()` / `trust_first_bonus_eligible()` が帯域を既存の
     `calc_rarity_score(p_penalty_mult)` / `record_facet_post(p_eligible)` に橋渡しする
   - `resolve_location_privacy()` がユーザー選択・ゾーン・ブロックリストの
     **最も厳しいもの**を返す。`reapply_privacy_zones()` が遡及適用する
   - **SEC-PRIV-02 の実装は仕様から一段強めた。** 投稿に表示座標を持たせず、
     `h3_cell_centers`（セルごとに1行）を引く形にしたので、
     **投稿ごとにジッターを入れる場所が構造として存在しない**
   - 座標を返してよいのは `v_post_location_public` だけ
2. **SEC-PRIV-01 の CI テスト**（EXIF除去検証）。ingest 実装（T-13）より先に
   テストだけ書いておく（実装がテストを追う形にする）
3. **SEC-AUTH-02 のトークン検証ミドルウェア**（API 実装 T-19 の最初のコミット）
4. **SEC-API-02 のレート制限**（T-19 内）
5. **SEC-VOTE-01 のペアトークン**（T-19 内）
6. **SEC-TRUST-01/02 の呼び出し**（T-13 内）。判定関数そのものは 1 で実装済み。
   残るのは `post_integrity_checks` の生値を `calc_trust_score()` の入力 jsonb に
   組み立てる部分と、`device_attestation` の有効化（T-20 のクライアント実装後）
7. IaC を書く際に §3 のフラグ群を最初から入れる（後付けは事故る）

各PRは対応する SEC-ID を本文に記載し、受け入れ条件のテストを含めること。
