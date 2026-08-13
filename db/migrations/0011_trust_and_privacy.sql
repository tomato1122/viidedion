-- 0011_trust_and_privacy.sql
-- docs/04-security-design.md §5（T-04 位置情報プライバシー）と §6（T-03 投稿の信頼度）の
-- スキーマ仕様を実装する。要件ID: SEC-PRIV-02/03/04, SEC-TRUST-01/02/03。
--
-- 設計の要点は docs/04 にある。ここではそれを「アプリコードの気配りに依存させない」形に
-- 落とすことだけを行う。判定ロジックの呼び出しは T-13（ingest）が行う。


-- ===========================================================================
-- SEC-TRUST-01/03 — 投稿の信頼度
-- ===========================================================================
-- 「EXIFとハッシュで不正はほぼ潰せる」を放棄し、複数シグナルの重み付き合成に置き換える。
-- 重みと閾値は scoring_rulesets と同じくテーブルに置く。コードに埋め込むと、
-- どの投稿がどのルールで判定されたか追えなくなる。

CREATE TABLE trust_rulesets (
    id          smallint    PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    code        text        NOT NULL,
    is_active   boolean     NOT NULL DEFAULT false,
    weights     jsonb       NOT NULL,
    note        text,
    created_at  timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT trust_ruleset_code_key UNIQUE (code)
);

CREATE UNIQUE INDEX trust_ruleset_active_uix ON trust_rulesets ((is_active)) WHERE is_active;


CREATE TYPE trust_band AS ENUM (
    'normal',      -- >= 0.70。全機能
    'restricted',  -- 0.40–0.69。「初」無効・希少性×0.5。通知しない（閾値を学習させない）
    'held'         -- < 0.40。非公開 + レビューキュー。投稿者には「確認中」とだけ出す
);

CREATE TABLE post_trust_scores (
    post_id     uuid        PRIMARY KEY REFERENCES posts (id) ON DELETE CASCADE,
    ruleset_id  smallint    NOT NULL REFERENCES trust_rulesets (id),
    trust_score real        NOT NULL,
    -- 各シグナルの生値と寄与。説明可能性のために必須（docs/04 §6 受け入れ条件）。
    -- ここから内訳が復元できないと、誤検知の申し立てに答えられない。
    signals     jsonb       NOT NULL,
    band        trust_band  NOT NULL,
    computed_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT post_trust_range_ck CHECK (trust_score >= 0 AND trust_score <= 1)
);

CREATE INDEX post_trust_band_idx ON post_trust_scores (band, computed_at)
    WHERE band <> 'normal';   -- レビューキューの走査対象


INSERT INTO trust_rulesets (code, is_active, weights, note) VALUES (
    't1-mvp', true,
    jsonb_build_object(
        'trust_base',                    0.60,

        -- 加減算（docs/04 §6 SEC-TRUST-01 の表）
        'w_exif_present',                0.05,
        'w_exif_present_missing',       -0.05,
        'w_exif_location_match',         0.10,
        'w_exif_location_mismatch',     -0.25,
        'w_exif_time_match',             0.05,
        'w_exif_time_mismatch',         -0.15,
        'w_duplicate_image',            -0.60,
        'w_impossible_travel',          -0.30,
        'w_attestation_pass',            0.15,
        'w_attestation_fail',           -0.40,
        'w_in_app_capture',              0.10,
        'w_account_new',                -0.10,
        'w_account_established',         0.05,
        'w_user_history',                0.10,

        -- 閾値もルールセットに置く。実データを見て必ず動かすため。
        'th_exif_distance_m',          500.0,
        'th_exif_time_days',             7.0,
        'th_travel_speed_mps',         280.0,   -- ≈1000km/h
        'th_account_new_hours',         24.0,
        'th_account_established_days',  30.0,

        -- 帯域の境界（docs/04 §6 SEC-TRUST-02）
        'band_normal_min',               0.70,
        'band_restricted_min',           0.40,

        -- 帯域ごとの効果。既存の calc_rarity_score / record_facet_post に写す値。
        'restricted_penalty_mult',       0.5,
        'held_penalty_mult',             0.0
    ),
    'MVP暫定。device_attestation はクライアント実装（T-20）まで実質未使用'
);


