# ADR-0001: ランキング期間の判定を撮影日時ベースにする

- **状態**: 承認（2026-08-13）。**実装は未了**（下記「実装状況」参照）
- **決定者**: 開発者
- **関連**: P-05 / `db/migrations/0009_ranking_fallback.sql` / `docs/04-security-design.md §6`

## 背景

`rebuild_ranking_entries` は週次ランキングの対象を **`posts.posted_at`（投稿日時）** で切っている。

```sql
-- db/migrations/0009_ranking_fallback.sql
AND p.posted_at >= v_start
AND p.posted_at <  v_end
```

一方で、スコアリングの他の部分はすべて **`captured_at`（撮影日時）** を基準にしている。

- 季節（`season`）・時間帯（`timeslot`）・天候（`weather`）のファセット導出は `captured_at` 基準
- `scoring/facets.py` の `timeslot_of()` は撮影地の日出・日没から相対で決める

つまり**ランキングの期間判定だけが別の時刻を見ている**という不整合があった。

さらに `docs/04-security-design.md` の `exif_time_match` シグナル（実装: `0011_trust_and_privacy.sql`
の `calc_trust_score`）は、EXIF 撮影時刻と投稿時刻の乖離が **7日を超えると trust_score を −0.15**
していた（`th_exif_time_days = 7.0`）。

P-01 で「全国 × ライト層（旅行・ドライブ）」を選んだ結果、この2点が実害になった。
**旅行から帰って写真を選んで投稿する**のはこのターゲットの標準的な行動であり、

- 7日ルールは主要ユーザーのほとんどの投稿を減点する
- `posted_at` 基準では「先週撮った夕景」が今週の部門に入り、季節・天候ファセットと矛盾する

## 決定

1. **ランキング期間の判定を `captured_at` に変更する**
2. **猶予期間 N = 30日**を設ける。撮影から30日以内の投稿のみランキング対象とする
3. **`exif_time_match` の 7日ルールを撤廃**し、猶予30日と整合させる。
   時刻の偽装検出は「EXIF 時刻が存在し、位置・天候と矛盾しないこと」で行う
4. 猶予を超えた投稿は**ランキング対象外。ただし投稿も②希少性も有効**
5. **EXIF が無い写真**は撮影日時が確定できないためランキング対象外とし、
   「初」ボーナスの対象外にする（既存の `record_facet_post(p_eligible => false)` に一致。
   判定の集約点は `is_first_bonus_eligible()` — `0012_invariant_guards.sql`）

## 影響

### スキーマ・関数

| 対象 | 変更 | 種別 |
|---|---|---|
| `rebuild_ranking_entries` | 期間判定を `captured_at` + 猶予30日 + `exif_captured_at IS NOT NULL` に | `CREATE OR REPLACE`（追記マイグレーション） |
| `scoring_rulesets.weights` | `ranking_grace_days: 30` を追加 | `publish_scoring_ruleset()` で新版発行 |
| `trust_rulesets` | `th_exif_time_days` を 7 → 30 に | `publish_trust_ruleset()`（新設）で新版発行 |

**マイグレーションは追記のみ**（CLAUDE.md 規約）のため、既存ファイルは書き換えず
`0015` 以降で `CREATE OR REPLACE FUNCTION` する。

### 新たに必要になる実装

**週締め後の確定スナップショット（T-35）**。撮影日ベースにすると、締めた週に対して
後から過去写真が入ってくるため、確定済みの順位が動く。`ranking_periods.closed_at` は
既に存在するので、締め済み期間のランキングは再生成せず凍結し、締め後の投稿は
翌週扱いにする。

### 副次的な効果

`captured_at` 基準にすることで、**季節・天候・時間帯のファセットと期間が同じ時刻を見る**ようになり、
「雪の◯◯峠」が冬の週に正しく入る。現行の `posted_at` 基準では、春に投稿された冬の写真が
春の週のランキングに `season='winter'` として入るという捻れがあった。

## 却下した案

- **投稿日ベース維持 ＋ 過去写真はランキング対象外**: 旅行後投稿が競争に一切参加できず、
  P-01 で選んだ主要ユーザー層が最も損をする。かつ後から救済できない
- **猶予なしの撮影日ベース**: 何年前の写真でもランキングに入れられてしまい、
  確定済みの順位が無期限に動く

## 未解決

- 猶予30日を超えた投稿の**表示上の扱い**（「記録」としてどう見せるか）は未設計
- EXIF なし写真の比率が高い場合の影響は実データ待ち（T-11 と併せて計測する）

## 実装状況（2026-08-14）

**決定・設計は確定しているが、コードへの反映は未了。** 影響が既存のスモークテスト・
`core/` の統合テスト（`posted_at` 基準を前提に組んである）に及ぶため、実装は別作業として
切り出す。着手時は次の順で進めること。

1. `rebuild_ranking_entries` を本 ADR の条件に変更する `0015` マイグレーション
2. `publish_trust_ruleset()` を新設し、`th_exif_time_days: 30` の新版を発行
3. 既存テストのフィクスチャに `exif_captured_at` を追加（無いと新条件で全件が対象外になる）
4. `db/tests/smoke_test.sql` と `core/tests/test_recalc.py` のうち `posted_at` を
   ランキング期間の判定に使っているテストを `captured_at` 基準に立て直す
