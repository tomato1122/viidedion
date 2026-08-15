# ADR-0005: スポットの永続IDと系譜を粒度バージョンから分離する

- **状態**: **参考資料（実装は別アプローチで完了済み）**。以下は 2026-08-13 の設計提案の全文
- **決定者**: 開発者
- **関連**: T-01 / レビュー指摘 B-01 / P-03 / P-06 / `docs/06-adr-poi-source.md` / `db/migrations/0003_spots.sql`

> **2026-08-14 追記**: T-01 は本 ADR とは別のアプローチ（`db/migrations/0008_spot_identity.sql`
> + `core/spots.py`）で既に実装・テスト済み（52件）。**この文書は設計提案として全文を残すが、
> 実装として採用されたのは以下ではない。** 差分は次のとおり。
>
> | 論点 | 本ADRの提案 | 実装（0008 / core/spots.py） |
> |---|---|---|
> | テーブル名 | `spot_identities`（複数形）/ `spot_sources`（履歴テーブル） | `spot_identity`（単数）/ `spot_source`（提供元マスタ + ライセンス情報） |
> | 系譜（carry_over）の判定 | 投稿集合の **Jaccard 係数**（重なり率）で類似度判定。閾値は未確定 | **`post_spot_assignment` の紐付けを一次情報**にする（投稿ごとに厳密に決まる。距離はフォールバックのみ）。詳細は `docs/01 §8.3` |
> | 出自の履歴 | `spot_sources` に来歴を複数行で保持（提供元の付け替えを追跡） | `spots.source_code` に現在値のみ。履歴は持たない（現状の要件を超えると判断） |
> | slug 生成 | **ローマ字化**（OSM `name:ja_rm` → `name:en` → 読み仮名のヘボン式変換 → フォールバック） | 日本語名は ASCII 化できないため**座標ベースの slug にフォールバック**（`generate_spot_slug()`）。ローマ字化は未実装 |
> | 統合時のフォロー付け替え | `spot_follows` を `ON CONFLICT DO NOTHING` で単純併合。通知しない | `spot_follows` 自体が未実装（P-03 は本 ADR 承認と同時に決定されたため） |
>
> **ローマ字化 slug は実装済みのものより優れた提案であり、T-01 の残作業として `docs/03` に
> 記録した。** Jaccard 係数によるアプローチは、実装済みの「投稿紐付けを一次情報にする」方式の方が
> 厳密（近似的な集合の重なりではなく、投稿ごとに厳密な帰属が決まる）と判断し不採用。

## 背景

現在の `spots` は `grain_version_id` を持ち、**粒度バージョンごとに別レコードとして作り直される**。
これは不変条件 I-2 / I-3（粒度変更で既存行を UPDATE しない）を守るための設計だが、副作用として
**粒度を変えるとスポットの ID が変わる**。

```sql
-- db/migrations/0003_spots.sql
CREATE TABLE spots (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    grain_version_id smallint NOT NULL REFERENCES spot_grain_versions (id),
    ...
);
```

壊れるもの:

| 対象 | 影響 |
|---|---|
| スポットのURL | 粒度変更のたびにリンクが切れる |
| 過去の称号 | 「先週◯◯展望台で1位」が指すスポットが消える |
| 訪問履歴 | 「行ったことがある場所」が追えなくなる |
| **スポットのフォロー**（P-03） | **フォローが粒度変更で全部切れる** |
| 命名 | ユーザーが付けた名前が新バージョンに引き継がれない |

**P-03（スポットのみフォロー）を決めたことで、この問題は深刻化した。** フォローは本アプリで
人と場所を結ぶ唯一の永続的な関係であり、通知（T-27）と票の重み付け（P-04）の原資でもある。
粒度変更のたびに切れる設計では成立しない。

また P-06（POI由来の未踏スポットを地図に先置き）により、**投稿がゼロのスポット**が大量に
生まれる。これらも粒度をまたいで同一性を保つ必要がある。

## 決定

**「場所の同一性」と「粒度バージョンごとの実体」を別テーブルに分離する。**

```
spot_identities          粒度に依存しない永続ID。URL・称号・フォローはこれを指す
      ↑ 1 : N
spots                    粒度バージョンごとの実体（現行テーブルに identity_id を追加）
      ↑
post_spot_assignment     計算上の紐付け（変更なし）
ranking_entries          順位（変更なし）
```

### 参照先の原則

**この一文が設計の要点である。**

