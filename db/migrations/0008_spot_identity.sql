-- 0008_spot_identity.sql
-- T-01: スポットの永続IDと系譜（設計レビュー B-01）。
--
-- 0003 の spots は粒度バージョンごとに作り直される。つまり粒度を変えるとスポットIDが変わり、
-- 「先週◯◯展望台で1位」の称号・スポット詳細ページのURL・訪問履歴が全て切れる。
--
-- ここで導入する対応関係:
--
--     spot_identity  … 粒度に依存しない永続ID。URLと称号はこれに紐づく
--        └─ spots    … 粒度バージョンごとの「実体」。従来どおり作り直してよい
--
-- 不変条件 I-1〜I-3（docs/01 §0）はそのまま維持する。spot_identity は新しい軸を足すもので、
-- posts に spot_id を戻すものではない。


-- ---------------------------------------------------------------------------
-- spot_source — スポットの出自（従来の spots.poi_source text を実体化）
-- ---------------------------------------------------------------------------
-- ライセンス条件のカラムを持たせてあるのは、T-05（POIソースのライセンスADR）の結論を
-- 置く場所を先に確保するため。cache_allowed = false のプロバイダを採用した場合、
-- spot_poi_cache の保持ポリシーと docs/01 §4.3 の再計算設計を見直す必要がある。
-- 値の確定は T-05 の担当であり、ここでの初期値は「未確認」を表す NULL にしてある。

CREATE TABLE spot_source (
    code                   text        PRIMARY KEY,
    display_name           text        NOT NULL,
    is_external            boolean     NOT NULL,

    -- T-05 で埋める。NULL = 規約を未確認。
    cache_allowed          boolean,
    cache_max_age_days     integer,
    redistribution_allowed boolean,
    attribution_text       text,       -- 表示義務がある場合の帰属表示文言
    terms_url              text,

    note                   text,
    created_at             timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT spot_source_cache_age_ck CHECK (cache_max_age_days IS NULL OR cache_max_age_days > 0)
);

COMMENT ON TABLE spot_source IS
    'スポットの出自とライセンス条件。cache_allowed 等の確定は T-05（POIライセンスADR）。';

INSERT INTO spot_source (code, display_name, is_external, note) VALUES
    ('azure_maps',      'Azure Maps',   true,  'MVPの第一候補。キャッシュ条件は T-05 で確認する'),
    ('osm',             'OpenStreetMap', true, 'ODbL。帰属表示と派生データベースの扱いが要る'),
    ('reverse_geocode', '逆ジオコーディング', true, '昇格スポットの暫定名の出所'),
    ('user',            'ユーザー作成',  false, 'DBSCAN昇格後にユーザーが命名したもの');


-- ---------------------------------------------------------------------------
-- spot_identity — 粒度に依存しない永続ID
-- ---------------------------------------------------------------------------
-- URL（slug）と称号（ranking_entries）はここを指す。粒度バージョンを差し替えても
-- この行は作り直さないので、リンクも履歴も切れない。

CREATE TYPE spot_identity_status AS ENUM (
    'active',   -- 通常
    'merged',   -- 別のidentityへ統合された。merged_into を辿る
    'retired'   -- 実体が無くなった（誤検出スポットの取り消しなど）
);

CREATE TABLE spot_identity (
    id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    -- URLに出る不変のキー。粒度変更で絶対に変えない。
    slug                 text        NOT NULL,
    status               spot_identity_status NOT NULL DEFAULT 'active',

    -- 表示用のキャッシュ。アクティブな粒度バージョンの実体から昇格させる。
    -- 正としてはあくまで spots 側であり、ここは一覧表示のための非正規化。
    canonical_name       text,
    name_source          spot_name_source,
    source_code          text        REFERENCES spot_source (code),
    -- 地図ピンと旧URLの解決に使う代表点。粒度が変わっても大きくは動かない。
    representative_point geography(Point, 4326) NOT NULL,

    merged_into          uuid        REFERENCES spot_identity (id),
    created_at           timestamptz NOT NULL DEFAULT now(),
    retired_at           timestamptz,

    CONSTRAINT spot_identity_slug_key   UNIQUE (slug),
    CONSTRAINT spot_identity_merged_ck  CHECK ((status = 'merged') = (merged_into IS NOT NULL)),
    -- 自分自身への統合は無限ループになる
    CONSTRAINT spot_identity_self_ck    CHECK (merged_into IS DISTINCT FROM id)
);

CREATE INDEX spot_identity_point_gix  ON spot_identity USING gist (representative_point);
CREATE INDEX spot_identity_active_idx ON spot_identity (status) WHERE status = 'active';

