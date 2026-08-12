-- 0005_ranking.sql
-- 週次リセットされるランキングと、表示ポリシー（docs/00 §3【変更禁止】）を型で守る公開ビュー。

-- ---------------------------------------------------------------------------
-- ranking_periods — 週次リセットの器（docs/00 §8 未決定事項への回答）
-- ---------------------------------------------------------------------------
-- 過去期間の entries は消さない。「先週◯◯部門1位」の称号の原資になる。

CREATE TYPE ranking_period_kind AS ENUM ('weekly', 'monthly', 'all_time');

CREATE TABLE ranking_periods (
    id          integer PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    kind        ranking_period_kind NOT NULL,
    starts_at   timestamptz NOT NULL,
    ends_at     timestamptz NOT NULL,
    closed_at   timestamptz,

    CONSTRAINT ranking_period_uix   UNIQUE (kind, starts_at),
    CONSTRAINT ranking_period_range CHECK (ends_at > starts_at)
);

CREATE INDEX ranking_period_current_idx ON ranking_periods (kind, ends_at DESC);


-- ---------------------------------------------------------------------------
-- ranking_entries
-- ---------------------------------------------------------------------------
-- ファセット（spot × 方位 × 天候 × 時間帯 × 季節）ごとの順位。
-- 粒度バージョンに依存するため grain_version_id を持つ（不変条件 I-3）。

CREATE TABLE ranking_entries (
    id                bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    period_id         integer      NOT NULL REFERENCES ranking_periods (id) ON DELETE CASCADE,
    grain_version_id  smallint     NOT NULL REFERENCES spot_grain_versions (id) ON DELETE CASCADE,

    spot_id           uuid         NOT NULL REFERENCES spots (id) ON DELETE CASCADE,
    bearing_sector    smallint,
    weather           weather_kind,
    timeslot          timeslot_kind,
    season            season_kind,

    post_id           uuid         NOT NULL REFERENCES posts (id) ON DELETE CASCADE,
    rank              integer      NOT NULL,
    facet_post_count  integer      NOT NULL,
    -- 上位何%か。0.05 = 上位5%。表示に使うのはこの値だけ。
    top_percentile    numeric(5,4) NOT NULL,
    -- 生の合計点。内部保持のみ。API から返してはいけない。
    total_score       numeric(6,2) NOT NULL,
    computed_at       timestamptz  NOT NULL DEFAULT now(),

    CONSTRAINT ranking_entry_uix UNIQUE NULLS NOT DISTINCT
        (period_id, grain_version_id, spot_id, bearing_sector, weather, timeslot, season, post_id),
    CONSTRAINT ranking_entry_rank_ck CHECK (rank >= 1),
    CONSTRAINT ranking_entry_pct_ck  CHECK (top_percentile > 0 AND top_percentile <= 1)
);

CREATE INDEX ranking_entry_post_idx  ON ranking_entries (post_id, period_id);
CREATE INDEX ranking_entry_facet_idx ON ranking_entries
    (period_id, grain_version_id, spot_id, rank);


-- ---------------------------------------------------------------------------
-- 期間のオープン
-- ---------------------------------------------------------------------------
-- 週の区切りは月曜 00:00 JST（= 日曜 15:00 UTC）。pg_cron から呼ぶ（0006_jobs.sql）。

CREATE FUNCTION open_next_ranking_period(
    p_kind ranking_period_kind DEFAULT 'weekly',
    p_now  timestamptz         DEFAULT now()
) RETURNS integer
LANGUAGE plpgsql
AS $$
DECLARE
    v_start timestamptz;
    v_end   timestamptz;
    v_id    integer;
BEGIN
    -- JST基準で週の頭に丸める
    v_start := date_trunc('week', p_now AT TIME ZONE 'Asia/Tokyo') AT TIME ZONE 'Asia/Tokyo';
    v_end   := v_start + interval '7 days';

    UPDATE ranking_periods
       SET closed_at = COALESCE(closed_at, p_now)
     WHERE kind = p_kind AND ends_at <= p_now AND closed_at IS NULL;

    INSERT INTO ranking_periods (kind, starts_at, ends_at)
    VALUES (p_kind, v_start, v_end)
    ON CONFLICT (kind, starts_at) DO UPDATE SET ends_at = EXCLUDED.ends_at
    RETURNING id INTO v_id;

    RETURN v_id;
END;
$$;


-- ---------------------------------------------------------------------------
-- ランキング再生成
-- ---------------------------------------------------------------------------
-- p_min_facet_posts: 投稿がこの数に満たないファセットはランキングを作らない。
-- docs/01 §3.2 —— 1件しかないファセットで1位を出すと、点数がインフレして無価値化する。

CREATE FUNCTION rebuild_ranking_entries(
    p_period_id        integer,
    p_grain_version_id smallint,
    p_min_facet_posts  integer DEFAULT 5
) RETURNS integer
LANGUAGE plpgsql
AS $$
DECLARE
    v_start timestamptz;
    v_end   timestamptz;
    v_rows  integer;