> **ユーザーの意図・履歴・URL は `spot_identities` を指す。
> 計算・集計・順位は `spots`（バージョン付き）を指す。**

| テーブル / 用途 | 参照先 | 理由 |
|---|---|---|
| `post_spot_assignment.spot_id` | `spots` | 計算の紐付け。どの粒度で紐付いたかが事実 |
| `ranking_entries.spot_id` | `spots` | 順位はその粒度における事実。再現性のため保持 |
| `spot_facet_stats.spot_id` | `spots` | 集計はバージョン固有 |
| `votes.spot_id` | `spots` | 監査用 |
| **`spot_follows`**（P-03・新規） | **`spot_identities`** | フォローは永続的な意図 |
| **`spot_name_proposals`** | **`spot_identities`** | 命名は場所の属性であって粒度の属性ではない |
| **URL / 称号 / 訪問履歴** | **`spot_identities`** | ユーザーに見える同一性 |

`ranking_entries` は `spots` を指したまま、表示時に `spots.identity_id` 経由で現在の
スポットへ解決する。**過去の順位がどの粒度で算出されたかを失わずに、称号は生き続ける。**

---

## スキーマ案

### spot_identities — 永続ID

```sql
CREATE TYPE spot_identity_status AS ENUM (
    'active',    -- 現行
    'merged',    -- 他のIDに統合された。merged_into_id へ辿る
    'retired'    -- 後継が無くなった（過去の順位は残るが新規投稿は付かない）
);

CREATE TABLE spot_identities (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    -- URL に出る安定キー。ID をURLに晒さないためと、人間可読にするため
    slug           text NOT NULL,
    status         spot_identity_status NOT NULL DEFAULT 'active',
    -- status='merged' のときの遷移先。URL のリダイレクトに使う
    merged_into_id uuid REFERENCES spot_identities (id),

    -- 現在の表示名（非正規化。履歴と別名は spot_aliases が持つ）
    display_name   text,
    name_source    spot_name_source,

    created_at     timestamptz NOT NULL DEFAULT now(),
    retired_at     timestamptz,

    CONSTRAINT spot_identity_slug_key  UNIQUE (slug),
    CONSTRAINT spot_identity_merged_ck CHECK ((status = 'merged') = (merged_into_id IS NOT NULL)),
    CONSTRAINT spot_identity_self_ck   CHECK (merged_into_id IS DISTINCT FROM id)
);
```

**表示名を identity 側に置くのが要点。** 名前は「場所」の属性であって「粒度」の属性ではない。
現行の `spots.display_name` は粒度バージョンごとに複製されており、ユーザーが付けた名前が
新バージョンに引き継がれない原因になっていた。

### spots — versioned な実体（既存テーブルへの追加）

```sql
ALTER TABLE spots ADD COLUMN identity_id uuid REFERENCES spot_identities (id);
-- 既存行に発番したのち NOT NULL 化する（移行手順は後述）

-- 1つの identity は1つの粒度バージョンに1レコードまで。
-- 2つに割れる場合は「分割」であり、片方は新しい identity を持つ（後述）
CREATE UNIQUE INDEX spots_identity_version_uix ON spots (identity_id, grain_version_id);
```

`spots.display_name` / `name_source` は **identity 側へ移すため廃止予定**とする
（互換のためしばらく残し、参照を切り替えてから落とす）。

### spot_aliases — 別名・旧名・旧URL

```sql
CREATE TYPE spot_alias_kind AS ENUM (
    'legacy_slug',   -- 過去のURL。リダイレクトに使う
    'alternate',     -- 別名（「◯◯峠」と「◯◯展望台」など）
    'reading'        -- よみがな。日本語検索に使う
);

CREATE TABLE spot_aliases (
    id          bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    identity_id uuid            NOT NULL REFERENCES spot_identities (id) ON DELETE CASCADE,
    kind        spot_alias_kind NOT NULL,
    value       text            NOT NULL,
    source      spot_name_source,
    -- 名称変更は「旧名を valid_to で閉じ、新名を開く」で表現する
    valid_from  timestamptz     NOT NULL DEFAULT now(),
    valid_to    timestamptz,
    created_at  timestamptz     NOT NULL DEFAULT now(),

    CONSTRAINT spot_alias_range_ck CHECK (valid_to IS NULL OR valid_to > valid_from)
);

-- 同一 identity 内で、現行の同種同値エイリアスは1つだけ
CREATE UNIQUE INDEX spot_alias_current_uix
    ON spot_aliases (identity_id, kind, value) WHERE valid_to IS NULL;
-- 旧URLからの解決
CREATE INDEX spot_alias_slug_idx
    ON spot_aliases (value) WHERE kind = 'legacy_slug';
```

