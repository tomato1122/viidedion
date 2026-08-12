-- 0003_spots.sql
-- スポット粒度のバージョニングと、投稿↔スポットの紐付け。
-- 設計の根拠は docs/01-spot-granularity.md。

-- ---------------------------------------------------------------------------
-- spot_grain_versions — 粒度定義のバージョン（不変条件 I-3 の起点）
-- ---------------------------------------------------------------------------
-- 粒度を変えるときは新しい行を作り、shadow で全件再計算し、最後に active を差し替える。
-- 既存行のパラメータは書き換えない（書き換えると過去の再現性が消える）。

CREATE TYPE grain_status AS ENUM (
    'draft',       -- パラメータのみ。計算未着手
    'shadow',      -- 再計算中 / 検証中。新規投稿はここにも二重書き込みする
    'active',      -- 配信で使う唯一のバージョン
    'deprecated'   -- 旧バージョン。ロールバック先として残す
);

CREATE TABLE spot_grain_versions (
    id                      smallint    PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    code                    text        NOT NULL,
    status                  grain_status NOT NULL DEFAULT 'draft',
    note                    text,

    -- 解決フローのパラメータ（docs/01 §1.1）
    h3_resolution           smallint    NOT NULL,
    snap_radius_m           real        NOT NULL,
    poi_match_radius_m      real        NOT NULL,
    bearing_sector_count    smallint    NOT NULL,
    dbscan_eps_m            real        NOT NULL,
    dbscan_min_points       smallint    NOT NULL,
    dbscan_min_users        smallint    NOT NULL,
    gps_accuracy_reject_m   real        NOT NULL,

    -- 将来パラメータを増やしたときの逃げ場。恒常的に使うものはカラムに昇格させること。
    extra                   jsonb       NOT NULL DEFAULT '{}'::jsonb,

    created_at              timestamptz NOT NULL DEFAULT now(),
    activated_at            timestamptz,
    deprecated_at           timestamptz,

    CONSTRAINT grain_code_key      UNIQUE (code),
    CONSTRAINT grain_h3_res_ck     CHECK (h3_resolution BETWEEN 0 AND 15),
    CONSTRAINT grain_sectors_ck    CHECK (bearing_sector_count IN (4, 8, 16)),
    CONSTRAINT grain_snap_ck       CHECK (snap_radius_m > 0),
    CONSTRAINT grain_dbscan_ck     CHECK (dbscan_eps_m > 0 AND dbscan_min_points >= 2 AND dbscan_min_users >= 1)
);

-- active と shadow はそれぞれ同時に1本まで。移行事故を型で防ぐ。
CREATE UNIQUE INDEX grain_single_active_uix ON spot_grain_versions ((status)) WHERE status = 'active';
CREATE UNIQUE INDEX grain_single_shadow_uix ON spot_grain_versions ((status)) WHERE status = 'shadow';


-- ---------------------------------------------------------------------------
-- spots
-- ---------------------------------------------------------------------------

CREATE TYPE spot_kind AS ENUM (
    'h3_cell',   -- 暫定。POIに当たらず、まだ昇格もしていない
    'poi',       -- 外部POIに一致し、名前を継承した
    'cluster'    -- DBSCANで昇格した独自スポット
);

CREATE TYPE spot_name_source AS ENUM ('poi', 'user', 'reverse_geocode');

CREATE TABLE spots (
    id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    grain_version_id      smallint    NOT NULL REFERENCES spot_grain_versions (id) ON DELETE CASCADE,
    kind                  spot_kind   NOT NULL,

    -- 候補引き当て用の H3 セル。アプリ層（h3-py / h3-js）で計算して入れる。
    -- 有効な H3 インデックスは最上位ビットが 0 なので signed bigint に収まる。
    h3_index              bigint      NOT NULL,
    centroid              geography(Point, 4326) NOT NULL,

    display_name          text,
    name_source           spot_name_source,
    poi_source            text,        -- 'azure_maps' など
    poi_external_id       text,

    -- 方位分割が意味を持たないスポット（海岸線・一本道）で false に落とす。
    -- 投稿20件超で円周分散を評価するバッチが更新する（docs/01 §2.3）。
    bearing_split_enabled boolean     NOT NULL DEFAULT true,

    -- 非正規化カウンタ。希少性の対数逓減で毎回参照するため実体で持つ。
    post_count            integer     NOT NULL DEFAULT 0,
    distinct_user_count   integer     NOT NULL DEFAULT 0,
    first_post_at         timestamptz,
    last_post_at          timestamptz,

    promoted_at           timestamptz, -- h3_cell から cluster へ昇格した時刻
    created_at            timestamptz  NOT NULL DEFAULT now(),

    CONSTRAINT spots_name_source_ck CHECK ((display_name IS NULL) OR (name_source IS NOT NULL)),
    CONSTRAINT spots_poi_ck         CHECK (kind <> 'poi' OR (poi_source IS NOT NULL AND poi_external_id IS NOT NULL)),
    CONSTRAINT spots_counts_ck      CHECK (post_count >= 0 AND distinct_user_count >= 0)
);