BEGIN
    SELECT starts_at, ends_at INTO v_start, v_end
      FROM ranking_periods WHERE id = p_period_id;

    IF v_start IS NULL THEN
        RAISE EXCEPTION 'ranking_period % not found', p_period_id;
    END IF;

    DELETE FROM ranking_entries
     WHERE period_id = p_period_id AND grain_version_id = p_grain_version_id;

    WITH scored AS (
        SELECT
            a.spot_id,
            a.bearing_sector,
            p.weather,
            p.timeslot,
            p.season,
            p.id AS post_id,
            t.total_score
        FROM post_spot_assignment a
        JOIN posts p               ON p.id = a.post_id
        JOIN v_post_total_score t  ON t.post_id = a.post_id
                                  AND t.grain_version_id = a.grain_version_id
        WHERE a.grain_version_id = p_grain_version_id
          AND p.status = 'published'
          AND p.posted_at >= v_start
          AND p.posted_at <  v_end
    ),
    ranked AS (
        SELECT
            s.*,
            rank()   OVER w_ordered AS rnk,
            -- ORDER BY を持つウィンドウで count(*) を取ると既定フレーム
            -- (RANGE UNBOUNDED PRECEDING AND CURRENT ROW) の累計になってしまうため、
            -- 件数は ORDER BY を持たない別ウィンドウで数える
            count(*) OVER w_whole   AS facet_n
        FROM scored s
        WINDOW
            w_ordered AS (
                PARTITION BY s.spot_id, s.bearing_sector, s.weather, s.timeslot, s.season
                ORDER BY s.total_score DESC
            ),
            w_whole AS (
                PARTITION BY s.spot_id, s.bearing_sector, s.weather, s.timeslot, s.season
            )
    )
    INSERT INTO ranking_entries (
        period_id, grain_version_id, spot_id, bearing_sector, weather, timeslot, season,
        post_id, rank, facet_post_count, top_percentile, total_score
    )
    SELECT
        p_period_id, p_grain_version_id,
        r.spot_id, r.bearing_sector, r.weather, r.timeslot, r.season,
        r.post_id, r.rnk, r.facet_n,
        round(r.rnk::numeric / r.facet_n, 4),
        r.total_score
    FROM ranked r
    WHERE r.facet_n >= p_min_facet_posts;

    GET DIAGNOSTICS v_rows = ROW_COUNT;
    RETURN v_rows;
END;
$$;

COMMENT ON FUNCTION rebuild_ranking_entries IS
    'ファセット別ランキングを再生成する。冪等（同一 period × grain を DELETE してから INSERT）。';


-- ---------------------------------------------------------------------------
-- 公開ビュー — 表示ポリシー（docs/00 §3【変更禁止】）の実装
-- ---------------------------------------------------------------------------
--   - 生の合計点は出さない
--   - 相対指標のみ（上位◯% / 部門◯位）
--   - 下位の順位は一切出さない → 上位50%に入らなければ NULL
--
-- API はこのビューだけを参照すること。ranking_entries を直接引くと
-- total_score や下位順位が漏れる。

CREATE VIEW v_post_display AS
SELECT
    e.post_id,
    e.period_id,
    s.display_name                              AS spot_name,
    e.bearing_sector,
    e.weather,
    e.timeslot,
    e.season,
    -- 上位50%に入っているときだけ順位を出す
    CASE WHEN e.top_percentile <= 0.5 THEN e.rank END        AS visible_rank,
    CASE WHEN e.top_percentile <= 0.5 THEN e.top_percentile END AS visible_top_percentile,
    e.facet_post_count,
    -- 「◯◯部門1位」バッジ用
    (e.rank = 1)                                AS is_facet_top,
    e.computed_at
FROM ranking_entries e
JOIN spots s ON s.id = e.spot_id;

COMMENT ON VIEW v_post_display IS
    '表示ポリシー準拠の唯一の公開ビュー。生の合計点と下位順位は含めない（docs/00 §3）。';


-- ---------------------------------------------------------------------------
-- 自己ベスト — 「他人との比較より自分の過去ベスト更新」の逃げ道（docs/00 §3）
-- ---------------------------------------------------------------------------
-- 点数そのものは返さず、「自己ベストを更新したか」の真偽値だけを返す。

CREATE VIEW v_user_personal_best AS
SELECT DISTINCT ON (p.author_id, a.grain_version_id)
    p.author_id,
    a.grain_version_id,
    p.id          AS best_post_id,
    t.total_score AS best_total_score,   -- 内部用。APIから返さないこと
    p.posted_at   AS achieved_at
FROM posts p
JOIN post_spot_assignment a ON a.post_id = p.id
JOIN v_post_total_score   t ON t.post_id = a.post_id
                           AND t.grain_version_id = a.grain_version_id
WHERE p.status = 'published'
ORDER BY p.author_id, a.grain_version_id, t.total_score DESC, p.posted_at ASC;