### spot_sources — 由来と提供元の変更

```sql
CREATE TYPE spot_source_kind AS ENUM (
    'osm',       -- OpenStreetMap 由来（ADR-0002）
    'cluster',   -- DBSCAN 昇格（docs/01 §1.3）
    'user',      -- ユーザーが作成・命名
    'operator'   -- 運営が手動登録
);

CREATE TABLE spot_sources (
    id           bigint           PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    identity_id  uuid             NOT NULL REFERENCES spot_identities (id) ON DELETE CASCADE,
    source_kind  spot_source_kind NOT NULL,
    -- OSM なら 'node/123456789'。cluster/user なら NULL
    external_ref text,
    is_current   boolean          NOT NULL DEFAULT true,
    linked_at    timestamptz      NOT NULL DEFAULT now(),
    unlinked_at  timestamptz,
    note         text,

    CONSTRAINT spot_source_current_ck CHECK (is_current = (unlinked_at IS NULL))
);

-- 現行の由来は identity ごとに1つ
CREATE UNIQUE INDEX spot_source_one_current_uix
    ON spot_sources (identity_id) WHERE is_current;
-- 同じ外部参照を2つの identity が同時に持たない
CREATE UNIQUE INDEX spot_source_external_uix
    ON spot_sources (source_kind, external_ref)
    WHERE is_current AND external_ref IS NOT NULL;
```

### spot_lineage — 分割・統合の履歴

```sql
CREATE TYPE spot_lineage_relation AS ENUM (
    'split',    -- 1つの旧スポットが複数に割れた
    'merge',    -- 複数の旧スポットが1つになった
    'new',      -- 対応する旧スポットが無い（parent が NULL）
    'retire'    -- 後継が無い（child が NULL）
);

CREATE TABLE spot_lineage (
    id                 bigint                PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    -- どの粒度バージョンへの移行で起きたか
    grain_version_id   smallint              NOT NULL REFERENCES spot_grain_versions (id) ON DELETE CASCADE,
    relation           spot_lineage_relation NOT NULL,
    parent_identity_id uuid REFERENCES spot_identities (id),
    child_identity_id  uuid REFERENCES spot_identities (id),
    -- 親の投稿のうち何割がこの子へ移ったか。分割時の「どちらが本家か」の根拠。
    -- real ではなく numeric にするのは、この値が「継続する identity」を決める判断に
    -- 使われるため。浮動小数点だと同値判定がブレて再計算の決定性が崩れる
    post_share         numeric(4,3),
    centroid_shift_m   real,
    created_at         timestamptz           NOT NULL DEFAULT now(),

    CONSTRAINT spot_lineage_new_ck    CHECK (relation <> 'new'    OR parent_identity_id IS NULL),
    CONSTRAINT spot_lineage_retire_ck CHECK (relation <> 'retire' OR child_identity_id  IS NULL),
    CONSTRAINT spot_lineage_share_ck  CHECK (post_share IS NULL OR (post_share >= 0 AND post_share <= 1))
);

CREATE INDEX spot_lineage_parent_idx ON spot_lineage (parent_identity_id, grain_version_id);
CREATE INDEX spot_lineage_child_idx  ON spot_lineage (child_identity_id,  grain_version_id);
```

---

## 4つの変化をどう表現するか

### 1. 分割（split）— 粒度を細かくすると1つの展望台が2つに割れる

**規則: 投稿の過半を引き継いだ方が identity を継続する。残りは新しい identity を得る。**

```
旧: A（identity=X, 投稿100件）
新: A1（投稿70件） / A2（投稿30件）

→ A1.identity_id = X          （継続。URLも称号もそのまま）
   A2.identity_id = Y（新規）  （新しいスポットとして生まれる）

spot_lineage:
  (relation='split', parent=X, child=X, post_share=0.70)
  (relation='split', parent=X, child=Y, post_share=0.30)
```

過半を持つ子が無い場合（例: 45% / 30% / 25%）は**最大シェアの子**が継続する。
同率のときは centroid が旧スポットに近い方を選ぶ。決定的にすること（再計算の冪等性のため）。

### 2. 統合（merge）— 粒度を粗くすると2つの展望台が1つになる

