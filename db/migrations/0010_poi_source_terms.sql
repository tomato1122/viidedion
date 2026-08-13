-- 0010_poi_source_terms.sql
-- T-05: POIソースのライセンス条件（設計レビュー B-11）。結論は docs/06-adr-poi-source.md。
--
-- 決定: MVPのPOIソースは OpenStreetMap（ODbL）。地域抽出を自前の PostGIS に取り込み、
--       外部POI APIは呼ばない。
--
-- 理由の核心は「docs/01 §4.3 の再計算設計が生き残る唯一の選択肢だから」。
-- Azure Maps の規約はキャッシュを latency 低減目的に限り、保持を最大6か月に制限する。
-- 再計算のために応答を溜めておく行為は「scaling Results to serve multiple users」に当たる。


-- ---------------------------------------------------------------------------
-- spot_source — 採用の可否とライセンス条件を埋める
-- ---------------------------------------------------------------------------
-- adopted は「MVPで実際に使う外部ソース」の印。却下したソースも行として残すのは、
-- ADR の却下理由を後からクエリで辿れるようにするため。

ALTER TABLE spot_source ADD COLUMN adopted boolean NOT NULL DEFAULT false;

-- 採用する外部ソースは同時に1つだけ。複数のPOIソースを混ぜると、
-- Azure Maps の「third-party map database に Results を表示してはいけない」条項のような
-- ソース間の相互制約を踏む。
CREATE UNIQUE INDEX spot_source_adopted_uix
    ON spot_source ((adopted)) WHERE adopted AND is_external;

INSERT INTO spot_source (code, display_name, is_external, note)
VALUES ('google_places', 'Google Places', true, '')
ON CONFLICT (code) DO NOTHING;

-- 採用: OpenStreetMap
UPDATE spot_source SET
    adopted                = true,
    cache_allowed          = true,
    cache_max_age_days     = NULL,          -- 保持期間の制限なし
    redistribution_allowed = true,          -- ただし ODbL（同一ライセンス）でのみ
    attribution_text       = '© OpenStreetMap contributors',
    terms_url              = 'https://www.openstreetmap.org/copyright',
    note = 'ADR-001 で採用。ODbL。派生データベースにシェアアライクが及ぶため、'
           'OSM由来の列に限った抽出をODbLで公開できる状態にしておくこと'
WHERE code = 'osm';

-- 却下: Azure Maps
UPDATE spot_source SET
    adopted                = false,
    cache_allowed          = true,          -- 条件付き。latency 低減目的に限る
    cache_max_age_days     = 180,           -- 応答ヘッダの有効期間か6か月の短いほう
    redistribution_allowed = false,
    attribution_text       = NULL,          -- Microsoft が提供する帰属表示を使う（固定文言にしない）
    terms_url              = 'https://www.microsoft.com/licensing/terms/en-US/productoffering/MicrosoftAzure/MCA',
    note = 'ADR-001 で却下。再計算目的の永続キャッシュは「scaling Results to serve multiple users」'
           'に当たり不可。Results を third-party の地図上に表示することも禁じられており、'
           'クライアントの地図描画まで縛られる'
WHERE code = 'azure_maps';

-- 却下: Google Places
UPDATE spot_source SET
    adopted                = false,
    cache_allowed          = false,         -- place ID 以外は保存不可
    cache_max_age_days     = NULL,
    redistribution_allowed = false,
    attribution_text       = NULL,          -- Google地図上でなければロゴ表示が必須
    terms_url              = 'https://developers.google.com/maps/documentation/places/web-service/policies',
    note = 'ADR-001 で却下。無期限保存できるのは place ID のみで、POI名を保持できない。'
           'docs/01 §1.4 の「POI名をそのまま継承」が成立しない'
WHERE code = 'google_places';

-- 逆ジオコーディング（昇格スポットの暫定名）の出所は未確定。docs/06 §6
UPDATE spot_source SET
    cache_allowed          = true,
    cache_max_age_days     = NULL,
    redistribution_allowed = false,
    note = 'OSM抽出から行政区画名を引ければ外部APIは不要。未検証（docs/06 §6）'
WHERE code = 'reverse_geocode';

-- ユーザー命名は自前データ
UPDATE spot_source SET
    cache_allowed          = true,
    cache_max_age_days     = NULL,
    redistribution_allowed = true,
    note = 'ユーザー生成コンテンツ。ODbL の対象外（OSM の派生データベースではない）'
