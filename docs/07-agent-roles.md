# AIエージェント役割分担・並行開発ルール v1.0

> Notion の [🧭 AIエージェント役割分担・並行開発ルール v1.0](https://app.notion.com/p/3bd7066098c28133a2ecd14c7719d265) が正。
> このファイルはリポジトリ側の写し。**Notion側を更新したら、このファイルも合わせること**
> （逆も同様。CLAUDE.md の「タスクの状態が変わったら docs/03 と Notion の両方を合わせる」と同じ原則）。
>
> 2026-08-22: 初回ミラー作成。作成の経緯は本ファイル末尾「ミラー作成の経緯」を参照。

複数AIエージェントを並行利用するための運用ルール。**エージェント名ではなく役割を正とする。**
実装速度より、後から直しにくい判断の一貫性と、ブランチ・マイグレーション衝突の防止を優先する。

## 1. 役割

| 役割 | 現在の担当 | 主な責任 |
|---|---|---|
| Product Owner | 開発者 | プロダクト価値、UX優先度、コスト対体験、公開方針などの最終判断 |
| Architecture Lead | ChatGPT | ADR、NFR、セキュリティ、DB不変条件、マイグレーション設計、設計レビュー、実装承認 |
| Implementation Lead | Claude | 承認済み設計の実装、API・worker・jobs等の実装、テスト、CI、リファクタ |
| Research & Validation Lead | Gemini | 一次資料、論文、料金、ライセンス、外部仕様、比較検証 |
| Sub Implementation Agent | Codex等 | 明確に閉じた実装タスク、テスト追加、CI、機械的修正 |

役割は将来別のAIへ交代してよい。**「Claudeだから設計を決められる」「ChatGPTだから実装できない」
といったエージェント名依存のルールは作らない。**

## 2. 分担の軸 — 「後から直しにくいか」

判断の境界は、変更を後から修正したときに過去データ・ユーザー体験・セキュリティ・説明責任へ
影響するかで決める。

### Architecture Lead の承認が必須

- プロダクト決定に技術的影響を与える設計
- ADR の作成、変更、Accepted 判定
- DBスキーマ、マイグレーション番号、制約、移行順序
- セキュリティ設計、権限、位置情報・個人情報の扱い
- 不変条件 I-1〜I-3 に触れる実装
- spot identity / lineage / grain version / 再計算方式
- ランキング成立条件、比較アルゴリズム、スコアの意味
- 表示ポリシー実装、生スコア非公開、位置情報公開レベル
- Azureサービス選定、NFR、RTO/RPO、コスト構造
- 後方互換性・データ移行・rollback方針

### Implementation Lead / Sub Agent が単独で進めてよい

- `docs/03-remaining-tasks.md` でスコープと完了条件が閉じている実装
- API scaffolding
- 既存設計に沿った handler / service / repository 実装
- worker / jobs の既定仕様どおりの実装
- テスト追加
- ロジック不変のリファクタ
- lint / CI / formatter / build 設定
- 誤字、リンク切れ等の内容判断を伴わない修正

**実装中に設計判断が必要になった時点で、そのタスクは「閉じた実装」ではなくなる。そこで停止する。**

## 3. Source of Truth

設計判断の優先順位は以下とする。

1. main に統合済みの Accepted ADR
2. Product Decisions
3. Security Design
4. Architecture Docs
5. Remaining Tasks
6. 古いREADME・コメント

**main を Accepted state とする。** branch上だけに存在する ADR や設計文書は
Proposed / Working Copy であり、main へ統合されるまで他タスクの確定前提にしてはならない。

Notion は共有・レビュー・Claude との連携に使うが、Repository と Notion が食い違った場合に
黙って片方を採用してはならない。更新時刻・Status・main統合有無を確認して差分を解消する。

## 4. Branch Baseline Invariant — 分岐事故を再発させない

**新しい実装作業は必ず最新 `origin/main` を基点に開始する。**

着手前に必ず以下を確認する。

1. `origin/main` を最新化する
2. 作業branchが最新mainを包含していることを確認する
3. branchがmainよりbehindしている場合、実装を開始しない
4. 大きくdivergeした古いbranch上で、新しいADRやmigrationを再実装しない
5. 古いbranchに必要な設計変更がある場合は、mainへ必要差分だけを移植する

**既存branchを「作業を続けているから」という理由だけで基準にしない。**

### 新タスク開始の原則

```
origin/main
  ↓
最新mainから新規branch
  ↓
1タスクまたは明確な変更単位
  ↓
PR
  ↓
main
```

## 5. ADR のルール

- branch上では `Proposed` を作成できる
- `Accepted` への変更は Product Owner / Architecture Lead の承認を必要とする
- **main へ統合されて初めて正式な Accepted state とみなす**
- Accepted ADR を覆す場合、既存ADRを黙って書き換えず、新しいADRで置き換える
- Implementation Lead / Sub Agent は独自判断で ADR を作成・Accepted化しない

Claude が実装中に ADR 相当の判断が必要だと気づいた場合は、実装を止めて
Architecture Lead へ提案する（§8 の形式）。

## 6. DBマイグレーション — 最重要衝突防止ルール

`db/migrations/` は **連番・追記のみ** とする。

### Architecture Lead が所有するもの

- 新規migrationが必要かの判断
- migration番号
- schema design
- table / column / constraint / index
- expand → deploy → contract の移行順序
- backward compatibility
- rollback / recovery方針
- data lossリスク評価

### Implementation Lead が実行してよいもの

Architecture Lead から**明示的に承認された migration specification または patch**がある場合、
その内容を Repository へ反映してよい。

Implementation Lead / Sub Agent が独自に以下を行ってはならない。

- 新しい migration 番号を採番する
- 新規 table / column / constraint を追加する
- 既存 migration を書き換える
- 「まだ本番データが無いから」という理由で破壊的変更を自己判断する

### 採番直前チェック

新しい migration を作成する直前に、必ず**最新 origin/main の最大 migration 番号を再確認する。**

サブ実装中にschema変更が必要になった場合はコードを書かず、§8 の提案経路へ切り替える。

## 7. Claude / Implementation Lead の実装境界

Claude は設計を大量に再決定する役ではなく、**承認された設計を高品質にコードへ落とす責任者**とする。

### そのまま進めてよい例

- T-19 API scaffolding
- 既存ADRに従ったendpoint実装
- service層の実装
- DTO / validation
- テスト
- CI
- 既存DB APIを利用するrepository

### その場で停止する条件

以下に遭遇したら実装を止め、Architecture Lead へ戻す。

- migrationが必要
- 新しいDB制約が必要
- Accepted ADRとコードが矛盾する
- セキュリティ要件を変える必要がある
- SAS / JWT / Managed Identity等の権限設計を変える
- raw locationや生スコアをAPIへ返したくなる
- `ranking_entries` / `v_post_total_score` を公開APIから直接利用したくなる
- spot identity / lineage / grain versionの意味を変える
- ランキング・投票・発見表示の意味を変える
- Product Decisionが必要

## 8. 設計判断が必要になった場合の提案経路

Implementation Lead / Sub Agent は、設計判断が必要な状況を発見した場合、コードで先に解決しない。
以下の形式で Architecture Lead へ渡す。

```
DESIGN_DECISION_REQUIRED

気づいた状況:
- 何を実装中に、どの問題へ到達したか

影響範囲:
- ADR / Security / DB / I-1〜I-3 / 表示ポリシー / Product Decision のどれか

現在の実装への影響:
- 止まっている箇所
- 既存仕様との矛盾

提案:
- A案
- B案
- 推奨案（あれば）

判断されるまで:
- 該当部分は実装しない
- 推測でschemaや仕様を固定しない
```

Architecture Lead は提案を黙って却下しない。採用しない場合も理由を返す。

## 9. Product Owner へ上げる条件

以下は Architecture Lead だけで確定しない。

- UX優先度
- コスト vs 体験
- 収益モデル
- プライバシーポリシー
- ユーザー向けランキング表現
- 発見者・称号・バッジ
- 通知
- プロダクト価値そのものを変える判断

この場合は以下を出す。

```
PRODUCT_DECISION_REQUIRED

論点:
A:
B:
推奨:
理由:
影響:
```

## 10. PR / コミット

- 各エージェントは自分専用branchを使う
- 同一branchへの複数エージェント同時pushは禁止
- branchは必ず最新mainから作成する
- コミットメッセージには `T-xx` / `ADR-xxxx` / `SEC-XX-nn` のいずれかを可能な限り含める
- 1PRに無関係な設計変更と実装変更を混在させない
- mainへの統合前にArchitecture Leadが境界チェックを行う

### PRでArchitecture Leadが確認すること

- Accepted ADRとの一致
- backward compatibility
- migration safety
- data loss
- constraint / index
- migration order
- PostGIS
- split / merge lineage
- spot identity
- ranking fallback
- security / privacy
- tests

レビュー結果は以下で分類する。

- **MUST FIX** — merge不可
- **SHOULD FIX** — 原則修正
- **NICE TO HAVE** — 後続でも可

## 11. docs/03 と Notion の同期

`docs/03-remaining-tasks.md` と Notion 残タスク一覧は同じ状態を維持する。

Implementation Lead / Sub Agent は branch 上の `docs/03` へ担当・提案・進捗を書いてよい。
ただし、**main へ merge する前に Notion との同期を完了することを merge gate とする。**
未同期状態で main へ入れない。

Notionのみ、Repositoryのみを更新して完了扱いにしない。

**Notion 側の記述が repo（main）に無い実体（migration・コード・ファイル）を「完了」と
主張している場合、それは Notion の誤記または未マージの Working Copy であり、main を正として
Notion を修正する。** 実体がどこにあるか不明な場合は Product Owner に確認する
（2026-08-22 の教訓。本ファイル末尾参照）。

## 12. Research & Validation Lead

Gemini等のResearch AgentはコードやADRを確定しない。以下をArchitecture Leadへ返す。

- Evidence
- Source
- Assumptions
- Counter evidence
- Project fit
- Current limitations / pricing / licensing

Architecture Leadは、Research結果をそのまま採用せず、**何を確認するためのEvidenceだったかを
明示して設計判断へ統合する。**

## 13. 現在のScenery SNSで特に守るもの

以下は現時点で変更容易性が低く、Implementation Agentが自己判断で変更しない。

- 全国 × ライトユーザー
- 地図ファースト
- スポットのみフォロー
- 投稿フロー内の比較投票（スキップ可）
- captured_atベース + 30日猶予
- POI由来未踏スポットの先置き
- ランキングより「発見」を重要価値とする
- POI source = OpenStreetMap
- spot identity / lineageをgrain versionから分離
- 不変条件 I-1〜I-3
- 生スコア非公開
- raw location非公開

これらを変更する必要が生じたら、実装変更ではなく設計判断として扱う。

## 14. 作業開始チェックリスト

Implementation Lead / Sub Agentは、新しいタスクに着手する前に以下を確認する。

- [ ] 最新 `origin/main` を取得した
- [ ] branchは最新mainから作られている
- [ ] `docs/03` のタスクIDと完了条件を確認した
- [ ] Accepted ADRを確認した
- [ ] Security Designに該当要件がないか確認した
- [ ] 新規migrationが不要であることを確認した
- [ ] Product Decisionを暗黙に変更していない
- [ ] public APIが生スコア・raw locationを返していない

1つでも判断できない場合、実装を始めずArchitecture Leadへ確認する。

## 15. 分岐事故からの恒久ルール

過去に、古い共通commitから分岐したbranchで、mainに既に存在する `0008〜0014` と別系列の
`0008〜0012` が作成される事故が起きた。この再発防止として、以下を恒久ルールとする。

1. **mainがAccepted state**
2. **新規作業は最新mainから開始**
3. **migration採番はArchitecture Leadが所有**
4. **採番直前に最新mainを再確認**
5. **divergeしたbranch上で設計を再実装しない**
6. **必要な差分だけをmain基準で移植する**

速度よりも「1本の正しい歴史」を優先する。複数エージェントを使う目的は判断を並列化することでは
なく、**役割を分けて実装速度と検証密度を上げること**である。

## 16. T-19 API再開条件

T-19 API scaffoldingはImplementation Leadへ委任可能な閉じた実装タスクである。
ただし、以下を満たしてから開始する。

1. recovery / reconciliationが完了している
2. Accepted ADRがmain基準で参照できる
3. 作業branchを最新mainから新規作成している
4. API scaffolding中にschema変更を行わない
5. 認証・位置情報・ランキング公開仕様に新判断が必要なら停止する

条件を満たした後は、ClaudeはT-19へ戻ってよい。

---

## ミラー作成の経緯（2026-08-22）

Notion「残タスク一覧」ページが、本リポジトリのどのブランチ・PRにも存在しない完了実体
（M-1/M-6 修正の migration `0015`、T-19 の `api/` 部分実装、この `docs/07-agent-roles.md`
自体）を「完了」として記載していたことが発覚した。`main` と `claude/new-session-6tt4vk` /
`claude/multiple-sessions-claude-md-check-gkb0td` のいずれにも該当コミットが無いことを
`git ls-tree` で確認済み。

Product Owner の判断により、**repo（main）に実体が無いものは Notion 側の誤記として扱い、
Notion を修正する**方針とした（本ファイル §11 に明文化）。あわせて、参照だけあって実体が
無かった本ファイルを新規作成し、リンク切れを解消した。

M-1（`votes_weight_ck` が SEC-VOTE-02 のシャドウバン方式 `weight=0` を拒否する）・
M-6（`post_trust_scores.band='held'` を非公開にする仕組みが無い）は、`db/migrations/0004_scoring.sql`
と `0011_trust_and_privacy.sql` を実際に読んで**内容自体は実在する不具合と確認済み**。
ただし修正（CHECK制約の変更・トリガ追加）は本ファイル §6 により Architecture Lead の
承認が必要なため、ここでは行わず `docs/03-remaining-tasks.md` に
`DESIGN_DECISION_REQUIRED` として記録するに留めた。