-- ---------------------------------------------------------------------------
-- calc_trust_score — シグナルから信頼度と帯域を出す
-- ---------------------------------------------------------------------------
-- 生値を渡して閾値の適用まで SQL 側で行う。閾値をルールセットに入れた意味が
-- 呼び出し側で潰れないようにするため。
--
-- p_signals の例:
--   {"exif_present": true, "exif_distance_m": 120, "exif_time_diff_days": 0.5,
--    "duplicate_image": false, "travel_speed_mps": 12.4,
--    "device_attestation": "pass", "in_app_capture": true,
--    "account_age_hours": 900, "user_trust_ewma": 0.72}
--
-- 値が無いシグナルは NULL（= 判定不能）として寄与0にする。減点にはしない。
-- 誤検知でユーザーを失うほうが損失が大きい（0002 の post_integrity_checks と同じ方針）。

CREATE FUNCTION calc_trust_score(
    p_weights jsonb,
    p_signals jsonb
) RETURNS jsonb
LANGUAGE sql
IMMUTABLE
AS $$
    WITH w AS (
        SELECT
            (p_weights ->> 'trust_base')::numeric                  AS base,
            (p_weights ->> 'w_exif_present')::numeric              AS w_exif_yes,
            (p_weights ->> 'w_exif_present_missing')::numeric      AS w_exif_no,
            (p_weights ->> 'w_exif_location_match')::numeric       AS w_loc_ok,
            (p_weights ->> 'w_exif_location_mismatch')::numeric    AS w_loc_ng,
            (p_weights ->> 'w_exif_time_match')::numeric           AS w_time_ok,
            (p_weights ->> 'w_exif_time_mismatch')::numeric        AS w_time_ng,
            (p_weights ->> 'w_duplicate_image')::numeric           AS w_dup,
            (p_weights ->> 'w_impossible_travel')::numeric         AS w_travel,
            (p_weights ->> 'w_attestation_pass')::numeric          AS w_att_ok,
            (p_weights ->> 'w_attestation_fail')::numeric          AS w_att_ng,
            (p_weights ->> 'w_in_app_capture')::numeric            AS w_capture,
            (p_weights ->> 'w_account_new')::numeric               AS w_acct_new,
            (p_weights ->> 'w_account_established')::numeric       AS w_acct_old,
            (p_weights ->> 'w_user_history')::numeric              AS w_history,
            (p_weights ->> 'th_exif_distance_m')::numeric          AS th_dist,
            (p_weights ->> 'th_exif_time_days')::numeric           AS th_time,
            (p_weights ->> 'th_travel_speed_mps')::numeric         AS th_speed,
            (p_weights ->> 'th_account_new_hours')::numeric        AS th_new,
            (p_weights ->> 'th_account_established_days')::numeric AS th_old,
            (p_weights ->> 'band_normal_min')::numeric             AS b_normal,
            (p_weights ->> 'band_restricted_min')::numeric         AS b_restricted
    ),
    s AS (
        SELECT
            (p_signals ->> 'exif_present')::boolean       AS exif_present,
            (p_signals ->> 'exif_distance_m')::numeric    AS exif_distance_m,
            (p_signals ->> 'exif_time_diff_days')::numeric AS exif_time_diff_days,
            (p_signals ->> 'duplicate_image')::boolean    AS duplicate_image,
            (p_signals ->> 'travel_speed_mps')::numeric   AS travel_speed_mps,
            (p_signals ->> 'device_attestation')          AS device_attestation,
            (p_signals ->> 'in_app_capture')::boolean     AS in_app_capture,
            (p_signals ->> 'account_age_hours')::numeric  AS account_age_hours,
            (p_signals ->> 'user_trust_ewma')::numeric    AS user_trust_ewma
    ),
    c AS (
        SELECT
            CASE
                WHEN s.exif_present IS NULL THEN 0
                WHEN s.exif_present         THEN w.w_exif_yes
                ELSE w.w_exif_no
            END AS c_exif_present,

            CASE
                WHEN s.exif_distance_m IS NULL          THEN 0
                WHEN s.exif_distance_m <= w.th_dist     THEN w.w_loc_ok
                ELSE w.w_loc_ng
            END AS c_exif_location,

            CASE
                WHEN s.exif_time_diff_days IS NULL      THEN 0
                WHEN s.exif_time_diff_days <= w.th_time THEN w.w_time_ok
                ELSE w.w_time_ng
            END AS c_exif_time,

            CASE WHEN s.duplicate_image THEN w.w_dup ELSE 0 END AS c_duplicate,

            -- 直前の投稿が無ければ判定できない。減点にはしない。
            CASE
                WHEN s.travel_speed_mps IS NULL           THEN 0
                WHEN s.travel_speed_mps > w.th_speed      THEN w.w_travel
                ELSE 0
            END AS c_travel,

            -- 未対応端末は 0。クライアント実装（T-20）前は全件ここに落ちる。
            CASE s.device_attestation
                WHEN 'pass' THEN w.w_att_ok
                WHEN 'fail' THEN w.w_att_ng
                ELSE 0
            END AS c_attestation,

            CASE WHEN s.in_app_capture THEN w.w_capture ELSE 0 END AS c_capture,

            CASE
                WHEN s.account_age_hours IS NULL                    THEN 0
                WHEN s.account_age_hours <  w.th_new                THEN w.w_acct_new
                WHEN s.account_age_hours >= w.th_old * 24           THEN w.w_acct_old
                ELSE 0
            END AS c_account,

            -- ユーザー履歴（過去 trust_score の EWMA）を ±w_history に写す。
            -- 0.5 を中立とし、投稿単位の判定に薄く反映する。
            CASE
                WHEN s.user_trust_ewma IS NULL THEN 0
                ELSE round((s.user_trust_ewma - 0.5) * 2 * w.w_history, 4)
            END AS c_history,

            w.base, w.b_normal, w.b_restricted
        FROM w, s
    ),
    total AS (
        SELECT
            c.*,
            least(1.0, greatest(0.0,
                c.base + c_exif_present + c_exif_location + c_exif_time + c_duplicate
                       + c_travel + c_attestation + c_capture + c_account + c_history
            )) AS score
        FROM c
    )
    SELECT jsonb_build_object(
        'trust_score', round(total.score, 4),
        'band', CASE
                    WHEN total.score >= total.b_normal     THEN 'normal'
                    WHEN total.score >= total.b_restricted THEN 'restricted'
                    ELSE 'held'
                END,
        'base', total.base,
        'contributions', jsonb_build_object(
            'exif_present',        total.c_exif_present,
            'exif_location_match', total.c_exif_location,
            'exif_time_match',     total.c_exif_time,
            'duplicate_image',     total.c_duplicate,
            'impossible_travel',   total.c_travel,
            'device_attestation',  total.c_attestation,
            'in_app_capture',      total.c_capture,
            'account_age',         total.c_account,
            'user_history',        total.c_history
        ),
        'raw', p_signals
    )
    FROM total;
