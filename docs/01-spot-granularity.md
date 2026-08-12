# スポット粒度設計

> 引継ぎ書 §4 / §8「最優先タスク1」に対する設計。
> 対象範囲：スポット同定アルゴリズム、方位セクター、粒度バージョニング、再計算ジョブ、テーブル設計。
> 対応するDDLは [`db/migrations/`](../db/migrations/) にある。

---

## 0. この設計が守る不変条件

先に結論から。以下3点を破らない限り、粒度定義は後からいくらでも変えられる。

| # | 不変条件 | 破ると起きること |
|---|---|---|
| **I-1** | **投稿テーブルは「観測事実」だけを持つ。スポットIDを持たない** | 粒度変更のたびに投稿テーブルをUPDATEすることになり、履歴が消えて再現性が失われる |
| **I-2** | **投稿とスポットの紐付けは `(post_id, grain_version_id)` の交差テーブルに置く** | 旧粒度と新粒度を同時に保持できず、再計算がダウンタイム付きの一発勝負になる |
| **I-3** | **希少性スコア・ランキングも `grain_version_id` を持つ** | 引継ぎ書 §4「粒度定義を変更すると過去の希少性スコアが全て変わる」がそのまま事故になる |

つまり **粒度変更 = 新しい `grain_version` で全件を別レコードとして再計算し、最後にアクティブポインタを差し替える（Blue-Green）**。既存行は一切書き換えない。

```
posts (不変の観測事実)
  └─ post_spot_assignment (post_id, grain_version_id) → spots
       └─ post_rarity_scores (post_id, grain_version_id)
            └─ ranking_entries (grain_version_id)
                      ▲
        spot_grain_versions.status = 'active' が指す1本だけを配信に使う
```

---

## 1. スポット同定アルゴリズム

引継ぎ書のハイブリッド案（H3 + POI + DBSCAN昇格）を、**実行順序と競合解決まで確定**させたもの。

### 1.1 前提となるパラメータ（`spot_grain_versions` に格納）

| パラメータ | 既定値 | 根拠 |
|---|---|---|
| `h3_resolution` | **9** | 平均六角形面積 0.105 km² / 平均辺長 ≒174m。展望台1つ〜駐車場+遊歩道程度が1セルに収まる |
| `snap_radius_m` | **120** | 既存スポットへの吸着半径。res9の辺長より短くし、隣接セルの正規スポットに吸い寄せられるようにする |
| `poi_match_radius_m` | **150** | Azure Maps POI検索半径 |
| `bearing_sector_count` | **8** | 45度刻み |
| `dbscan_eps_m` | **80** | 昇格クラスタの密度基準 |
| `dbscan_min_points` | **5** | 同上。「同じ場所で5回以上撮られた」を独自スポットの閾値とする |
| `dbscan_min_users` | **3** | 1人の連投でスポットが生えるのを防ぐ |
| `gps_accuracy_reject_m` | **100** | これより粗い測位は「初」判定から除外（§3.3） |

### 1.2 解決フロー（投稿1件あたり）

```
入力: (lat, lon, gps_accuracy_m, bearing_deg?, captured_at, user_id)
      grain_version = 対象の粒度バージョン

1. cell    := h3.latLngToCell(lat, lon, grain.h3_resolution)
2. ring    := h3.gridDisk(cell, 1)                    // 自セル + 隣接6セル
3. cands   := spots WHERE grain_version_id = grain.id
                      AND h3_index = ANY(ring)
                      AND kind IN ('poi', 'cluster')  // 命名済みの「正規」スポットのみ

4. IF cands 内に centroid までの距離 <= grain.snap_radius_m のものがある
       → 最近傍に bind。 kind は据え置き。            [SNAP]
       → 終了

5. poi := AzureMaps.searchNearby(lat, lon, radius = grain.poi_match_radius_m,
                                 categories = SCENIC_CATEGORIES)
   IF poi が見つかる
       → spots に upsert (kind='poi', external_id=poi.id, display_name=poi.name)
       → bind                                          [POI]
       → 終了

6. → cell そのものを暫定スポットとして upsert (kind='h3_cell', display_name=NULL)
   → bind                                              [CELL]
```

**手順4が引継ぎ書§4の「セル境界で同一展望台が分割される」への回答**。セル所属で決めるのではなく、**セルは候補を引くためのインデックスとしてだけ使い、最終判定は正規スポット重心からの実距離で行う**。res9セルの境界に立っている展望台でも、先に登録された1つのスポットに全投稿が吸着する。

**手順5のカテゴリフィルタは必須**。無条件POIマッチをすると、峠の絶景ポイントがすぐ隣のコンビニや自販機のPOI名を継承する。採用カテゴリは概ね以下（Azure Maps のカテゴリセット）:

```
SCENIC_CATEGORIES =
  展望台/ビューポイント, 公園・庭園, 山・峠・岬, 湖沼・滝・海岸,
  神社仏閣・城郭, 橋梁, 灯台, 展望タワー, キャンプ場, 道の駅(展望併設)
```

一致しなければ手順6に落とす。**「無名の絶景を拾えない」問題は、POIで拾わずCELL→昇格ルートで拾う**（§1.3）。

### 1.3 CELL → 独自スポット昇格（DBSCAN）

`kind='h3_cell'` の暫定スポットは、投稿が溜まった時点で夜間バッチが精査する。

```
対象: kind='h3_cell' AND post_count >= dbscan_min_points AND promoted_at IS NULL

1. そのセル + 隣接セルに属する投稿の座標を集める
   （gps_accuracy_m <= gps_accuracy_reject_m のものだけ）
2. DBSCAN(eps = 80m, minPts = 5) を Haversine 距離で実行
3. 得られたクラスタのうち distinct(user_id) >= dbscan_min_users のものを
   kind='cluster' の新スポットに昇格。centroid = クラスタ重心
4. そのクラスタに含まれる投稿の post_spot_assignment を新スポットへ張り替える
   （同一 grain_version 内の張り替えなので、希少性の再計算対象になる → §4.3）
5. ノイズ点は h3_cell スポットに残す
6. 昇格したスポットの最多投稿者に「命名権」通知を出す
   → 命名されるまで display_name は逆ジオコーディングの暫定名
```

昇格スポットは手順4の[SNAP]候補になるため、**以後その場所の投稿はセル境界に関係なく同じスポットに集まる**。

### 1.4 命名の扱い

| kind | display_name | 表示 |
|---|---|---|
| `poi` | POI名をそのまま継承 | 「◯◯展望台」 |
| `cluster` | ユーザー命名（未命名時は逆ジオコーディングの暫定名） | 「△△の桜並木」/「◯◯町 付近」 |
| `h3_cell` | NULL | 「この付近」（ランキング対象には入るが名前を出さない） |

命名は `spot_name_proposals` に提案を溜め、同一スポットで3票集まったものを採用する（荒らし対策）。MVPでは最多投稿者の命名を即採用でよい。

---

## 2. 方位セクター

引継ぎ書§4「同じ展望台でも北を向くか南を向くかで全く別の景色」への実装。

### 2.1 定義

EXIF `GPSImgDirection`（+ `GPSImgDirectionRef`）から真北基準の方位角を取り、8セクターに割る。**セクター境界ではなく中心が主要8方位に来るようにオフセットする**。

```
sector = floor((((bearing_deg + 22.5) mod 360) / 45))   // 0..7
0=N(337.5–22.5), 1=NE, 2=E, 3=SE, 4=S, 5=SW, 6=W, 7=NW
```

磁北基準しか取れない端末向けに、`GPSImgDirectionRef='M'` の場合は撮影地の偏角（日本は概ね西偏6〜9度）で補正する。MVPでは補正なし・`bearing_source='magnetic'` を記録しておき、後から一括補正できるようにする。

### 2.2 取得できない場合（重要）

Androidの一部機種・スクリーンショット・編集アプリ経由では `GPSImgDirection` が落ちる。**方位不明は独立したバケット `sector = NULL` として扱い、8セクターのどれにも混ぜない。**

そして **方位不明の投稿には「初」ボーナスを与えない**（§3.3）。方位を消せば全方位で「初」を取れる、という自明な抜け道を塞ぐため。

### 2.3 スポットごとの有効/無効

方位分割が意味を持つのは「一点から複数方向を見渡す」スポットだけ。海岸線や1本道の展望台では方位が実質固定になり、分割しても椅子が増えない代わりに希少性が水増しされる。

`spots.bearing_split_enabled`（既定 true）を持たせ、**投稿が20件を超えた時点で方位の分散を評価し、円周分散が閾値未満なら false に落とす**バッチを回す。false のスポットでは全投稿を `sector = NULL` 相当の単一バケットに寄せる。

---

## 3. ファセット（「1位の椅子」の単位）

引継ぎ書§1「スポット別 × 天候別 × 時間帯別 × 季節別に枠を切る」の実体。

### 3.1 ファセットキー

```
facet = (grain_version_id, spot_id, bearing_sector, weather, timeslot, season)
```