-- 同じ粒度バージョン内で、1つのH3セルに暫定スポットは1つだけ
CREATE UNIQUE INDEX spots_cell_uix ON spots (grain_version_id, h3_index) WHERE kind = 'h3_cell';
-- 同じ粒度バージョン内で、1つの外部POIにスポットは1つだけ
CREATE UNIQUE INDEX spots_poi_uix  ON spots (grain_version_id, poi_source, poi_external_id) WHERE kind = 'poi';

-- 解決フロー手順3: h3_index = ANY(gridDisk(cell,1)) で正規スポット候補を引く
CREATE INDEX spots_lookup_idx   ON spots (grain_version_id, h3_index) INCLUDE (kind);
-- 解決フロー手順4: 重心からの実距離で最終判定する（ST_DWithin）
CREATE INDEX spots_centroid_gix ON spots USING gist (centroid);


-- ---------------------------------------------------------------------------
-- post_spot_assignment — 不変条件 I-2
-- ---------------------------------------------------------------------------
-- 粒度バージョンごとに1行。旧粒度と新粒度が同時に存在できることが要点。

CREATE TYPE bind_method AS ENUM (
    'snap',     -- 既存の正規スポットに吸着（セル境界問題への対処）
    'poi',      -- POIマッチで新規作成
    'cell',     -- 暫定セルスポット
    'cluster'   -- DBSCAN昇格に伴う張り替え
);

CREATE TABLE post_spot_assignment (
    post_id           uuid        NOT NULL REFERENCES posts (id) ON DELETE CASCADE,
    grain_version_id  smallint    NOT NULL REFERENCES spot_grain_versions (id) ON DELETE CASCADE,
    spot_id           uuid        NOT NULL REFERENCES spots (id) ON DELETE CASCADE,

    h3_index          bigint      NOT NULL,
    -- 0..(bearing_sector_count-1)。NULL は「方位不明」の独立バケット。
    bearing_sector    smallint,
    bind_method       bind_method NOT NULL,
    bind_distance_m   real,
    -- 測位が粗い / 不正チェックに引っかかった投稿。「初」ボーナスの対象外にする。
    low_confidence    boolean     NOT NULL DEFAULT false,

    assigned_at       timestamptz NOT NULL DEFAULT now(),

    PRIMARY KEY (post_id, grain_version_id),
    CONSTRAINT psa_sector_ck CHECK (bearing_sector IS NULL OR bearing_sector >= 0)
);

CREATE INDEX psa_spot_idx  ON post_spot_assignment (grain_version_id, spot_id);
CREATE INDEX psa_cell_idx  ON post_spot_assignment (grain_version_id, h3_index)
    WHERE bind_method = 'cell';   -- DBSCAN昇格ジョブの走査対象


-- ---------------------------------------------------------------------------
-- spot_facet_stats — 「1位の椅子」の単位ごとの累計（docs/01 §3）
-- ---------------------------------------------------------------------------
-- facet = (grain_version, spot, bearing_sector, weather, timeslot, season)
-- 「初」判定はこのテーブルへの upsert がそのまま排他制御になる。