$$;

COMMENT ON FUNCTION calc_trust_score IS
    'SEC-TRUST-01/02。シグナルの生値から信頼度と帯域を出す。contributions から内訳が復元できること。';


-- ---------------------------------------------------------------------------
-- 帯域を既存の採点関数の引数に写す
-- ---------------------------------------------------------------------------
-- docs/04 §6「既存の関数シグネチャは変更不要」を守るための橋渡し。
-- calc_rarity_score(p_penalty_mult) と record_facet_post(p_eligible) に渡す値を作る。

CREATE FUNCTION trust_penalty_mult(p_weights jsonb, p_band trust_band)
RETURNS real
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT CASE p_band
        WHEN 'normal'     THEN 1.0
        WHEN 'restricted' THEN COALESCE((p_weights ->> 'restricted_penalty_mult')::real, 0.5)
        ELSE                   COALESCE((p_weights ->> 'held_penalty_mult')::real, 0.0)
    END;
$$;

-- 「初」ボーナスは通常帯だけ。抑制帯・保留帯では出さない（docs/04 §6 SEC-TRUST-02）。
CREATE FUNCTION trust_first_bonus_eligible(p_band trust_band)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$ SELECT p_band = 'normal'; $$;


-- ---------------------------------------------------------------------------
-- ユーザー信頼度の EWMA
-- ---------------------------------------------------------------------------
-- 次の投稿の user_history シグナルに使う。α=0.2（docs/04 §6）。
-- 直近の投稿ほど重い。集計ビューにしてあるのは、値を持ち回して古くなるのを避けるため。