COMMENT ON TABLE spot_identity IS
    '粒度に依存しないスポットの永続ID。URLと称号履歴の連続性はこの行が担保する（T-01 / B-01）。';


-- ---------------------------------------------------------------------------
-- spot_alias — 旧URL・旧名・外部ID
-- ---------------------------------------------------------------------------
-- 統合や改名でどのキーが使われなくなっても、301 で現行の identity に解決できるようにする。
-- 「旧URLが2つの identity を指す」状態を作らないため、値は種別ごとに一意にする。

CREATE TYPE spot_alias_kind AS ENUM (
    'slug',          -- 旧URL
    'display_name',  -- 旧表示名（検索とユーザーの記憶のため）
    'external'       -- 外部POI ID（提供元が同じスポットに別IDを振り直した場合）
);

CREATE TABLE spot_alias (
    id           bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    identity_id  uuid            NOT NULL REFERENCES spot_identity (id) ON DELETE CASCADE,
    alias_kind   spot_alias_kind NOT NULL,
    alias_value  text            NOT NULL,
    source_code  text            REFERENCES spot_source (code),
    valid_from   timestamptz     NOT NULL DEFAULT now(),
    valid_to     timestamptz,

    CONSTRAINT spot_alias_uix UNIQUE (alias_kind, alias_value)
);

CREATE INDEX spot_alias_identity_idx ON spot_alias (identity_id);


-- ---------------------------------------------------------------------------
-- spot_lineage — 分割・統合の履歴
-- ---------------------------------------------------------------------------
-- 粒度を細かくすると1スポットが2つに割れ、粗くすると2つが1つになる。
-- 「先週1位を取ったスポット」が今週どれに当たるかを辿れないと、称号の引き継ぎが決められない。
--
-- post_share（親の投稿のうちこの子に流れた割合）を持たせているのは、分割時に
-- 「主系列＝slugを引き継ぐ側」を機械的に決めるため。最大シェアの子が slug を継ぐ。

CREATE TYPE spot_lineage_op AS ENUM (
    'create',      -- 新しい粒度バージョンで初めて出現した
    'carry_over',  -- 1対1でそのまま引き継がれた
    'split',       -- 親1 → 子N
    'merge'        -- 親N → 子1
);

CREATE TABLE spot_lineage (
    id                    bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    op                    spot_lineage_op NOT NULL,
    from_grain_version_id smallint  REFERENCES spot_grain_versions (id) ON DELETE CASCADE,
    to_grain_version_id   smallint  NOT NULL REFERENCES spot_grain_versions (id) ON DELETE CASCADE,

    parent_identity_id    uuid      REFERENCES spot_identity (id) ON DELETE CASCADE,
    child_identity_id     uuid      NOT NULL REFERENCES spot_identity (id) ON DELETE CASCADE,

    -- 親の投稿のうち、この子に流れた割合（0.0–1.0）
    post_share            real,
    moved_post_count      integer,
    created_at            timestamptz NOT NULL DEFAULT now(),

    -- create だけが親を持たない。それ以外は親が必須。
    CONSTRAINT spot_lineage_parent_ck CHECK ((op = 'create') = (parent_identity_id IS NULL)),
    CONSTRAINT spot_lineage_share_ck  CHECK (post_share IS NULL OR (post_share >= 0 AND post_share <= 1)),
    CONSTRAINT spot_lineage_uix       UNIQUE NULLS NOT DISTINCT
        (to_grain_version_id, parent_identity_id, child_identity_id)
);

CREATE INDEX spot_lineage_child_idx  ON spot_lineage (child_identity_id);
CREATE INDEX spot_lineage_parent_idx ON spot_lineage (parent_identity_id);

COMMENT ON TABLE spot_lineage IS
    '粒度変更に伴うスポットの分割・統合履歴。称号の引き継ぎ判定の根拠（T-01 / B-01）。';


-- ---------------------------------------------------------------------------
-- spots に identity を持たせる
-- ---------------------------------------------------------------------------
-- 既存行には後段のバックフィルで埋めてから NOT NULL にする。

ALTER TABLE spots ADD COLUMN identity_id uuid REFERENCES spot_identity (id) ON DELETE RESTRICT;

-- 従来の poi_source（自由記述の text）を spot_source へ寄せる。
-- 既存カラムは残す。0003 のチェック制約が参照しているため落とせない。
ALTER TABLE spots ADD COLUMN source_code text REFERENCES spot_source (code);