**規則: 投稿数が最大の identity が生き残り、他は `merged` にして遷移先を記録する。**

```
旧: A（identity=X, 80件） / B（identity=Y, 20件）
新: C（1つのスポット）

→ C.identity_id = X
   spot_identities: Y.status='merged', Y.merged_into_id=X

spot_lineage:
  (relation='merge', parent=X, child=X, post_share=0.80)
  (relation='merge', parent=Y, child=X, post_share=0.20)
```

**Y の URL は X へリダイレクトする**（`merged_into_id` を辿る）。
Y をフォローしていたユーザーは X のフォローへ移す。Y の称号は「X の過去の称号」として表示できる。

### 3. 名称変更

`spot_identities.display_name` を更新し、**旧名を `spot_aliases` に `alternate` として残す**
（`valid_to` を設定して閉じる）。slug を変える場合は旧 slug を `legacy_slug` として残し、
URL のリダイレクトに使う。

```
UPDATE spot_identities SET display_name='◯◯岬展望台' WHERE id=X;
INSERT INTO spot_aliases (identity_id, kind, value, valid_from, valid_to)
     VALUES (X, 'alternate', '◯◯展望台', '2026-01-01', now());
```

**slug は原則変えない。** 名前が変わっても URL は維持するのが利用者にとって親切であり、
リダイレクトの連鎖も防げる。

### 4. POI提供元の変更

`spot_sources` の現行行を閉じ、新しい行を開く。**identity は変わらない。**

```
-- OSM の node が way に付け替わった / 運営登録に切り替えた
UPDATE spot_sources SET is_current=false, unlinked_at=now()
 WHERE identity_id=X AND is_current;
INSERT INTO spot_sources (identity_id, source_kind, external_ref)
     VALUES (X, 'osm', 'way/987654321');
```

OSM 側で POI が削除された場合は、`source_kind='cluster'` または `'operator'` に切り替えるか、
投稿がゼロなら identity を `retired` にする。**投稿があるスポットは絶対に retire しない**
（ユーザーの記録が孤立するため）。

---

## 再計算時の identity 割り当て

粒度再計算（docs/01 §4.3）の中で、新しい `spots` 行それぞれに identity を決める。
**決定的であること**（同じ入力なら同じ出力）が要件。冪等な再実行を守るため。

```
新スポット s について:

1. s.kind='poi' かつ spot_sources に同じ external_ref の現行行がある
   → その identity を継続                                    【最強のシグナル】

2. 旧アクティブ版の各スポット o について、投稿集合の Jaccard 係数を計算
   J(s, o) = |posts(s) ∩ posts(o)| / |posts(s) ∪ posts(o)|
   最大の J が閾値以上なら o の identity を継承候補にする

3. 1つの旧スポットが複数の新スポットの継承候補になった → 分割として処理
   複数の旧スポットが1つの新スポットの候補になった → 統合として処理

4. 候補が無い（投稿ゼロの新規POIスポットを含む）→ 新しい identity を発番

5. 後継が無い旧スポットで、投稿ゼロのもの → retired
   投稿があるものは retire しない（統合先を必ず割り当てる）
```

**閾値（Jaccard の下限）は未確定。** 実データで分布を見てから決める。初期値の目安は 0.3
だが、**根拠が無いため承認対象から外し、T-10（H3解像度の決定）と同じタイミングで
実データを見て確定する**ことを提案する。

---

## ビューと解決関数

```sql
-- 現行の粒度における、生きているスポットの一覧
CREATE VIEW v_spot_current AS
SELECT i.id            AS identity_id,
       i.slug,
       i.display_name,
       s.id            AS spot_id,
       s.grain_version_id,
       s.kind,
       s.centroid,
       s.post_count,
       src.source_kind,
       src.external_ref
FROM spot_identities i
JOIN spots s               ON s.identity_id = i.id
JOIN spot_grain_versions g ON g.id = s.grain_version_id AND g.status = 'active'
LEFT JOIN spot_sources src ON src.identity_id = i.id AND src.is_current
WHERE i.status = 'active';

-- slug（現行 or 旧）から最終的な identity を解決する。merged を辿る
CREATE FUNCTION resolve_spot_slug(p_slug text, p_max_hops int DEFAULT 8)
RETURNS uuid LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_id   uuid;
    v_next uuid;
    v_hops int := 0;
BEGIN
    SELECT id INTO v_id FROM spot_identities WHERE slug = p_slug;
    IF v_id IS NULL THEN
        SELECT a.identity_id INTO v_id
          FROM spot_aliases a
         WHERE a.kind = 'legacy_slug' AND a.value = p_slug
         ORDER BY a.created_at DESC
         LIMIT 1;
    END IF;
    IF v_id IS NULL THEN RETURN NULL; END IF;

    -- 統合の連鎖を辿る。循環に備えて上限を設ける
    LOOP
        SELECT merged_into_id INTO v_next FROM spot_identities WHERE id = v_id;
        EXIT WHEN v_next IS NULL;
        v_hops := v_hops + 1;
        IF v_hops > p_max_hops THEN
            RAISE EXCEPTION 'spot identity merge chain too deep or cyclic: %', p_slug;
        END IF;
        v_id := v_next;
    END LOOP;
    RETURN v_id;
END;
$$;
```