CREATE VIEW v_user_trust_ewma AS
SELECT
    p.author_id,
    -- 新しい投稿ほど重い指数減衰の加重平均
    round((sum(t.trust_score::numeric * power(0.8, rn - 1))
           / nullif(sum(power(0.8, rn - 1)), 0))::numeric, 4) AS trust_ewma,
    count(*) AS scored_post_count
FROM (
    SELECT p.id, p.author_id,
           row_number() OVER (PARTITION BY p.author_id ORDER BY p.posted_at DESC) AS rn
    FROM posts p
) p
JOIN post_trust_scores t ON t.post_id = p.id
WHERE p.rn <= 50            -- 50件も遡れば重みは 0.8^49 ≈ 0.00002 で無視できる
GROUP BY p.author_id;

COMMENT ON VIEW v_user_trust_ewma IS
    'ユーザー信頼度（過去 trust_score の指数移動平均、α=0.2）。次の投稿の user_history シグナル。';


-- ===========================================================================
-- SEC-PRIV-02/03/04 — 位置情報プライバシー
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 表示座標（グリッドスナップ）
-- ---------------------------------------------------------------------------
-- SEC-PRIV-02: coarse_500m の表示座標は「投稿地点を含む H3 res8 セルの中心」。
-- ランダムジッターは禁止。同一地点の複数投稿を平均すると元座標が復元できるため。
--
-- **投稿に表示座標そのものを持たせない。** 投稿はセルインデックスだけを持ち、
-- 中心座標はセルごとに1行の表 h3_cell_centers から引く。こうすると
-- 「同じセルの投稿は必ず同じ座標になる」がスキーマの構造として成立し、
-- ジッターを混ぜようとしても入れる場所が無い。
--
-- H3 はアプリ層で計算する方針（0001）なので、セルの中心座標もアプリ層で求めて
-- h3_cell_centers に upsert する。

CREATE TABLE h3_cell_centers (
    h3_index   bigint PRIMARY KEY,
    resolution smallint NOT NULL,
    center     geography(Point, 4326) NOT NULL,

    CONSTRAINT h3_cell_res_ck CHECK (resolution BETWEEN 0 AND 15)
);

COMMENT ON TABLE h3_cell_centers IS
    '表示用グリッドの中心座標。セルごとに1行しか持てないので、投稿ごとにジッターを入れられない（SEC-PRIV-02）。';

ALTER TABLE posts ADD COLUMN coarse_h3_r8 bigint REFERENCES h3_cell_centers (h3_index);

COMMENT ON COLUMN posts.coarse_h3_r8 IS
    '表示用の H3 res8 セル。表示座標はここから h3_cell_centers を引いて決める（投稿に座標を持たせない）。';

CREATE INDEX posts_coarse_cell_idx ON posts (coarse_h3_r8) WHERE coarse_h3_r8 IS NOT NULL;


-- ---------------------------------------------------------------------------
-- user_privacy_zones — 自宅保護（SEC-PRIV-03）
-- ---------------------------------------------------------------------------
-- center / radius は API から読み返せない。ゾーン自体が自宅位置の漏洩源になるため、
-- 一覧に出してよいのは「ゾーンあり」の真偽と作成日時だけ（v_user_privacy_zone_summary）。

CREATE TABLE user_privacy_zones (
    id          bigint      PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    user_id     uuid        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    center      geography(Point, 4326) NOT NULL,
    radius_m    integer     NOT NULL,
    -- 'exact' は選べない。保護ゾーンなのに劣化しない設定を作れてしまうため。
    policy      location_privacy NOT NULL DEFAULT 'hidden',
    created_at  timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT privacy_zone_radius_ck CHECK (radius_m BETWEEN 200 AND 2000),
    CONSTRAINT privacy_zone_policy_ck CHECK (policy <> 'exact')
);

