-- 0014_recalc.sql
-- T-21: 粒度再計算ジョブ（docs/01 §4.3）の永続状態と、希少性②の一括再計算。
--
-- ここまで ②希少性 は calc_rarity_score という「関数」しか無く、**それを実データに
-- 当てる場所がどこにも無かった**。T-16（DBSCAN昇格）が投稿の紐付けを張り替えるので、
-- 当てる場所が無いままだと post_rarity_scores が実態とずれたまま配信される。
--
-- 再計算は「途中で落ちる前提」（docs/01 §4.3）。カーソルとフェーズを永続化して、
-- 同じコマンドを再実行すれば続きから進むようにする。


-- ---------------------------------------------------------------------------
-- grain_recalc_runs — 再計算の進捗
-- ---------------------------------------------------------------------------

CREATE TYPE recalc_phase AS ENUM (
    'assign',   -- 全投稿にスポット解決フローを当てる（docs/01 §4.3 手順2）
    'promote',  -- DBSCAN昇格（同 手順4）
    'lineage',  -- 系譜の確定。split はここでしか判定できない（docs/01 §8.3）
    'rarity',   -- ファセット統計の再構築 + ②の再計算（同 手順3・5）
    'ranking',  -- ランキング再生成（同 手順6）
    'done'
);

CREATE TABLE grain_recalc_runs (
    id                     bigint       PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    grain_version_id       smallint     NOT NULL REFERENCES spot_grain_versions (id) ON DELETE CASCADE,
    -- 当時の POI 抽出を固定する。指定しないと抽出更新で結果が変わる（docs/06 §4.2）
    poi_extract_version_id smallint     REFERENCES poi_extract_versions (id),

    phase                  recalc_phase NOT NULL DEFAULT 'assign',
    -- assign フェーズの進捗。posts.id の昇順でここまで処理済み
    cursor_post_id         uuid,
    processed_count        integer      NOT NULL DEFAULT 0,

    started_at             timestamptz  NOT NULL DEFAULT now(),
    updated_at             timestamptz  NOT NULL DEFAULT now(),
    completed_at           timestamptz,
    last_error             text
);

-- 同じ粒度バージョンに未完了のランは1本まで。多重起動で二重に走らせない。
CREATE UNIQUE INDEX grain_recalc_open_uix
    ON grain_recalc_runs (grain_version_id) WHERE completed_at IS NULL;

COMMENT ON TABLE grain_recalc_runs IS
    '粒度再計算の進捗（docs/01 §4.3）。冪等性と再開可能性のための状態。';


-- 再計算は draft / shadow でしか走らせない。
-- 0013 が「配信中のスポットを動かさない」をガードしているが、そもそも配信中の
-- バージョンに対して再計算を始めさせない方が事故が浅い。
CREATE FUNCTION recalc_target_guard() RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE v_status grain_status;
BEGIN
    SELECT status INTO v_status FROM spot_grain_versions WHERE id = NEW.grain_version_id;
    IF v_status NOT IN ('draft', 'shadow') THEN
        RAISE EXCEPTION
            '再計算は draft / shadow に対してのみ実行できる（対象の status = %）。'
            '配信中のバージョンを作り直すのではなく、新しいバージョンを立てて'
            'Blue-Green で差し替えること（docs/01 §4.2）', v_status;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER grain_recalc_target_trg
    BEFORE INSERT ON grain_recalc_runs
    FOR EACH ROW EXECUTE FUNCTION recalc_target_guard();


-- ---------------------------------------------------------------------------
-- 系譜の確定 — split の判定（docs/01 §8.3 / T-16 からの持ち越し）
-- ---------------------------------------------------------------------------
-- 「1つの親が2つに割れたか」は投稿の分布を見ないと決まらないので、投稿1件ごとの
-- 解決フローからは判断できない。全件処理が終わったこの時点で初めて確定する。
--
-- 親（比較元バージョンのスポット）ごとに、その投稿が新バージョンでどの identity に
-- 散ったかを数える。2つ以上に散っていれば split。

CREATE FUNCTION finalize_spot_lineage(
    p_grain_version_id     smallint,
    p_reference_grain_id   smallint
) RETURNS integer
LANGUAGE plpgsql
AS $$
DECLARE v_rows integer;
BEGIN
    WITH flow AS (
        SELECT
            old_s.identity_id AS parent_identity,
            new_s.identity_id AS child_identity,
            count(*)          AS moved
        FROM post_spot_assignment old_a
        JOIN spots old_s ON old_s.id = old_a.spot_id
        JOIN post_spot_assignment new_a ON new_a.post_id = old_a.post_id
                                       AND new_a.grain_version_id = p_grain_version_id
        JOIN spots new_s ON new_s.id = new_a.spot_id
        WHERE old_a.grain_version_id = p_reference_grain_id
        GROUP BY 1, 2
    ),
    totals AS (
        SELECT parent_identity,
               sum(moved)  AS parent_total,
               count(*)    AS child_count
        FROM flow GROUP BY 1
    ),
    split AS (
        SELECT f.*, t.parent_total
        FROM flow f JOIN totals t USING (parent_identity)
        WHERE t.child_count > 1          -- 1つの親が複数の子に散った = 分割
    )
    INSERT INTO spot_lineage (
        op, from_grain_version_id, to_grain_version_id,
        parent_identity_id, child_identity_id, post_share, moved_post_count
    )
    SELECT 'split', p_reference_grain_id, p_grain_version_id,
           s.parent_identity, s.child_identity,
           round((s.moved::numeric / s.parent_total), 4), s.moved
    FROM split s
    ON CONFLICT (to_grain_version_id, parent_identity_id, child_identity_id)
    DO UPDATE SET
        op               = 'split',
        post_share       = EXCLUDED.post_share,
        moved_post_count = EXCLUDED.moved_post_count;

    GET DIAGNOSTICS v_rows = ROW_COUNT;
    RETURN v_rows;