-- 1つの粒度バージョンの中で、1つの identity に実体は1つだけ。
-- ここが崩れると「この粒度でのこのスポット」が一意に決まらなくなる。
CREATE UNIQUE INDEX spots_identity_uix ON spots (grain_version_id, identity_id);


-- ---------------------------------------------------------------------------
-- ランキング（称号）を identity に紐づける
-- ---------------------------------------------------------------------------
-- ranking_entries.spot_id は粒度バージョンごとの実体を指すため、粒度を変えると
-- 過去の称号が辿れなくなる。永続IDを併記して、そちらを称号の引き当てに使う。

ALTER TABLE ranking_entries ADD COLUMN spot_identity_id uuid REFERENCES spot_identity (id) ON DELETE CASCADE;

CREATE INDEX ranking_entry_identity_idx
    ON ranking_entries (spot_identity_id, period_id DESC);
-- バックフィルは spots.identity_id を埋めた後に行う（このファイル後段）。


-- ---------------------------------------------------------------------------
-- slug の生成
-- ---------------------------------------------------------------------------
-- 表示名があればそれを、無ければ座標を丸めた文字列を種にする。
-- 種が衝突しても identity ごとに一意になるよう、末尾に短いランダムサフィックスを付ける。
-- 日本語の表示名はそのままでは URL に使いにくいので、非ASCIIは座標にフォールバックする。

CREATE FUNCTION generate_spot_slug(
    p_display_name text,
    p_point        geography
) RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
    v_base text;
BEGIN
    v_base := lower(COALESCE(p_display_name, ''));
    v_base := regexp_replace(v_base, '[^a-z0-9]+', '-', 'g');
    v_base := trim(both '-' from v_base);

    -- 日本語名など ASCII に落ちなかった場合は座標を種にする
    IF v_base = '' THEN
        v_base := 'spot-' || to_char(ST_Y(p_point::geometry), 'FM90.0000')
                          || '-' || to_char(ST_X(p_point::geometry), 'FM990.0000');
        v_base := replace(v_base, '.', '');
    END IF;

    -- サフィックスは gen_random_uuid()（PostgreSQL 13+ の組み込み）から作る。
    -- pgcrypto の gen_random_bytes は Azure の対応拡張の確認が済んでいないので使わない。
    RETURN left(v_base, 48) || '-' || substr(md5(gen_random_uuid()::text), 1, 6);
END;
$$;

COMMENT ON FUNCTION generate_spot_slug IS
    'URL用の不変キーを作る。一度発行したら粒度変更でも変えない（変えると旧URLが死ぬ）。';


-- ---------------------------------------------------------------------------
-- 既存 spots へのバックフィル
-- ---------------------------------------------------------------------------
-- 導入時点で存在する実体それぞれに identity を発行し、系譜に 'create' を1件残す。

DO $$
DECLARE
    r RECORD;
    v_identity uuid;
BEGIN
    FOR r IN
        SELECT id, grain_version_id, display_name, name_source, poi_source, centroid
          FROM spots
         WHERE identity_id IS NULL
         ORDER BY created_at, id
    LOOP
        INSERT INTO spot_identity (
            slug, canonical_name, name_source, source_code, representative_point
        ) VALUES (
            generate_spot_slug(r.display_name, r.centroid),
            r.display_name,
            r.name_source,
            (SELECT code FROM spot_source WHERE code = r.poi_source),
            r.centroid
        )
        RETURNING id INTO v_identity;

        UPDATE spots
           SET identity_id = v_identity,
               source_code = (SELECT code FROM spot_source WHERE code = r.poi_source)
         WHERE id = r.id;

        INSERT INTO spot_lineage (op, to_grain_version_id, child_identity_id)
        VALUES ('create', r.grain_version_id, v_identity);
    END LOOP;
END;
$$;

ALTER TABLE spots ALTER COLUMN identity_id SET NOT NULL;

-- 既存の称号を永続IDへ寄せる。埋めてから NOT NULL にするのは、
-- 導入前に積まれた「先週◯◯で1位」を落とさないため。
UPDATE ranking_entries e
   SET spot_identity_id = s.identity_id
  FROM spots s
 WHERE s.id = e.spot_id AND e.spot_identity_id IS NULL;

ALTER TABLE ranking_entries ALTER COLUMN spot_identity_id SET NOT NULL;


-- ---------------------------------------------------------------------------
-- 実体の作成 — identity の発行と再利用をまとめる
-- ---------------------------------------------------------------------------
-- 新しい粒度バージョンを作るとき、スポット解決フロー（docs/01 §1.2）は
-- 「この場所は前の粒度のどのスポットの続きか」を決めなければならない。
-- p_parent_identity_id を渡せば系譜が繋がり、渡さなければ新規スポットになる。