| 次元 | 値 | 決め方 |
|---|---|---|
| `bearing_sector` | 0–7 / NULL | §2 |
| `weather` | clear, cloudy, rain, snow, fog | 撮影地・撮影時刻の気象APIを逆引き（後述） |
| `timeslot` | dawn, morning, noon, golden, dusk, night | 撮影地の日出・日没時刻からの相対で決める（固定時刻ではない） |
| `season` | spring, summer, autumn, winter | 月ベース（3–5/6–8/9–11/12–2） |

**`timeslot` を固定時刻で切ってはいけない。** 「朝焼け部門」は夏と冬で2時間ずれる。日出時刻 `sunrise` を基準に:

```
dawn   : [sunrise - 60min, sunrise)
morning: [sunrise, sunrise + 120min)
golden : [sunset - 60min, sunset)      ※ dawn/golden が優先
dusk   : [sunset, sunset + 45min)
night  : [sunset + 45min, sunrise - 60min)
noon   : それ以外
```

`weather` は撮影時刻が過去なので予報ではなく実況/履歴を引く。Azure Maps Weather の `Get Daily Historical Actuals` 等で撮影地・撮影日の実績を取り、取得できなければ `weather = NULL`（= 天候不明バケット、「初」ボーナス対象外）。

### 3.2 椅子の総数感覚

1スポットあたり最大 8方位 × 5天候 × 6時間帯 × 4季節 = **960ファセット**。これは多すぎる。**ランキングとして配信するのは「投稿が5件以上あるファセット」に限定する**（`ranking_entries` 生成時にフィルタ）。1件しかないファセットで1位を出すと引継ぎ書§4の「点数インフレ→無価値化」そのものになる。

一方 **希少性の「初」判定はフルの960空間で行ってよい**。こちらは順位ではなく一過性のボーナスなので、インフレしない（§3.3の逓減で吸収される）。

### 3.3 「初」ボーナスの発行条件

以下を **すべて** 満たすときのみ `first_combination` ボーナスを出す。

- `gps_accuracy_m <= 100`
- `bearing_sector IS NOT NULL`（方位不明では出さない）
- `weather IS NOT NULL`（天候不明では出さない）
- EXIF撮影時刻と投稿位置の整合チェック（引継ぎ書§5）を通過している
- 同一ユーザーが同一スポットで直近24時間以内に「初」を取っていない

最後の条件は、1人が同じ峠で方位を変えて8連投すると8回「初」が出る、という一番踏まれやすい抜け道を塞ぐもの。

---

## 4. 粒度バージョニングと再計算

### 4.1 バージョンのライフサイクル

```
draft ──► shadow ──► active ──► deprecated ──► (archived)
  │         │           │
  │         │           └─ 配信で使う唯一のバージョン
  │         └─ 全件再計算が走っている / 完了して検証中。書き込みは新旧両方に行う
  └─ パラメータだけ入っていて計算は未着手
```

`spot_grain_versions.status` に `active` は**部分ユニークインデックスで1行だけ**に制約する（DDL参照）。

### 4.2 移行手順（Blue-Green）

1. 新パラメータで `spot_grain_versions` に `draft` 行を作る
2. `shadow` に上げる。**この瞬間から、新規投稿の取り込みは active と shadow の両方に assignment を書く**（デュアルライト）
3. 再計算ジョブが過去分を古い順に埋める（§4.3）
4. 差分レポートを見て検証：
   - スポット総数、`kind` 別内訳
   - 1スポットあたり投稿数の分布（p50 / p90 / max）
   - **「初」ボーナス発行数の総和**（これが跳ね上がる粒度は細かすぎる）
   - 投稿数5件以上ファセット数（＝実際に配信される椅子の数）
5. 問題なければトランザクション内で `active` → `deprecated`、`shadow` → `active`
6. 旧バージョンの行は残す。ロールバックはポインタを戻すだけ

**ユーザーに見えているスコアが移行の瞬間に変わる**点は避けられない。表示ポリシー（引継ぎ書§3）が相対指標のみなので絶対値のブレは見えにくいが、順位は動く。移行は週次リセットの直後に実施するのが被害が最も小さい。

### 4.3 再計算ジョブ

```
recalc(grain_version_id, from_post_id, batch_size = 5000)
  1. posts を id 昇順で batch_size 件取得（カーソルは job_state に永続化）
  2. 各投稿に §1.2 の解決フローを適用 → post_spot_assignment を INSERT
     ※ POI検索は呼ばない。再計算では spot_poi_cache から引くだけにする
       （数十万件分の外部API課金と レート制限を避けるため）
  3. spot_facet_stats を集計し直す（post_count, first_post_id, last_post_at）
  4. §1.3 の DBSCAN 昇格を全セルに対して実行
  5. post_rarity_scores を再計算（②は決定的なので、同じ入力なら同じ出力）
  6. ranking_entries を再生成
```

