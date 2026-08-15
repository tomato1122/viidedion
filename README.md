# viidedion

景色特化SNSアプリ。撮影した風景写真に得点をつけ、**「場所」を評価の軸に置く**ことで
誰でもどこかで1位を取れる状態を作る。

> Instagram は**フォロワー数が権力になる**構造で、後発ユーザーが勝てない。
> 本アプリは「1位の椅子を大量に用意する」ことを設計の根幹に置く。
> スポット別 × 天候別 × 時間帯別 × 季節別に枠を切り、毎週リセットする。

## ドキュメント

| | 内容 |
|---|---|
| [docs/00-original-handoff.md](docs/00-original-handoff.md) | 元の設計引継ぎ書（プロダクト方針・スコア設計・表示ポリシー・研究的根拠） |
| [docs/01-spot-granularity.md](docs/01-spot-granularity.md) | **スポット粒度設計** — 同定アルゴリズム、方位セクター、粒度バージョニング、再計算ジョブ |
| [docs/02-azure-architecture.md](docs/02-azure-architecture.md) | **Azureインフラ構成** — 採点パイプライン、推論ホスティング、データストア選定、③の遅延集計 |
| [docs/03-remaining-tasks.md](docs/03-remaining-tasks.md) | **残タスク一覧** — レビュー指摘の未対応分を含む |
| [docs/04-security-design.md](docs/04-security-design.md) | **セキュリティ設計** — 認証、位置情報プライバシー、trust_score、投票の完全性 |
| [docs/05-product-decisions.md](docs/05-product-decisions.md) | **プロダクト決定記録** — P-01〜P-08 は決定済み。未決定は P-09（安全・誘導リスク）のみ |
| [docs/06-adr-poi-source.md](docs/06-adr-poi-source.md) / [docs/adr/](docs/adr/) | **ADR** — POIソース（ADR-001）、ランキング期間（ADR-0001）、比較ペア構成（ADR-0004）ほか |
| [docs/07-agent-roles.md](docs/07-agent-roles.md) | **AIエージェント役割分担・並行開発ルール** |

## 実装

| | 内容 |
|---|---|
| [db/migrations/](db/migrations/) | PostgreSQL 16 + PostGIS のスキーマ（0001〜0007） |
| [db/tests/smoke_test.sql](db/tests/smoke_test.sql) | スキーマと関数の振る舞い検証（46アサーション） |
| [scoring/facets.py](scoring/facets.py) | ファセット導出規則（方位セクター・時間帯・季節・フラクタル選好曲線） |
| [scoring/tests/](scoring/tests/) | 同上のテスト（33ケース） |

## 設計上の3つの不変条件

粒度定義を変更すると過去の希少性スコアが全て変わる。以下を守っている限り、
粒度は後からいくらでも変更できる（詳細は [docs/01 §0](docs/01-spot-granularity.md)）。

1. **`posts` は観測事実だけを持ち、スポットIDを持たない**
2. **投稿とスポットの紐付けは `(post_id, grain_version_id)` の交差テーブルに置く**
3. **希少性スコアもランキングも `grain_version_id` を持つ**

粒度変更 = 新しいバージョンで全件を別レコードとして再計算し、最後にアクティブポインタを
差し替える（Blue-Green）。既存行は一切書き換えない。

## 表示ポリシー（変更禁止）

絶対評価の点数を晒すと、低スコア帯のユーザーから静かに離脱する。

- **生の合計点は非公開**（`v_post_total_score` は内部専用。APIから返さない）
- 表示は相対指標のみ（`v_post_display` だけを公開する）
- **減点・下位順位は一切表示しない**（上位50%に入らなければ順位は `NULL`）

この方針はスキーマ側でビューとして実装してある。`ranking_entries` を直接引くと
生の合計点と下位順位が漏れるため、API からは必ず `v_post_display` を使うこと。

## テスト

```bash
./scripts/test.sh                       # Python のみ
PGHOST=/tmp PGPORT=5432 PGUSER=postgres ./scripts/test.sh   # + PostgreSQL
```

PostgreSQL のテストには PostGIS 拡張が使えるサーバーが必要。

## 次のタスク

- クライアント実装（EXIF `GPSImgDirection` の取得可否を実機で確認するのが先）
- ①AI採点ワーカー（ONNX Runtime + Scenic-Or-Not 転移学習）の実装
- スポット解決フローの実装（`h3-py` + Azure Maps POI）
- 未決定事項は各ドキュメントの末尾「未決定のまま残した点」を参照