CREATE TABLE spot_facet_stats (
    id                bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    grain_version_id  smallint      NOT NULL REFERENCES spot_grain_versions (id) ON DELETE CASCADE,
    spot_id           uuid          NOT NULL REFERENCES spots (id) ON DELETE CASCADE,
    bearing_sector    smallint,
    weather           weather_kind,
    timeslot          timeslot_kind,
    season            season_kind,

    post_count        integer       NOT NULL DEFAULT 0,
    first_post_id     uuid          REFERENCES posts (id) ON DELETE SET NULL,
    first_post_at     timestamptz,
    last_post_at      timestamptz,

    -- NULL（=不明バケット）同士を同一視する。PostgreSQL 15+ が必要。
    CONSTRAINT spot_facet_uix UNIQUE NULLS NOT DISTINCT
        (grain_version_id, spot_id, bearing_sector, weather, timeslot, season)
);

CREATE INDEX spot_facet_spot_idx ON spot_facet_stats (grain_version_id, spot_id);


-- ---------------------------------------------------------------------------
-- spot_poi_cache — 外部POI応答のキャッシュ
-- ---------------------------------------------------------------------------
-- 再計算ジョブ（docs/01 §4.3）は外部APIを呼ばずここだけを読む。
-- これが無いと粒度変更のたびに全投稿ぶんの Azure Maps 課金が発生する。

CREATE TABLE spot_poi_cache (
    -- 問い合わせを丸めたキー: h3(res=10) + カテゴリセットのバージョン
    cache_key    text        PRIMARY KEY,
    h3_index     bigint      NOT NULL,
    radius_m     real        NOT NULL,
    provider     text        NOT NULL,
    response     jsonb       NOT NULL,
    fetched_at   timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX spot_poi_cache_h3_idx ON spot_poi_cache (h3_index);


-- ---------------------------------------------------------------------------
-- spot_name_proposals — 昇格スポットの命名（docs/01 §1.4）
-- ---------------------------------------------------------------------------

CREATE TABLE spot_name_proposals (
    id            bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    spot_id       uuid        NOT NULL REFERENCES spots (id) ON DELETE CASCADE,
    proposed_by   uuid        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    proposed_name text        NOT NULL,
    vote_count    integer     NOT NULL DEFAULT 1,
    accepted_at   timestamptz,
    created_at    timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT spot_name_proposal_uix UNIQUE (spot_id, proposed_by)
);


-- ---------------------------------------------------------------------------
-- 「初」判定 + ファセット統計更新をまとめて行う関数
-- ---------------------------------------------------------------------------
-- 戻り値 true = このファセットの初回投稿だった。
-- upsert の一意制約違反で排他されるため、同時投稿でも「初」は必ず1人にしか出ない。
--
-- eligible = false（方位不明・天候不明・測位が粗い・不正チェック失敗）のときは
-- 統計だけ更新し、初回フラグは返さない（docs/01 §3.3）。

CREATE FUNCTION record_facet_post(
    p_grain_version_id smallint,
    p_spot_id          uuid,
    p_bearing_sector   smallint,
    p_weather          weather_kind,
    p_timeslot         timeslot_kind,
    p_season           season_kind,
    p_post_id          uuid,
    p_captured_at      timestamptz,
    p_eligible         boolean
) RETURNS boolean
LANGUAGE plpgsql
AS $$
DECLARE
    v_was_first boolean;
BEGIN
    INSERT INTO spot_facet_stats AS s (
        grain_version_id, spot_id, bearing_sector, weather, timeslot, season,
        post_count, first_post_id, first_post_at, last_post_at
    )
    VALUES (
        p_grain_version_id, p_spot_id, p_bearing_sector, p_weather, p_timeslot, p_season,
        1,
        CASE WHEN p_eligible THEN p_post_id END,
        CASE WHEN p_eligible THEN p_captured_at END,
        p_captured_at
    )
    ON CONFLICT (grain_version_id, spot_id, bearing_sector, weather, timeslot, season)
    DO UPDATE SET
        post_count    = s.post_count + 1,
        last_post_at  = greatest(s.last_post_at, EXCLUDED.last_post_at),
        -- 先行する投稿がすべて ineligible だった場合、初回の座はまだ空いている
        first_post_id = COALESCE(s.first_post_id, EXCLUDED.first_post_id),
        first_post_at = COALESCE(s.first_post_at, EXCLUDED.first_post_at)
    RETURNING (s.first_post_id = p_post_id) INTO v_was_first;

    RETURN COALESCE(v_was_first, false);
END;
$$;

COMMENT ON FUNCTION record_facet_post IS
    'ファセット統計を更新し、この投稿が初回だったかを返す。「初」ボーナスの排他制御そのもの。';