CREATE FUNCTION upsert_spot_with_identity(
    p_grain_version_id   smallint,
    p_kind               spot_kind,
    p_h3_index           bigint,
    p_centroid           geography,
    p_display_name       text     DEFAULT NULL,
    p_name_source        spot_name_source DEFAULT NULL,
    p_source_code        text     DEFAULT NULL,
    p_poi_external_id    text     DEFAULT NULL,
    p_parent_identity_id uuid     DEFAULT NULL,
    p_lineage_op         spot_lineage_op DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql
AS $$
DECLARE
    v_identity uuid;
    v_spot     uuid;
    v_op       spot_lineage_op;
BEGIN
    IF p_parent_identity_id IS NOT NULL THEN
        -- 既存スポットの続き。slug も称号も引き継がれる。
        v_identity := p_parent_identity_id;
        v_op       := COALESCE(p_lineage_op, 'carry_over');
    ELSE
        INSERT INTO spot_identity (
            slug, canonical_name, name_source, source_code, representative_point
        ) VALUES (
            generate_spot_slug(p_display_name, p_centroid),
            p_display_name, p_name_source, p_source_code, p_centroid
        )
        RETURNING id INTO v_identity;
        v_op := COALESCE(p_lineage_op, 'create');
    END IF;

    INSERT INTO spots (
        grain_version_id, kind, h3_index, centroid,
        display_name, name_source, poi_source, source_code, poi_external_id, identity_id
    ) VALUES (
        p_grain_version_id, p_kind, p_h3_index, p_centroid,
        p_display_name, p_name_source, p_source_code, p_source_code, p_poi_external_id, v_identity
    )
    ON CONFLICT (grain_version_id, identity_id) DO UPDATE SET
        h3_index     = EXCLUDED.h3_index,
        centroid     = EXCLUDED.centroid,
        display_name = COALESCE(EXCLUDED.display_name, spots.display_name)
    RETURNING id INTO v_spot;

    INSERT INTO spot_lineage (
        op, from_grain_version_id, to_grain_version_id, parent_identity_id, child_identity_id
    )
    SELECT v_op,
           (SELECT grain_version_id FROM spots WHERE identity_id = p_parent_identity_id
              AND grain_version_id <> p_grain_version_id ORDER BY grain_version_id DESC LIMIT 1),
           p_grain_version_id,
           CASE WHEN v_op = 'create' THEN NULL ELSE p_parent_identity_id END,
           v_identity
    ON CONFLICT DO NOTHING;

    RETURN v_spot;
END;
$$;


-- ---------------------------------------------------------------------------
-- 改名 — 旧名を alias に退避してから差し替える
-- ---------------------------------------------------------------------------
-- ユーザーが記憶している名前で検索できなくなるのを防ぐ。

CREATE FUNCTION rename_spot_identity(
    p_identity_id uuid,
    p_new_name    text,
    p_name_source spot_name_source
) RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    v_old text;
BEGIN
    SELECT canonical_name INTO v_old FROM spot_identity WHERE id = p_identity_id;

    IF v_old IS NOT NULL AND v_old IS DISTINCT FROM p_new_name THEN
        INSERT INTO spot_alias (identity_id, alias_kind, alias_value, valid_to)
        VALUES (p_identity_id, 'display_name', v_old, now())
        ON CONFLICT (alias_kind, alias_value) DO NOTHING;
    END IF;

    UPDATE spot_identity
       SET canonical_name = p_new_name, name_source = p_name_source
     WHERE id = p_identity_id;
END;
$$;


-- ---------------------------------------------------------------------------
-- 統合 — 旧 slug を alias に残してから統合先へ寄せる
-- ---------------------------------------------------------------------------
-- 粒度を粗くしたときに2つのスポットが1つになるケース。旧URLは 301 で生き続ける。

CREATE FUNCTION merge_spot_identity(
    p_from_identity_id  uuid,
    p_into_identity_id  uuid,
    p_grain_version_id  smallint
) RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    v_slug text;
BEGIN
    IF p_from_identity_id = p_into_identity_id THEN
        RAISE EXCEPTION '自分自身へは統合できない: %', p_from_identity_id;
    END IF;

    SELECT slug INTO v_slug FROM spot_identity WHERE id = p_from_identity_id;

    -- 旧URLを統合先に向ける
    INSERT INTO spot_alias (identity_id, alias_kind, alias_value, valid_to)
    VALUES (p_into_identity_id, 'slug', v_slug, now())
    ON CONFLICT (alias_kind, alias_value) DO NOTHING;

    UPDATE spot_identity
       SET status = 'merged', merged_into = p_into_identity_id
     WHERE id = p_from_identity_id;

    INSERT INTO spot_lineage (
        op, to_grain_version_id, parent_identity_id, child_identity_id, post_share
    ) VALUES (
        'merge', p_grain_version_id, p_from_identity_id, p_into_identity_id, 1.0
    )
    ON CONFLICT DO NOTHING;
END;
$$;


-- ---------------------------------------------------------------------------
-- URL の解決 — 現行 slug と旧 slug の両方を受ける
-- ---------------------------------------------------------------------------
-- 統合が連鎖している場合（A→B→C）も終端まで辿る。

CREATE FUNCTION resolve_spot_slug(p_slug text)
RETURNS uuid
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_id    uuid;
    v_next  uuid;
    v_hops  integer := 0;
BEGIN
    SELECT id INTO v_id FROM spot_identity WHERE slug = p_slug;

    IF v_id IS NULL THEN
        SELECT identity_id INTO v_id
          FROM spot_alias WHERE alias_kind = 'slug' AND alias_value = p_slug;
    END IF;

    -- 統合の連鎖を辿る。循環していたら諦める（制約で作れないはずだが保険）
    LOOP
        SELECT merged_into INTO v_next FROM spot_identity WHERE id = v_id;
        EXIT WHEN v_next IS NULL OR v_hops >= 8;
        v_id   := v_next;
        v_hops := v_hops + 1;
    END LOOP;

    RETURN v_id;
END;
$$;

COMMENT ON FUNCTION resolve_spot_slug IS
    '現行slug・旧slug・統合の連鎖のいずれからでも現行の identity に解決する。旧URLを死なせないため。';


-- ---------------------------------------------------------------------------
-- v_spot_public — スポット詳細ページが読む唯一のビュー
-- ---------------------------------------------------------------------------
-- アクティブな粒度バージョンの実体を identity に重ねて返す。
-- API が spots を直接引くと、粒度バージョンの選択を毎回書くことになり事故る。

CREATE VIEW v_spot_public AS
SELECT
    i.id                                        AS identity_id,
    i.slug,
    COALESCE(s.display_name, i.canonical_name)  AS display_name,
    i.name_source,
    i.source_code,
    src.attribution_text,                        -- 表示義務がある場合はUIに出す（T-05）
    i.representative_point,
    s.id                                        AS spot_id,
    s.grain_version_id,
    s.kind,
    s.post_count,
    s.distinct_user_count,
    s.bearing_split_enabled,
    s.first_post_at,
    s.last_post_at
FROM spot_identity i
LEFT JOIN spots s
       ON s.identity_id = i.id
      AND s.grain_version_id = (SELECT id FROM spot_grain_versions WHERE status = 'active')
LEFT JOIN spot_source src ON src.code = i.source_code
WHERE i.status = 'active';

COMMENT ON VIEW v_spot_public IS
    'スポット詳細ページ用。粒度バージョンの選択をここに閉じ込める。';


-- ---------------------------------------------------------------------------
-- v_spot_titles — 称号履歴（粒度変更をまたいで連続する）
-- ---------------------------------------------------------------------------
-- 「先週◯◯展望台で1位」の原資。ranking_entries を直接引かせないのは、
-- total_score と下位順位が漏れるため（docs/00 §3【変更禁止】）。

CREATE VIEW v_spot_titles AS
SELECT
    e.spot_identity_id,
    i.slug,
    COALESCE(i.canonical_name, s.display_name) AS spot_name,
    p.author_id,
    e.post_id,
    e.period_id,
    per.kind        AS period_kind,
    per.starts_at,
    per.ends_at,
    e.bearing_sector,
    e.weather,
    e.timeslot,
    e.season,
    e.rank
FROM ranking_entries e
JOIN spot_identity   i   ON i.id = e.spot_identity_id
JOIN spots           s   ON s.id = e.spot_id
JOIN posts           p   ON p.id = e.post_id
JOIN ranking_periods per ON per.id = e.period_id
-- 称号は1位のみ。順位そのものを晒さないための絞り込みでもある。
WHERE e.rank = 1;

COMMENT ON VIEW v_spot_titles IS
    '称号履歴。永続IDで引くため、粒度バージョンを差し替えても過去の称号が切れない（T-01 の完了条件）。';