END;
$$;

COMMENT ON FUNCTION finalize_spot_lineage IS
    '全件処理後に split を確定する。投稿の分布を見ないと分割は判定できない（docs/01 §8.3）。';


-- ---------------------------------------------------------------------------
-- ②希少性の一括再計算（docs/01 §4.3 手順3・5）
-- ---------------------------------------------------------------------------
-- ファセット統計を作り直しながら、投稿を撮影時刻順に1件ずつ通す。
--
-- **順番に意味がある。** 「初」判定は record_facet_post の upsert が排他制御で、
-- 24時間ルール（docs/01 §3.3）は spot_facet_stats.first_post_id を読む
-- （0012 の first_bonus_eligibility）。集合演算で一度に出すと、どちらも壊れる。
--
-- サーバー側のループにしてあるのは、1件ずつクライアントと往復すると
-- 100万件で現実的な時間に終わらないため。

CREATE FUNCTION recompute_rarity_for_grain(
    p_grain_version_id smallint,
    p_ruleset_id       smallint DEFAULT NULL
) RETURNS integer
LANGUAGE plpgsql
AS $$
DECLARE
    v_ruleset_id     smallint;
    v_weights        jsonb;
    v_trust_weights  jsonb;
    r                RECORD;
    v_was_first      boolean;
    v_penalty        real;
    v_breakdown      jsonb;
    v_count          integer := 0;
BEGIN
    SELECT COALESCE(p_ruleset_id, (SELECT id FROM scoring_rulesets WHERE is_active))
      INTO v_ruleset_id;
    IF v_ruleset_id IS NULL THEN
        RAISE EXCEPTION 'active な scoring_ruleset が無い';
    END IF;

    SELECT weights INTO v_weights FROM scoring_rulesets WHERE id = v_ruleset_id;
    SELECT weights INTO v_trust_weights FROM trust_rulesets WHERE is_active;

    -- 作り直す。増分更新にすると、張り替えで居なくなった投稿の分が残る。
    DELETE FROM spot_facet_stats WHERE grain_version_id = p_grain_version_id;
    DELETE FROM post_rarity_scores WHERE grain_version_id = p_grain_version_id;

    FOR r IN
        SELECT
            p.id AS post_id, a.spot_id, a.bearing_sector,
            p.weather, p.timeslot, p.season, p.captured_at,
            -- そのスポットで自分より前に撮られた投稿の数（自分を含まない）
            (row_number() OVER w - 1)::int AS prior_count,
            -- 直前の投稿からの日数。NULL = そのスポットの初投稿
            EXTRACT(day FROM p.captured_at - lag(p.captured_at) OVER w)::int AS days_since_prev
        FROM post_spot_assignment a
        JOIN posts p ON p.id = a.post_id
        WHERE a.grain_version_id = p_grain_version_id
          AND p.location IS NOT NULL
        WINDOW w AS (PARTITION BY a.spot_id ORDER BY p.captured_at, p.id)
        ORDER BY p.captured_at, p.id
    LOOP
        -- 「初」の判定は 0012 の関数に集約されている。true を組み立てない。
        v_was_first := record_facet_post(
            p_grain_version_id, r.spot_id, r.bearing_sector,
            r.weather, r.timeslot, r.season,
            r.post_id, r.captured_at,
            is_first_bonus_eligible(r.post_id, p_grain_version_id)
        );

        -- 信頼度の帯域を減衰係数に写す（docs/04 §6 SEC-TRUST-02）。
        -- 未判定なら減衰なし。ここで 0 に倒すと、trust の計算が未実装な間
        -- 全投稿の②が消える。
        SELECT COALESCE(trust_penalty_mult(v_trust_weights, t.band), 1.0)
          INTO v_penalty
          FROM post_trust_scores t WHERE t.post_id = r.post_id;
        v_penalty := COALESCE(v_penalty, 1.0);

        v_breakdown := calc_rarity_score(
            v_weights, r.prior_count, v_was_first, r.days_since_prev, v_penalty
        );

        INSERT INTO post_rarity_scores (
            post_id, grain_version_id, ruleset_id, rarity_score, breakdown
        ) VALUES (
            r.post_id, p_grain_version_id, v_ruleset_id,
            (v_breakdown ->> 'rarity_score')::numeric, v_breakdown
        )
        ON CONFLICT (post_id, grain_version_id) DO UPDATE SET
            ruleset_id   = EXCLUDED.ruleset_id,
            rarity_score = EXCLUDED.rarity_score,
            breakdown    = EXCLUDED.breakdown,
            computed_at  = now();

        v_count := v_count + 1;
    END LOOP;

    RETURN v_count;
END;
$$;

COMMENT ON FUNCTION recompute_rarity_for_grain IS
    '②希少性とファセット統計を作り直す。撮影時刻順の逐次処理（「初」判定と24時間ルールが順序に依存するため）。';


-- ---------------------------------------------------------------------------
-- v_recalc_progress — 走っている再計算の状態
-- ---------------------------------------------------------------------------

CREATE VIEW v_recalc_progress AS
SELECT
    r.id                AS run_id,
    g.code              AS grain_code,
    g.status            AS grain_status,
    r.phase,
    r.processed_count,
    (SELECT count(*) FROM posts p WHERE p.location IS NOT NULL) AS total_posts,
    r.started_at,
    r.updated_at,
    r.completed_at,
    r.last_error
FROM grain_recalc_runs r
JOIN spot_grain_versions g ON g.id = r.grain_version_id;