CREATE INDEX privacy_zone_user_idx   ON user_privacy_zones (user_id);
CREATE INDEX privacy_zone_center_gix ON user_privacy_zones USING gist (center);

-- 1ユーザーあたり5個まで（docs/04 SEC-PRIV-03）。
-- 上限を制約で持てないのでトリガーで守る。アプリ側の検証だけに任せない。
CREATE FUNCTION check_privacy_zone_limit() RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF (SELECT count(*) FROM user_privacy_zones WHERE user_id = NEW.user_id) > 5 THEN
        RAISE EXCEPTION 'プライバシーゾーンは1ユーザーあたり5個まで';
    END IF;
    RETURN NEW;
END;
$$;

CREATE CONSTRAINT TRIGGER privacy_zone_limit_trg
    AFTER INSERT ON user_privacy_zones
    FOR EACH ROW EXECUTE FUNCTION check_privacy_zone_limit();

CREATE VIEW v_user_privacy_zone_summary AS
SELECT user_id, count(*) AS zone_count, max(created_at) AS last_added_at
FROM user_privacy_zones
GROUP BY user_id;

COMMENT ON VIEW v_user_privacy_zone_summary IS
    'API に返してよいのはここまで。center / radius は返さない（ゾーン自体が漏洩源になる）。';


-- ---------------------------------------------------------------------------
-- location_blocklist — 保護地域・危険地点（SEC-PRIV-04）
-- ---------------------------------------------------------------------------

CREATE TYPE blocklist_policy AS ENUM (
    'coarse',         -- 表示を粗くする
    'hide_location',  -- 位置を出さない
    'reject'          -- 投稿自体を受け付けない
);

CREATE TABLE location_blocklist (
    id          bigint           PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    area        geography(Polygon, 4326) NOT NULL,
    -- 'protected_species' | 'hazard' | 'private_land' 等
    reason      text             NOT NULL,
    policy      blocklist_policy NOT NULL,
    note        text,
    created_at  timestamptz      NOT NULL DEFAULT now()
);

CREATE INDEX location_blocklist_gix ON location_blocklist USING gist (area);

COMMENT ON TABLE location_blocklist IS
    '保護地域・危険地点・立入禁止区域。MVPでは運用者が手動登録。データソース選定は未決定（docs/04 §10）。';


-- ---------------------------------------------------------------------------
-- 実効的な公開レベルの判定
-- ---------------------------------------------------------------------------
-- ユーザーの選択・プライバシーゾーン・ブロックリストのうち **最も厳しいもの**を採る。
-- ユーザーが exact を選んでいてもゾーン内なら上書きする（docs/04 SEC-PRIV-03）。
--
-- commit 時と publish 時の両方で呼ぶこと。片方だけだと、
-- 「公開直前にゾーンを追加した」ケースが抜ける。

CREATE FUNCTION strictest_privacy(a location_privacy, b location_privacy)
RETURNS location_privacy
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT CASE
        WHEN a = 'hidden'      OR b = 'hidden'      THEN 'hidden'
        WHEN a = 'coarse_500m' OR b = 'coarse_500m' THEN 'coarse_500m'
        ELSE 'exact'
    END::location_privacy;
$$;

