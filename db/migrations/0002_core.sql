-- 0002_core.sql
-- ユーザーと投稿。投稿テーブルは「観測事実」だけを持ち、スポットIDを一切持たない。
-- 不変条件 I-1 (docs/01-spot-granularity.md §0)

-- ---------------------------------------------------------------------------
-- 列挙型
-- ---------------------------------------------------------------------------

CREATE TYPE post_status AS ENUM (
    'pending',    -- 行だけ作成、画像未アップロード
    'uploaded',   -- Blob到着、ingest待ち
    'ingested',   -- EXIF/pHash/サムネ完了、採点待ち
    'scored',     -- ①+② 確定（③は24時間後）
    'published',  -- 公開中
    'hidden'      -- 転載検出などで非公開
);

-- 撮影地の実況天候。NULL は「取得できなかった」を意味する独立バケット。
CREATE TYPE weather_kind AS ENUM ('clear', 'cloudy', 'rain', 'snow', 'fog');

-- 撮影地の日出・日没からの相対で決める。固定時刻では切らない（docs/01 §3.1）。
CREATE TYPE timeslot_kind AS ENUM ('dawn', 'morning', 'noon', 'golden', 'dusk', 'night');

CREATE TYPE season_kind AS ENUM ('spring', 'summer', 'autumn', 'winter');

-- EXIF GPSImgDirectionRef 由来。magnetic は後から偏角補正を一括適用できるよう区別する。
CREATE TYPE bearing_source AS ENUM ('true', 'magnetic');

-- 投稿位置の公開精度。スコア計算には常に正確な値を使い、これは表示にのみ効かせる。
CREATE TYPE location_privacy AS ENUM ('exact', 'coarse_500m', 'hidden');


-- ---------------------------------------------------------------------------
-- users
-- ---------------------------------------------------------------------------

CREATE TABLE users (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    handle              text        NOT NULL,
    display_name        text        NOT NULL,
    created_at          timestamptz NOT NULL DEFAULT now(),
    -- 投票の重み付け（docs/00 §2③「同じスポットを訪れたことがあるユーザーの票を重くする」）
    -- の基礎になる。スパム投票検知でここを下げる。
    vote_trust          real        NOT NULL DEFAULT 1.0,

    CONSTRAINT users_handle_key    UNIQUE (handle),
    CONSTRAINT users_vote_trust_ck CHECK (vote_trust >= 0.0 AND vote_trust <= 3.0)
);


-- ---------------------------------------------------------------------------
-- posts
-- ---------------------------------------------------------------------------
-- ここに spot_id / rarity_score を置いてはいけない。粒度定義を変えるたびに
-- UPDATE することになり、過去の再現性が失われる。

CREATE TABLE posts (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    author_id           uuid        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    status              post_status NOT NULL DEFAULT 'pending',

    -- Blob（raw は非公開のまま保持。public は EXIF 除去済み）
    raw_blob_path       text,
    public_prefix       text,

    -- 投稿時にクライアントが申告した位置（採点の基準はこちら）
    location            geography(Point, 4326),
    gps_accuracy_m      real,
    location_privacy    location_privacy NOT NULL DEFAULT 'exact',

    -- EXIF 由来の観測値（不正対策の突合に使う。docs/02 §5）
    exif_location       geography(Point, 4326),
    exif_captured_at    timestamptz,
    exif_camera_model   text,

    -- 撮影方位。NULL は「取得できなかった」。ファセット分割は 0003 の bearing_sector で行う。
    bearing_deg         real,
    bearing_src         bearing_source,

    -- 採点に使う確定時刻。EXIF があればそれ、無ければ投稿時刻。
    captured_at         timestamptz NOT NULL,
    posted_at           timestamptz NOT NULL DEFAULT now(),

    -- ファセット次元のうち、粒度バージョンに依存しないもの。
    -- weather は撮影地・撮影時刻の「実況」を外部APIから引いた結果。
    weather             weather_kind,
    timeslot            timeslot_kind,
    season              season_kind,

    -- ingest が計算する一次特徴（docs/02 §1.2）
    phash               bigint,           -- 64bit perceptual hash（転載検出）
    tech_quality        real,             -- 0.0–1.0。①の足切り係数として使う

    created_at          timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT posts_bearing_deg_ck   CHECK (bearing_deg IS NULL OR (bearing_deg >= 0 AND bearing_deg < 360)),
    CONSTRAINT posts_bearing_src_ck   CHECK ((bearing_deg IS NULL) = (bearing_src IS NULL)),
    CONSTRAINT posts_accuracy_ck      CHECK (gps_accuracy_m IS NULL OR gps_accuracy_m >= 0),
    CONSTRAINT posts_tech_quality_ck  CHECK (tech_quality IS NULL OR (tech_quality >= 0 AND tech_quality <= 1))
);

CREATE INDEX posts_location_gix    ON posts USING gist (location);
CREATE INDEX posts_author_idx      ON posts (author_id, posted_at DESC);
CREATE INDEX posts_captured_at_idx ON posts (captured_at);
-- 転載検出は「直近90日の総当たり」で始める（docs/02 §5）。件数が増えたら索引構造を検討。
CREATE INDEX posts_phash_idx       ON posts (phash) WHERE phash IS NOT NULL;
-- 採点ワーカーの取りこぼし回収用
CREATE INDEX posts_status_idx      ON posts (status, created_at) WHERE status IN ('uploaded', 'ingested');


-- ---------------------------------------------------------------------------
-- post_integrity_checks — 不正対策（docs/00 §5 / docs/02 §5）
-- ---------------------------------------------------------------------------
-- 判定に失敗しても投稿は落とさない。フラグを立ててスコアだけ抑制する。
-- 誤検知でユーザーを失うほうが損失が大きいため。

CREATE TYPE integrity_check_kind AS ENUM (
    'exif_location_match',   -- EXIF位置と投稿位置の距離
    'exif_time_match',       -- EXIF時刻と投稿時刻の乖離
    'duplicate_image',       -- pHash 近傍に既存投稿あり
    'exif_present'           -- EXIF そのものの有無
);

CREATE TABLE post_integrity_checks (
    post_id       uuid                 NOT NULL REFERENCES posts (id) ON DELETE CASCADE,
    check_kind    integrity_check_kind NOT NULL,
    passed        boolean              NOT NULL,
    detail        jsonb                NOT NULL DEFAULT '{}'::jsonb,
    checked_at    timestamptz          NOT NULL DEFAULT now(),

    PRIMARY KEY (post_id, check_kind)
);

CREATE INDEX post_integrity_failed_idx
    ON post_integrity_checks (check_kind, checked_at)
    WHERE NOT passed;


-- 「初」ボーナスを出してよい投稿かどうかの一次判定。
-- calc_rarity_score の引数を組み立てる側がこれを見る（docs/01 §3.3）。
CREATE VIEW v_post_integrity AS
SELECT
    p.id AS post_id,
    -- 位置・時刻の偽装チェックに1つでも失敗していたら初回ボーナスは出さない
    COALESCE(bool_and(c.passed) FILTER (
        WHERE c.check_kind IN ('exif_location_match', 'exif_time_match')
    ), true) AS spoofing_clean,
    COALESCE(bool_and(c.passed) FILTER (
        WHERE c.check_kind = 'duplicate_image'
    ), true) AS not_duplicate
FROM posts p
LEFT JOIN post_integrity_checks c ON c.post_id = p.id
GROUP BY p.id;