**冪等性が要件**。ジョブは途中で落ちる前提で、`ON CONFLICT (post_id, grain_version_id) DO UPDATE` と カーソル永続化で再開可能にする。

**①AIスコアは再計算対象外**（粒度に依存しないため）。③コミュニティ加点も投票結果そのものは不変だが、**ファセットが変わると相対順位が変わる**ため、Eloレーティングからのマッピングだけは再計算する。

### 4.4 コスト見積もり（100万投稿時点）

| 工程 | 見積 | 備考 |
|---|---|---|
| 解決フロー（H3 + 近傍検索） | 約1〜2時間 | 5000件バッチ × 200バッチ、1件あたり2〜3ms |
| DBSCAN 昇格 | 約20分 | セル単位に分割すれば並列可 |
| 希少性再計算 | 約10分 | 純SQL |
| ランキング再生成 | 約5分 | |

Container Apps Job（4 vCPU）1本で回る規模。粒度変更は年に数回のイベントなので、専用の常設インフラは持たない。

---

## 5. テーブル設計

DDL全文は [`db/migrations/`](../db/migrations/)。ここでは意図だけ記す。

| テーブル | 役割 | 粒度依存 |
|---|---|---|
| `posts` | 観測事実（座標・方位・撮影時刻・Blobパス・pHash） | **なし（I-1）** |
| `spot_grain_versions` | 粒度定義とパラメータ、`status` | — |
| `spots` | スポット実体（kind, centroid, h3_index, display_name） | **あり** |
| `post_spot_assignment` | 投稿↔スポット + ファセットキー | **あり（I-2）** |
| `spot_facet_stats` | ファセット別の累計・初回投稿 | **あり** |
| `post_ai_scores` | ①（model_bundle_version 別） | なし |
| `post_rarity_scores` | ②（breakdown を jsonb で保持し説明可能に） | **あり（I-3）** |
| `post_community_scores` | ③（Elo + 確定時刻） | なし |
| `votes` | 2枚比較投票の生ログ | なし |
| `ranking_periods` / `ranking_entries` | 週次リセットの器 | **あり** |
| `post_integrity_checks` | 不正対策の判定結果（引継ぎ書§5） | なし |
| `spot_poi_cache` | Azure Maps POI応答のキャッシュ | なし（再計算で再利用） |

### なぜ H3インデックスをアプリ側で計算するか

Azure Database for PostgreSQL フレキシブルサーバーの対応拡張機能一覧に **`h3-pg` は含まれていない**（PostGIS 3.6.1、pg_cron、pg_partman 等は利用可）。したがって:

- H3インデックスは **アプリ層（`h3-py` / `h3-js`）で計算し、`bigint` として保存**する
- 近傍検索は `h3_index = ANY(...)` の btree索引 + PostGIS の `ST_DWithin`（GiST索引）の併用
- 将来 `h3-pg` が来ても、カラムの型と値はそのままなので移行コストはゼロ

出典: [対応拡張機能一覧](https://learn.microsoft.com/azure/postgresql/extensions/concepts-extensions-by-engine)

---

## 6. 失敗モードと検知

引継ぎ書§4の失敗モードを、**運用中に自動検知できる指標**に落としたもの。

| 失敗モード | 監視指標 | アラート閾値（初期値） |
|---|---|---|
| 細かすぎる | 1スポットあたり投稿数の中央値 | **< 3** |
| 細かすぎる | 全投稿に占める「初」ボーナス発行率 | **> 25%** |
| 細かすぎる | 投稿数1件のスポットの比率 | **> 60%** |
| 粗すぎる | 1スポットあたり投稿数の p99 | **> 5000** |
| 粗すぎる | 1スポット内スコア分散 | 上位10スポットで平均の2倍超 |
| POI誤継承 | `kind='poi'` かつ SCENIC_CATEGORIES 外の名前比率 | **> 5%** |

これらは週次でダッシュボードに出す。**閾値を割ったら粒度変更を検討する** —— そのときに §4 のバージョニングが効く。

---

## 7. 未決定のまま残した点

| 論点 | 現状 | 判断に必要なもの |
|---|---|---|
| `h3_resolution` を 9 と 10 のどちらにするか | **9 で開始** | 実データ200〜500件。§6の指標で判断できる |
| 方位セクター 8 分割 vs 4 分割 | **8 で開始**、`bearing_split_enabled` で個別無効化 | 実際に方位が取れる端末の比率。5割を切るなら4分割に落とす |
| 天候の取得元 | Azure Maps Weather（履歴実況） | 課金と日本の粒度。代替は気象庁アメダスの直近データ |
| 命名の承認フロー | 3票で採用 | 荒らし発生率次第。MVPは最多投稿者の即採用 |
