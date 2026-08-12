-- 0006_jobs.sql
-- 定期ジョブ。pg_cron は 'postgres' データベースにのみインストールでき、
-- ジョブ定義もそこに置く必要がある（Azure Database for PostgreSQL フレキシブルサーバー）。
--
-- このファイルは検証環境では実行されない（pg_cron 拡張が必要）。
-- Azure 側では azure.extensions と shared_preload_libraries に pg_cron を追加してから流すこと。

-- ---------------------------------------------------------------------------
-- ③ の確定スイープ（docs/02 §4.1 方式A）
-- ---------------------------------------------------------------------------
-- Durable Functions で投稿1件ごとにオーケストレーションを持つ方式を採らない理由は
-- docs/02 §4.1 を参照。ここでは投稿数に依存しない O(1) のスイープにする。
--
-- Functions のタイマートリガーで実装する場合はこのジョブは不要。
-- どちらか一方だけを有効にすること。

-- SELECT cron.schedule(
--     'finalize-community-scores',
--     '* * * * *',                       -- 毎分
--     $$
--     WITH due AS (
--         SELECT post_id
--           FROM post_community_scores
--          WHERE finalize_at <= now() AND finalized_at IS NULL
--          ORDER BY finalize_at
--          LIMIT 500
--            FOR UPDATE SKIP LOCKED      -- 多重起動しても二重確定しない
--     )
--     UPDATE post_community_scores s
--        SET community_score = calc_community_score(
--                                  (SELECT weights FROM scoring_rulesets WHERE is_active),
--                                  s.elo_rating, s.vote_count),
--            finalized_at    = now()
--       FROM due
--      WHERE s.post_id = due.post_id;
--     $$
-- );

-- ---------------------------------------------------------------------------
-- 週次リセット（docs/02 §4.4）
-- ---------------------------------------------------------------------------
-- 月曜 00:00 JST = 日曜 15:00 UTC。cron は UTC で評価される。

-- SELECT cron.schedule(
--     'weekly-ranking-reset',
--     '0 15 * * 0',
--     $$
--     SELECT rebuild_ranking_entries(
--                open_next_ranking_period('weekly'),
--                (SELECT id FROM spot_grain_versions WHERE status = 'active')
--            );
--     $$
-- );

-- ---------------------------------------------------------------------------
-- ランキングの日次更新（週の途中でも順位を動かす）
-- ---------------------------------------------------------------------------

-- SELECT cron.schedule(
--     'daily-ranking-refresh',
--     '10 19 * * *',                     -- 毎日 04:10 JST
--     $$
--     SELECT rebuild_ranking_entries(
--                (SELECT id FROM ranking_periods
--                  WHERE kind = 'weekly' AND ends_at > now()
--                  ORDER BY starts_at DESC LIMIT 1),
--                (SELECT id FROM spot_grain_versions WHERE status = 'active')
--            );
--     $$
-- );

-- ---------------------------------------------------------------------------
-- 粒度の健全性メトリクス（docs/01 §6 の失敗モード検知）
-- ---------------------------------------------------------------------------
-- 週次でダッシュボードに出す。閾値を割ったら粒度変更を検討する。

CREATE VIEW v_grain_health AS
SELECT
    g.id                                                        AS grain_version_id,
    g.code,
    g.status,
    count(DISTINCT s.id)                                        AS spot_count,
    count(DISTINCT s.id) FILTER (WHERE s.kind = 'h3_cell')      AS provisional_spot_count,
    count(DISTINCT s.id) FILTER (WHERE s.kind = 'poi')          AS poi_spot_count,
    count(DISTINCT s.id) FILTER (WHERE s.kind = 'cluster')      AS cluster_spot_count,
    -- 細かすぎる兆候: 中央値 < 3 / 1件スポット比率 > 60%
    percentile_cont(0.5) WITHIN GROUP (ORDER BY s.post_count)   AS posts_per_spot_p50,
    percentile_cont(0.99) WITHIN GROUP (ORDER BY s.post_count)  AS posts_per_spot_p99,
    avg((s.post_count = 1)::int)::numeric(5,4)                  AS single_post_spot_ratio,
    -- 細かすぎる兆候: 「初」ボーナス発行率 > 25%
    (
        SELECT avg(((r.breakdown ->> 'first_combination')::numeric > 0)::int)::numeric(5,4)
          FROM post_rarity_scores r
         WHERE r.grain_version_id = g.id
    )                                                           AS first_bonus_ratio,
    -- 実際に配信される「椅子」の数
    (
        SELECT count(*)
          FROM spot_facet_stats f
         WHERE f.grain_version_id = g.id AND f.post_count >= 5
    )                                                           AS servable_facet_count
FROM spot_grain_versions g
LEFT JOIN spots s ON s.grain_version_id = g.id
GROUP BY g.id, g.code, g.status;

COMMENT ON VIEW v_grain_health IS
    '粒度の失敗モード検知（docs/01 §6）。posts_per_spot_p50 < 3 または first_bonus_ratio > 0.25 で粒度が細かすぎる。';
