# ADR-001: POIソースの選定とライセンス条件

> T-05 / 設計レビュー B-11 への回答。
> 状態: **採択（2026-08-12）**
> 影響範囲: `docs/01 §1.2 手順5`、`docs/01 §4.3`、`spot_poi_cache`、`spot_source`、T-15、T-20、T-21

---

## 1. 何を決めなければいけなかったか

`docs/01` はスポット同定フローの手順5で外部POI検索を呼び、その応答を `spot_poi_cache` に
永続キャッシュして、**粒度変更時の全件再計算ではキャッシュだけを読む**設計になっていた。

> 「再計算では外部APIを呼ばない。`spot_poi_cache` から引くだけにする
> （数十万件分の外部API課金とレート制限を避けるため）」 —— docs/01 §4.3

この設計は「キャッシュが永続できること」を暗黙の前提にしていたが、**その前提を利用規約で
確認していなかった**というのが B-11 の指摘。プロバイダ次第でこの前提は崩れる。

## 2. 調べた結果（一次情報）

### Azure Maps

出典: [Microsoft Product Terms / Microsoft Customer Agreement](https://www.microsoft.com/licensing/terms/en-US/productoffering/MicrosoftAzure/MCA)

| 項目 | 規約の内容 |
|---|---|
| キャッシュの禁止 | 「Customer may not cache or store results delivered by the Azure Maps API **for the purpose of scaling such Results to serve multiple users**」 |
| キャッシュの許可 | 「Caching and storing Results and locations ... are permitted **where the purpose of caching is to reduce latency times**」 |
| 保持期間 | 「(i) the validity period indicated in returned headers; or (ii) **6 months, whichever is shorter**」 |
| ジオコードの例外 | Azureアカウントが有効な間はより長く保存できるという記述がある |
| 表示制限 | 「Customer may not display any Results ... on any **third-party content or geographical map database**」 |
| 帰属表示 | Microsoft が提供する帰属表示を目立つ形で表示する義務。Render では Get Map Attribution API から取得する |

**判定: 現行の `spot_poi_cache` の設計は規約に反する。**

- 目的が「再計算時のAPI課金とレート制限の回避」であり、これは *latency の低減* ではない
- 全ユーザーの投稿処理に使い回すので「scaling such Results to serve multiple users」に該当する
- 保持期間の上限（6か月）を設けていない

さらに **表示制限が波及する**。Azure Maps の Results を採用すると、クライアントの地図描画も
Azure Maps に固定される（MapLibre + OSMタイル等の上に POI 名を重ねられない）。
T-20（クライアントアプリ）の選択肢を先に狭めることになる。

### Google Places

出典: [Places API policies](https://developers.google.com/maps/documentation/places/web-service/policies)

| 項目 | 規約の内容 |
|---|---|
| 無期限保存が可能 | **place ID のみ**（「The place ID ... is exempt from the caching restrictions」） |
| その他のコンテンツ | 事前取得・キャッシュ・保存は原則不可（例外の範囲外） |
| 帰属表示 | Googleの地図上でなければ **Googleロゴの表示が必須** |

**判定: Azure Maps より制約が強い。** 名前を保持できないため `spots.display_name` に
POI名を継承する設計（docs/01 §1.4）が成立しない。Azureプロジェクトである点も含めて不採用。

### OpenStreetMap（ODbL）

出典: [openstreetmap.org/copyright](https://www.openstreetmap.org/copyright) /
[OSMF Attribution Guidelines](https://osmfoundation.org/wiki/Licence/Attribution_Guidelines)

| 項目 | 規約の内容 |
|---|---|
| ライセンス | Open Database License (ODbL) |
| 帰属表示 | 「Attribution must be to **"OpenStreetMap"**」。openstreetmap.org/copyright へのリンクを推奨 |
| データベースとして使う場合 | 「You must include attribution to OpenStreetMap and either the text of the ODbL or a link to it **as part of the database**」 |
| シェアアライク | 「If you alter or build upon our data, you may distribute the result only under the same license」 |
| 保持期間 | **制限なし** |
| 料金・レート制限 | 抽出データを自前で持てば **どちらも無い** |

---

## 3. 決定

**MVPのPOIソースは OpenStreetMap（ODbL）とし、地域抽出データを自前の PostGIS に取り込んで使う。
外部POI APIは呼ばない。**

```
従来:  投稿 → Azure Maps searchNearby → spot_poi_cache（永続）→ 再計算で再利用
                                          ↑ 規約違反

決定:  Geofabrik の日本抽出 → poi_reference（自前テーブル）→ 投稿も再計算も同じ表を読む
                                          ↑ 自分のデータなので保持期間の制約が無い
```

### 決め手

1. **`docs/01 §4.3` の再計算設計が唯一そのまま生き残る選択肢。** 粒度バージョニングは
   「いつでも全件再計算できる」ことに全体が乗っている。外部APIのキャッシュに6か月の上限が
   付くと、6か月より古い投稿の再計算で必ず API を叩き直すことになり、この前提が壊れる。
2. **個人開発でコストとレート制限がゼロになる。** 100万投稿の再計算（docs/01 §4.4）で
   外部API課金が発生しない。
3. **クライアントの地図描画を縛らない。** Azure Maps の「third-party map database に表示禁止」に
   引っかからないので、T-20 の選択肢を残せる。
4. **`tourism=viewpoint` に `direction=*` が付く。** 「その展望台がどちらを向いているか」が
   データとして取れる。docs/01 §2（方位セクター）と §2.3（`bearing_split_enabled`）の
   事前情報として使える。これは商用POI APIでは得られない。

### 引き受ける義務

| 義務 | 対応 |
|---|---|
| 帰属表示 | アプリ内に「© OpenStreetMap contributors」を常時表示し、openstreetmap.org/copyright へリンクする。スポット詳細ページでは `spot_source.attribution_text` を表示する（`v_spot_public` が返している） |
| シェアアライク | `poi_reference` は OSM の派生データベースにあたる。**OSM由来の列に限った抽出をODbLで公開できる状態にしておく。** ユーザー投稿・スコア・ランキングはODbLの対象外（別データベース） |
| 出典の明示 | 取り込んだ抽出のURLと日付を `poi_extract_versions` に記録する |

**シェアアライクの範囲を誤解しないこと。** ODbL が及ぶのは OSM から取り込んだ
`poi_reference` とその派生であって、ユーザーの投稿・写真・スコアには及ばない。
`spots` は OSM 由来の名前を継承するので、**`spots` のうち OSM 由来の列**（`display_name`,
`poi_external_id`, `centroid` の一部）が公開対象になりうる。ここを分離しておくため、
`spots.source_code` で出自を判別できるようにしてある。

---

## 4. 実装への影響

### 4.1 docs/01 §1.2 手順5 の置き換え

```
旧: poi := AzureMaps.searchNearby(lat, lon, radius, categories = SCENIC_CATEGORIES)
新: poi := find_scenic_poi(lat, lon, radius)     -- poi_reference をPostGISで近傍検索
```

外部呼び出しが消えるので、**採点ワーカーのレイテンシ（docs/02 §1.3 の3秒SLO）にも効く。**
ネットワーク往復が1本減り、同一DB内のGiSTインデックス検索になる。

### 4.2 docs/01 §4.3 の前提が確定した

「再計算では外部APIを呼ばない」は、規約上の懸念なしに成立する。
ただし条件が1つ付く: **再計算は、その投稿を最初に処理したときと同じ抽出バージョンを使うこと。**
`poi_extract_versions` を切ってあるのはこのため。抽出を更新すると POI が増減し、
同じ入力から違うスポットが出る。これは粒度バージョンと同じ再現性の問題。

### 4.3 `spot_poi_cache` の扱い

**MVPでは使わない。** ただしテーブルは残し、将来 Azure Maps 等の外部APIを併用する場合に
備えて**規約の保持上限をスキーマの制約として書き込んだ**。

```sql
CHECK (expires_at <= fetched_at + interval '180 days')
```

6か月（≒180日）を超える行は物理的に作れない。`purge_expired_poi_cache()` を日次で回す。
「規約を守るのを運用の注意力に任せない」ための措置。

### 4.4 SCENIC_CATEGORIES の OSM タグ対応

docs/01 §1.2 のカテゴリ一覧を OSM のタグに写したもの。**核となるのは `tourism=viewpoint`**
（「A place worth visiting, often high, with a good view of surrounding countryside or
notable buildings」）。

| カテゴリ | OSMタグ（候補） |
|---|---|
| 展望台・ビューポイント | `tourism=viewpoint` |
| 山・峠・岬 | `natural=peak`, `mountain_pass=yes`, `natural=cape` |
| 湖沼・滝・海岸 | `natural=water`, `waterway=waterfall`, `natural=beach` |
| 公園・庭園 | `leisure=park`, `leisure=garden` |
| 神社仏閣・城郭 | `amenity=place_of_worship`, `historic=castle` |
| 灯台・展望タワー | `man_made=lighthouse`, `man_made=tower` + `tower:type=observation` |
| 橋梁 | `man_made=bridge` |
| キャンプ場 | `tourism=camp_site` |

**この対応表は実データで検証すること。** 日本の 道の駅 のタグ付けは揺れがあり、
確定できていない。`poi_reference.category` に正規化して入れる際の分類規則は T-15 で確定する。
検証しないまま採用すると、docs/01 §1.2 が警告している「峠の絶景ポイントがコンビニの名前を
継承する」と同種の事故が起きる。

---

## 5. 却下した案

| 案 | 却下理由 |
|---|---|
| Azure Maps を規約準拠の6か月キャッシュで使う | 6か月より古い投稿の再計算で必ず API を叩き直すことになり、docs/01 §4.3 の前提が壊れる。100万投稿規模で課金とレート制限が読めない |
| Google Places | POI名を保持できない。`spots.display_name` への継承（docs/01 §1.4）が成立しない |
| POIを使わない（H3セル + DBSCAN昇格のみ） | ライセンスリスクはゼロだが、「◯◯展望台」と名前が出せない。docs/01 §1.4 がこれを「強い」と評価しており、初期の体験を大きく落とす。**ただし OSM の日本カバレッジが想定より薄かった場合の退避先として残す** |

---

## 6. 未決定のまま残す点

- **抽出の更新頻度。** 頻繁に更新すると再現性（§4.2）が壊れ、更新しないと新しい展望台が出ない。
  四半期ごとを仮置きするが、**新バージョンへの切り替えは粒度バージョンの切り替えと同時に行う**
  のが筋（どちらも全件再計算を伴うため）。T-21 で確定する。
- **逆ジオコーディングの出所。** 昇格スポットの暫定名（docs/01 §1.4）に使う。
  OSM 抽出から行政区画名を引ければ外部APIは不要になるが、未検証。
- **OSM の日本の `tourism=viewpoint` カバレッジ。** T-10（H3解像度の決定）で実データを
  集めるときに同時に測る。薄ければ §5 の「POIを使わない」案に退避する。
- **天候API（T-12）への波及。** Azure Maps Weather にも同じキャッシュ条項が掛かる。
  `posts.weather` は応答そのものではなく `weather_kind` に分類した派生値なので
  「Results のキャッシュ」には当たらないと解釈しているが、**天候の生応答を溜めるテーブルは
  作らないこと。** T-12 で気象庁アメダスと比較する際の判断材料に加える。