CREATE FUNCTION resolve_location_privacy(
    p_user_id  uuid,
    p_location geography,
    p_requested location_privacy DEFAULT 'exact'
) RETURNS TABLE (
    effective_privacy location_privacy,
    rejected          boolean,
    reason            text
)
LANGUAGE sql
STABLE
AS $$
    WITH zone AS (
        SELECT z.policy
        FROM user_privacy_zones z
        WHERE z.user_id = p_user_id
          AND ST_DWithin(z.center, p_location, z.radius_m)
        ORDER BY z.policy DESC        -- hidden > coarse_500m > exact（enum の定義順）
        LIMIT 1
    ),
    block AS (
        SELECT b.policy, b.reason
        FROM location_blocklist b
        WHERE ST_Intersects(b.area, p_location)
        -- reject が1件でもあれば他は見なくてよい
        ORDER BY (b.policy = 'reject') DESC, (b.policy = 'hide_location') DESC
        LIMIT 1
    )
    SELECT
        strictest_privacy(
            strictest_privacy(p_requested, COALESCE((SELECT policy FROM zone), 'exact')),
            CASE (SELECT policy FROM block)
                WHEN 'hide_location' THEN 'hidden'
                WHEN 'coarse'        THEN 'coarse_500m'
                WHEN 'reject'        THEN 'hidden'
                ELSE 'exact'
            END::location_privacy
        ),
        COALESCE((SELECT policy FROM block) = 'reject', false),
        (SELECT reason FROM block);
$$;

COMMENT ON FUNCTION resolve_location_privacy IS
    'SEC-PRIV-03/04。ユーザー選択・ゾーン・ブロックリストのうち最も厳しい公開レベルを返す。commit と publish の両方で呼ぶ。';


-- ---------------------------------------------------------------------------
-- 遡及適用（SEC-PRIV-03）
-- ---------------------------------------------------------------------------
-- ゾーンを後から追加・拡大した場合、既存投稿にも効かせる。
-- これが無いと「自宅を登録する前の投稿」から住所が割れる。

CREATE FUNCTION reapply_privacy_zones(p_user_id uuid) RETURNS integer
LANGUAGE plpgsql
AS $$
DECLARE v_rows integer;
BEGIN
    -- UPDATE ... FROM LATERAL では更新対象そのものを横方向参照できないため、
    -- 新しい公開レベルを先に別クエリで確定させてから当てる。
    UPDATE posts p
       SET location_privacy = src.effective_privacy
      FROM (
            SELECT p2.id, r.effective_privacy
              FROM posts p2
              CROSS JOIN LATERAL resolve_location_privacy(
                    p2.author_id, p2.location, p2.location_privacy) r
             WHERE p2.author_id = p_user_id
               AND p2.location IS NOT NULL
      ) src
     WHERE p.id = src.id
       AND src.effective_privacy <> p.location_privacy;

    GET DIAGNOSTICS v_rows = ROW_COUNT;
    RETURN v_rows;
END;
$$;

COMMENT ON FUNCTION reapply_privacy_zones IS
    'ゾーン追加・拡大時に既存投稿へ遡及適用する。緩める方向には動かない（strictest_privacy のため）。';


-- ---------------------------------------------------------------------------
-- v_post_location_public — 座標を返してよい唯一のビュー
-- ---------------------------------------------------------------------------
-- API が posts.location を直接引くと、location_privacy を毎回自分で解釈することになり
-- いつか漏れる。「スコア計算は正確な座標、表示は劣化した座標」をビューで分離する。
--
-- exact でも投稿の生座標は出さない。表示は常にスポット単位（docs/04 SEC-PRIV-02）。

CREATE VIEW v_post_location_public AS
SELECT
    p.id AS post_id,
    p.location_privacy,
    CASE p.location_privacy
        WHEN 'exact'       THEN s.centroid
        WHEN 'coarse_500m' THEN g.center
        ELSE NULL
    END AS display_location,
    CASE WHEN p.location_privacy = 'hidden' THEN NULL
         ELSE COALESCE(i.canonical_name, s.display_name)
    END AS display_spot_name,
    CASE WHEN p.location_privacy = 'hidden' THEN NULL ELSE i.slug END AS spot_slug
FROM posts p
LEFT JOIN post_spot_assignment a
       ON a.post_id = p.id
      AND a.grain_version_id = (SELECT id FROM spot_grain_versions WHERE status = 'active')
LEFT JOIN spots           s ON s.id = a.spot_id
LEFT JOIN spot_identity   i ON i.id = s.identity_id
LEFT JOIN h3_cell_centers g ON g.h3_index = p.coarse_h3_r8;

COMMENT ON VIEW v_post_location_public IS
    '座標を返してよい唯一のビュー。posts.location を API から直接引かないこと（SEC-PRIV-02）。';