WHERE code = 'user';


-- ---------------------------------------------------------------------------
-- poi_extract_versions — 取り込んだ抽出のスナップショット
-- ---------------------------------------------------------------------------
-- 抽出を更新すると POI が増減し、同じ投稿から違うスポットが出る。
-- 粒度バージョンとまったく同じ再現性の問題なので、同じようにバージョンを切る。
--
-- 再計算は「その投稿を最初に処理したときと同じ抽出バージョン」を使うこと（docs/06 §4.2）。

CREATE TABLE poi_extract_versions (
    id           smallint    PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    source_code  text        NOT NULL REFERENCES spot_source (code),
    extract_url  text        NOT NULL,
    -- Geofabrik 等のスナップショット日付。出典の明示は ODbL の義務でもある。
    extract_date date        NOT NULL,
    is_active    boolean     NOT NULL DEFAULT false,
    poi_count    integer,
    imported_at  timestamptz,
    note         text,

    CONSTRAINT poi_extract_uix UNIQUE (source_code, extract_date)
);

CREATE UNIQUE INDEX poi_extract_active_uix
    ON poi_extract_versions ((is_active)) WHERE is_active;

COMMENT ON TABLE poi_extract_versions IS
    'OSM抽出のスナップショット。再計算の再現性のためにバージョンを切る（docs/06 §4.2）。';


-- ---------------------------------------------------------------------------
-- poi_reference — 自前に取り込んだ景観POI
-- ---------------------------------------------------------------------------
-- docs/01 §1.2 手順5 の AzureMaps.searchNearby を置き換える。
-- 自分のデータベースなので保持期間の制約が無く、再計算で何度読んでも課金されない。

CREATE TABLE poi_reference (
    id                 bigint   PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    extract_version_id smallint NOT NULL REFERENCES poi_extract_versions (id) ON DELETE CASCADE,

    osm_type           text     NOT NULL,
    osm_id             bigint   NOT NULL,

    name               text,
    name_ja            text,
    -- docs/06 §4.4 の対応表で正規化したカテゴリ。生タグではなくこちらで絞る。
    -- 生タグのまま検索すると、docs/01 §1.2 が警告している「コンビニの名前を継承する」事故が起きる。
    category           text     NOT NULL,
    -- tourism=viewpoint の direction=*。その展望台がどちらを向いているか。
    -- docs/01 §2 の方位セクターと §2.3 の bearing_split_enabled の事前情報になる。
    direction_deg      real,
    location           geography(Point, 4326) NOT NULL,
    tags               jsonb    NOT NULL DEFAULT '{}'::jsonb,

    CONSTRAINT poi_reference_uix     UNIQUE (extract_version_id, osm_type, osm_id),
    CONSTRAINT poi_reference_type_ck CHECK (osm_type IN ('node', 'way', 'relation')),
    CONSTRAINT poi_reference_dir_ck  CHECK (direction_deg IS NULL
                                            OR (direction_deg >= 0 AND direction_deg < 360))
);

CREATE INDEX poi_reference_loc_gix ON poi_reference USING gist (location);
CREATE INDEX poi_reference_cat_idx ON poi_reference (extract_version_id, category);

COMMENT ON TABLE poi_reference IS
    'OSM抽出から取り込んだ景観POI。ODbL のシェアアライクが及ぶ範囲はこのテーブルとその派生（docs/06 §3）。';


-- ---------------------------------------------------------------------------
-- find_scenic_poi — スポット解決フロー手順5
-- ---------------------------------------------------------------------------
-- 最近傍を1件返す。呼び出し側は docs/01 §1.2 の手順4（吸着）で決まらなかったときだけ呼ぶ。
-- 抽出バージョンを引数に取るのは、再計算で当時のバージョンを指定できるようにするため。