---

## 移行手順（既存スキーマから）

**マイグレーションは追記のみ**（CLAUDE.md 規約）。`0008` 以降で行う。

1. `spot_identities` / `spot_aliases` / `spot_sources` / `spot_lineage` を作成
2. `spots.identity_id` を nullable で追加
3. 既存の `spots` 全行に identity を1対1で発番
   （現状 `active` な粒度バージョンは1本だけなので単純な1対1でよい）
   - `display_name` / `name_source` を identity 側へ複写
   - `poi_source` / `poi_external_id` から `spot_sources` を生成
   - slug を生成（規則は後述の未解決事項）
4. `spots.identity_id` を NOT NULL 化し、ユニークインデックスを張る
5. `spot_name_proposals.spot_id` を identity 参照へ付け替え
6. `spot_follows`（P-03・新規）は**最初から identity を参照して作る**

**現時点で本番データが無いため、この移行は低リスク**である。
実装が進んでからでは 3 が重くなるため、**T-01 を先に片付ける意義はここにある。**

---

## 影響

| 対象 | 影響 |
|---|---|
| `spots` | `identity_id` 追加。`display_name` / `name_source` は identity へ移し廃止予定 |
| `spot_name_proposals` | 参照先を identity へ |
| `spot_follows`（P-03） | **identity を参照**（未実装なので設計時点で対応できる） |
| API | スポットのURLは `slug` ベース。`resolve_spot_slug` でリダイレクト |
| 再計算ジョブ（T-21） | identity 割り当てと lineage 記録の工程が増える |
| T-34（OSM取り込み） | POI ごとに identity を作る。`spot_sources.external_ref` が同一性の鍵 |
| `v_grain_health` | 変更不要 |
| 表示ポリシー | 変更なし（identity は名前とURLのみを持ち、スコアを持たない） |

---

## 検証済みの振る舞い

提案スキーマを使い捨てDB（PostgreSQL 16 + PostGIS、既存 `0001`〜`0007` の上）へ適用し、
**21項目の振る舞いを実際に動かして確認した**（2026-08-13）。リポジトリにはまだ入れていない。

| # | 確認した振る舞い |
|---|---|
| 1 | 統合された旧 slug が統合先の identity へ解決される。現行 slug はそのまま解決される |
| 2 | 統合の連鎖（A→B→C）を辿って最終IDに到達する。**循環参照は例外で止まり無限ループしない** |
| 3 | 自分自身への統合は CHECK で拒否される |
| 4 | `status='active'` のまま統合先だけ設定することはできない |
| 5 | 分割が親→子2件として記録され、過半を引き継いだ側が元の identity を継続する |
| 6 | **同じ identity が同じ粒度バージョンに2つ現れない**（分割は必ず新IDを作る） |
| 7 | 名称を変えても slug（URL）は変わらず、旧名が期間付きで履歴に残る |
| 8 | 提供元が変わっても identity は変わらず、旧い由来も履歴として残る |
| 9 | 同一の OSM 参照を2つのスポットが同時に持てない |
| 10 | **投稿ゼロの POI 由来スポットを作れ、現行ビューに出る**（P-06 の前提） |
| 11 | 統合済み identity は現行ビューから消えるが、URL は解決できる |

### 検証で見つけた設計上の修正

`spot_lineage.post_share` を当初 `real`（浮動小数点）にしていたが、**この値は
「どちらの子が identity を継続するか」を決める判断に使われる**。浮動小数点だと同値判定が
ブレて再計算の決定性が崩れるため、**`numeric(4,3)` に変更した**。

## 却下した案