CREATE FUNCTION find_scenic_poi(
    p_lat                double precision,
    p_lon                double precision,
    p_radius_m           real,
    p_extract_version_id smallint DEFAULT NULL
) RETURNS TABLE (
    poi_id        bigint,
    osm_type      text,
    osm_id        bigint,
    display_name  text,
    category      text,
    direction_deg real,
    distance_m    double precision
)
LANGUAGE sql
STABLE
AS $$
    WITH v AS (
        SELECT COALESCE(
            p_extract_version_id,
            (SELECT id FROM poi_extract_versions WHERE is_active)
        ) AS id
    ),
    origin AS (
        SELECT ST_SetSRID(ST_MakePoint(p_lon, p_lat), 4326)::geography AS g
    )
    SELECT
        r.id,
        r.osm_type,
        r.osm_id,
        COALESCE(r.name_ja, r.name),
        r.category,
        r.direction_deg,
        ST_Distance(r.location, origin.g)
    FROM poi_reference r, v, origin
    WHERE r.extract_version_id = v.id
      AND ST_DWithin(r.location, origin.g, p_radius_m)
      -- 名前の無いPOIを継承しても「この付近」と変わらないので候補にしない
      AND COALESCE(r.name_ja, r.name) IS NOT NULL
    ORDER BY r.location <-> origin.g
    LIMIT 1;
$$;

COMMENT ON FUNCTION find_scenic_poi IS
    'docs/01 §1.2 手順5。外部API呼び出しを自前テーブルの近傍検索に置き換えたもの（ADR-001）。';


-- ---------------------------------------------------------------------------
-- spot_poi_cache — 規約の保持上限をスキーマの制約にする
-- ---------------------------------------------------------------------------
-- MVPでは使わない。将来 Azure Maps 等を併用する場合に備えて残すが、
-- 「6か月を超えて保持しない」を運用の注意力ではなく CHECK 制約で守る。

ALTER TABLE spot_poi_cache ADD COLUMN expires_at timestamptz;

UPDATE spot_poi_cache SET expires_at = fetched_at + interval '180 days'
 WHERE expires_at IS NULL;

ALTER TABLE spot_poi_cache ALTER COLUMN expires_at SET NOT NULL;

-- Azure Maps: 「応答ヘッダの有効期間」か「6か月」の短いほう。
-- 180日を超える行はそもそも INSERT できない。
ALTER TABLE spot_poi_cache ADD CONSTRAINT spot_poi_cache_retention_ck
    CHECK (expires_at <= fetched_at + interval '180 days');

CREATE INDEX spot_poi_cache_expiry_idx ON spot_poi_cache (expires_at);

COMMENT ON COLUMN spot_poi_cache.expires_at IS
    '外部POI応答の保持期限。Azure Maps の規約上限（6か月）を CHECK 制約で強制している（docs/06 §4.3）。';

CREATE FUNCTION purge_expired_poi_cache() RETURNS integer
LANGUAGE plpgsql
AS $$
DECLARE v_rows integer;
BEGIN
    DELETE FROM spot_poi_cache WHERE expires_at <= now();
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    RETURN v_rows;
END;
$$;

COMMENT ON FUNCTION purge_expired_poi_cache IS
    '保持期限の切れた外部POI応答を削除する。日次で回すこと。';

-- 外部POIソースを採用した場合はこのジョブを有効にすること。
-- MVP（OSM）では spot_poi_cache を使わないので不要。
--
-- SELECT cron.schedule(
--     'purge-expired-poi-cache',
--     '30 18 * * *',                     -- 毎日 03:30 JST
--     $$ SELECT purge_expired_poi_cache(); $$
-- );


-- ---------------------------------------------------------------------------
-- v_poi_license_compliance — 規約遵守の状態を1画面で見る
-- ---------------------------------------------------------------------------
-- ライセンス条件は「決めた」だけでは守られない。運用中に崩れていないかを見る指標を置く。

CREATE VIEW v_poi_license_compliance AS
SELECT
    s.code                                   AS source_code,
    s.adopted,
    s.cache_allowed,
    s.cache_max_age_days,
    s.attribution_text,
    -- 保持上限を超えて残っている応答（あってはならない）
    (SELECT count(*) FROM spot_poi_cache c
      WHERE c.provider = s.code AND c.expires_at <= now())  AS expired_cache_rows,
    -- このソース由来のスポット数。ODbL のシェアアライク対象の規模
    (SELECT count(*) FROM spots sp WHERE sp.source_code = s.code) AS spot_count,
    -- 帰属表示が必要なのに文言が無い状態の検出
    (s.is_external AND s.adopted AND s.attribution_text IS NULL) AS attribution_missing
FROM spot_source s;

COMMENT ON VIEW v_poi_license_compliance IS
    'POIライセンス遵守の監視。expired_cache_rows > 0 と attribution_missing = true は即対処（docs/06）。';