- **`spots` の主キーを粒度バージョンから独立させ、粒度ごとに UPDATE する**:
  不変条件 I-2 / I-3 に真っ向から反する。過去の再現性が失われる
- **`ranking_entries` を identity 直参照にする**: 表示は簡単になるが、
  「どの粒度で算出された順位か」を失う。原則10（バージョンと履歴を保持）に反する
- **identity を作らず、slug だけを安定させる**: 分割・統合を表現できず、
  フォローや称号の移送先が決められない

---

## slug の生成規則（決定）

**URL には日本語を入れず、ローマ字にする。**

```
slug = {base}-{suffix}       例: misaki-tenboudai-k7f2qa
       {suffix} のみ          例: spot-k7f2qa      （base を作れない場合）
```

### base の決定順

| 優先 | 入力 | 備考 |
|---|---|---|
| 1 | OSM `name:ja_rm`（ローマ字タグ） | そのまま使える |
| 2 | OSM `name:en` | 英語名。実質ローマ字であることが多い |
| 3 | 読み仮名（OSM `name:ja_kana` / **ユーザー命名時に入力された読み**） | ヘボン式で機械的にローマ字化する |
| 4 | どれも無い | base を付けず `spot-{suffix}` にする |

**漢字から直接ローマ字化しない。** 漢字の読みを得るには形態素解析器（MeCab / SudachiPy）と
数百MBの辞書が必要で、依存として重すぎる。**仮名からローマ字への変換は機械的**（辞書不要）なので、
入力が仮名であることを前提にする。

### 実測したカバレッジ（2026-08-13・Overpass API）

| | 件数 | 割合 |
|---|---|---|
| `tourism=viewpoint`（日本） | 6,658 | 100% |
| うち `name:en` を持つ | **970** | **14.6%** |

`name:ja_rm` / `name:ja_kana` の件数は Overpass のレート制限により未計測。

**つまり、OSM 由来スポットの多くは初期状態で `spot-{suffix}` 形式になる。** これは許容する。
理由は2つ:

1. **slug の第一目的は「壊れない安定したURL」**であって、読みやすさは副次的
2. **ユーザーが命名したスポットは読み仮名を必須入力にする**ことで base を作れる。
   この読みは `spot_aliases.kind='reading'` にも入り、**日本語検索にも効く**（一石二鳥）

### 正規化と suffix

```
base   : 小文字化 → 英数字以外をハイフンに → 連続ハイフンを1つに → 前後のハイフンを除去 → 40文字で切る
suffix : identity の UUID から決定的に導出する小文字 Base32 の6文字
```

- **suffix は常に付ける。** 「◯◯展望台」のような名前は全国に大量にあり衝突するため
- suffix を UUID から決定的に導出するので、**再生成しても同じ slug になる**（冪等）
- `spot_identities.slug` に UNIQUE 制約があるため、万一衝突したら桁を増やして再試行する
- **名称が変わっても slug は変えない**（§4「名称変更」参照）

---

## 統合時のフォローの扱い（決定）

**特別な仕組みは作らない。ユーザーにも通知しない。**

統合処理の中で、フォロー行を生存する identity へ単純に付け替えるだけにする。

```sql
-- Y が X へ統合されるとき
INSERT INTO spot_follows (user_id, identity_id)
SELECT user_id, :x FROM spot_follows WHERE identity_id = :y
ON CONFLICT (user_id, identity_id) DO NOTHING;   -- 既に X をフォロー済みなら捨てる
DELETE FROM spot_follows WHERE identity_id = :y;
```

- **通知しない。** 統合は粒度変更に伴う内部的な出来事であり、ユーザーの関心事ではない。
  T-27（通知イベント仕様）の対象外とする
- 重複は `ON CONFLICT DO NOTHING` で捨てる（X と Y の両方をフォローしていた場合）
- 移送のためのUIも履歴表示も作らない。**`spot_lineage` に記録が残るので、
  問い合わせがあれば辿れる**という程度で足りる

---

## 未解決

1. **Jaccard 閾値**（旧スポットとの同一性判定）— 実データを見てから。**T-10（H3解像度の決定）と
   同じタイミング**で確定する
2. **`spots.display_name` の廃止時期** — 参照を identity 側へ切り替えてから落とす二段階が安全。
   実装（T-15 / T-19）の進捗に合わせる
3. **ヘボン式変換の細部** — 長音（おう → o / ou / ō）、撥音の前の m/n、促音の扱い。
   URL に使う以上は ASCII のみとし、長音記号は使わない方針だけ決めておく
