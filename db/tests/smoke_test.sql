-- smoke_test.sql
-- スキーマと関数の振る舞いを検証する。CI で 0001〜0007 を流した直後に実行する想定。
--   psql -v ON_ERROR_STOP=1 -f db/tests/smoke_test.sql
-- すべてのアサーションが通れば最後に "ALL SMOKE TESTS PASSED" が出る。

\set ON_ERROR_STOP on
BEGIN;

CREATE OR REPLACE FUNCTION assert_eq(p_actual anyelement, p_expected anyelement, p_label text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    IF p_actual IS DISTINCT FROM p_expected THEN
        RAISE EXCEPTION 'ASSERT FAILED [%]: got % / want %', p_label, p_actual, p_expected;
    END IF;
    RAISE NOTICE '  ok  %', p_label;
END;
$$;

CREATE OR REPLACE FUNCTION assert_true(p_cond boolean, p_label text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    IF p_cond IS NOT TRUE THEN
        RAISE EXCEPTION 'ASSERT FAILED [%]: expected true, got %', p_label, p_cond;
    END IF;
    RAISE NOTICE '  ok  %', p_label;
END;
$$;


-- ===========================================================================
\echo '== 1. 粒度バージョンの一意制約 =='
-- ===========================================================================
DO $$
DECLARE v_ok boolean := false;
BEGIN
    BEGIN
        INSERT INTO spot_grain_versions (
            code, status, h3_resolution, snap_radius_m, poi_match_radius_m,
            bearing_sector_count, dbscan_eps_m, dbscan_min_points, dbscan_min_users,
            gps_accuracy_reject_m
        ) VALUES ('g-dup-active', 'active', 9, 120, 150, 8, 80, 5, 3, 100);
    EXCEPTION WHEN unique_violation THEN
        v_ok := true;
    END;
    PERFORM assert_true(v_ok, 'active な粒度バージョンは同時に1本しか作れない');
END;
$$;


-- ===========================================================================
\echo '== 2. テストデータ投入 =='
-- ===========================================================================
CREATE TEMP TABLE t_ids (k text PRIMARY KEY, v uuid);
CREATE TEMP TABLE t_grain (k text PRIMARY KEY, v smallint);

INSERT INTO t_grain SELECT 'grain', id FROM spot_grain_versions WHERE status = 'active';

INSERT INTO users (handle, display_name)
SELECT 'user' || i, 'テストユーザー' || i FROM generate_series(1, 8) i;

INSERT INTO t_ids
SELECT 'spot_a', gen_random_uuid();

-- 富士山周辺を想定したダミー座標（H3インデックスは本来アプリ層で計算する）。
-- スポットは粒度バージョンごとの「実体」なので、先に永続ID（spot_identity）を発行する（T-01）。
INSERT INTO spot_identity (slug, canonical_name, name_source, source_code, representative_point)
VALUES ('tenbodai-a', '◯◯展望台', 'poi', 'azure_maps',
        ST_SetSRID(ST_MakePoint(138.7274, 35.3606), 4326)::geography);

INSERT INTO t_ids
SELECT 'identity_a', id FROM spot_identity WHERE slug = 'tenbodai-a';

INSERT INTO spots (id, identity_id, grain_version_id, kind, h3_index, centroid,
                   display_name, name_source, poi_source, source_code, poi_external_id)
SELECT (SELECT v FROM t_ids WHERE k = 'spot_a'),
       (SELECT v FROM t_ids WHERE k = 'identity_a'),
       (SELECT v FROM t_grain WHERE k = 'grain'),
       'poi', 617700169958293503,
       ST_SetSRID(ST_MakePoint(138.7274, 35.3606), 4326)::geography,
       '◯◯展望台', 'poi', 'azure_maps', 'azure_maps', 'poi-test-0001';

-- kind='poi' なのに出自が無いスポットは作れない
DO $$
DECLARE v_ok boolean := false;
BEGIN
    BEGIN
        INSERT INTO spots (identity_id, grain_version_id, kind, h3_index, centroid)
        VALUES ((SELECT v FROM t_ids WHERE k = 'identity_a'),
                (SELECT v FROM t_grain WHERE k = 'grain'), 'poi', 617700169958293504,
                ST_SetSRID(ST_MakePoint(138.72, 35.36), 4326)::geography);
    EXCEPTION WHEN check_violation THEN
        v_ok := true;
    END;
    PERFORM assert_true(v_ok, 'POIスポットは出自（provider + external_id）なしには作れない');
END;
$$;


-- ===========================================================================
\echo '== 3. record_facet_post — 「初」判定の排他 =='
-- ===========================================================================
DO $$
DECLARE
    v_grain  smallint := (SELECT v FROM t_grain WHERE k = 'grain');
    v_spot   uuid     := (SELECT v FROM t_ids   WHERE k = 'spot_a');
    v_author uuid     := (SELECT id FROM users WHERE handle = 'user1');
    v_p1     uuid;
    v_p2     uuid;
    v_p3     uuid;
    v_first  boolean;
BEGIN
    INSERT INTO posts (author_id, status, captured_at, weather, timeslot, season)
    VALUES (v_author, 'published', now(), 'snow', 'dawn', 'winter') RETURNING id INTO v_p1;

    -- 1件目 eligible → 初
    v_first := record_facet_post(v_grain, v_spot, 0::smallint, 'snow'::weather_kind, 'dawn'::timeslot_kind, 'winter'::season_kind, v_p1, now(), true);
    PERFORM assert_true(v_first, '同一ファセットの1件目は「初」になる');

    -- 2件目 eligible → 初ではない
    INSERT INTO posts (author_id, status, captured_at, weather, timeslot, season)
    VALUES (v_author, 'published', now(), 'snow', 'dawn', 'winter') RETURNING id INTO v_p2;
    v_first := record_facet_post(v_grain, v_spot, 0::smallint, 'snow'::weather_kind, 'dawn'::timeslot_kind, 'winter'::season_kind, v_p2, now(), true);
    PERFORM assert_eq(v_first, false, '同一ファセットの2件目は「初」にならない');

    PERFORM assert_eq(
        (SELECT post_count FROM spot_facet_stats
          WHERE grain_version_id = v_grain AND spot_id = v_spot AND bearing_sector = 0),
        2, 'ファセット統計の件数が積み上がる');

    -- 方位が違えば別ファセット → また「初」が出る（これが「1位の椅子を大量に用意する」の実体）
    INSERT INTO posts (author_id, status, captured_at, weather, timeslot, season)
    VALUES (v_author, 'published', now(), 'snow', 'dawn', 'winter') RETURNING id INTO v_p3;
    v_first := record_facet_post(v_grain, v_spot, 4::smallint, 'snow'::weather_kind, 'dawn'::timeslot_kind, 'winter'::season_kind, v_p3, now(), true);
    PERFORM assert_true(v_first, '方位セクターが違えば別ファセットとして「初」になる');
END;
$$;


-- ===========================================================================
\echo '== 4. record_facet_post — 不明バケットには「初」を出さない =='
-- ===========================================================================
DO $$
DECLARE
    v_grain  smallint := (SELECT v FROM t_grain WHERE k = 'grain');
    v_spot   uuid     := (SELECT v FROM t_ids   WHERE k = 'spot_a');
    v_author uuid     := (SELECT id FROM users WHERE handle = 'user2');
    v_p1 uuid; v_p2 uuid;
    v_first boolean;
BEGIN
    -- 方位不明（bearing_sector IS NULL）の投稿を ineligible として記録
    INSERT INTO posts (author_id, status, captured_at, weather, timeslot, season)
    VALUES (v_author, 'published', now(), 'rain', 'noon', 'autumn') RETURNING id INTO v_p1;
    v_first := record_facet_post(v_grain, v_spot, NULL::smallint, 'rain'::weather_kind, 'noon'::timeslot_kind, 'autumn'::season_kind, v_p1, now(), false);
    PERFORM assert_eq(v_first, false, '方位不明の投稿には「初」を出さない');

    PERFORM assert_eq(
        (SELECT first_post_id FROM spot_facet_stats
          WHERE grain_version_id = v_grain AND spot_id = v_spot
            AND bearing_sector IS NULL AND weather = 'rain'),
        NULL::uuid, 'ineligible な投稿は初回の座を埋めない');

    -- 後から eligible な投稿が来たら、その投稿が初回の座を取る
    INSERT INTO posts (author_id, status, captured_at, weather, timeslot, season)
    VALUES (v_author, 'published', now(), 'rain', 'noon', 'autumn') RETURNING id INTO v_p2;
    v_first := record_facet_post(v_grain, v_spot, NULL::smallint, 'rain'::weather_kind, 'noon'::timeslot_kind, 'autumn'::season_kind, v_p2, now(), true);
    PERFORM assert_true(v_first, 'ineligible の後に来た eligible な投稿が「初」を取れる');
END;
$$;


-- ===========================================================================
\echo '== 5. calc_rarity_score — 対数逓減・初回・復活・上限 =='
-- ===========================================================================
DO $$
DECLARE
    w jsonb := (SELECT weights FROM scoring_rulesets WHERE is_active);
    r jsonb;
BEGIN
    -- 未投稿のスポット: base が最大 18.0
    r := calc_rarity_score(w, 0, false, NULL);
    PERFORM assert_eq((r ->> 'base')::numeric, 18.00, '累計0件のスポットは base が最大');

    -- 累計が n_ref に達すると base はほぼ 0
    r := calc_rarity_score(w, 500, false, NULL);
    PERFORM assert_true((r ->> 'base')::numeric < 0.05, '累計500件で base はほぼ0まで逓減する');

    -- 逓減は単調
    PERFORM assert_true(
        (calc_rarity_score(w, 10,  false, NULL) ->> 'base')::numeric
        > (calc_rarity_score(w, 100, false, NULL) ->> 'base')::numeric,
        'base は投稿数に対して単調減少する');

    -- 初回ボーナス
    r := calc_rarity_score(w, 30, true, NULL);
    PERFORM assert_eq((r ->> 'first_combination')::numeric, 8.00, '初の組み合わせで +8');

    -- 復活ボーナス
    r := calc_rarity_score(w, 30, false, 45);
    PERFORM assert_eq((r ->> 'revival')::numeric, 4.00, '直近30日投稿ゼロで復活ボーナス +4');
    r := calc_rarity_score(w, 30, false, 10);
    PERFORM assert_eq((r ->> 'revival')::numeric, 0.00, '30日未満なら復活ボーナスなし');

    -- 上限30
    r := calc_rarity_score(w, 0, true, 90);
    PERFORM assert_eq((r ->> 'rarity_score')::numeric, 30.00, '合計は30点で頭打ちになる');

    -- 不正チェック失敗時の減衰
    r := calc_rarity_score(w, 0, true, 90, 0.5);
    PERFORM assert_eq((r ->> 'rarity_score')::numeric, 15.00, '位置偽装疑いは②を50%に減衰させる');

    -- 実際に post_rarity_scores へ入れられること（CHECK 制約の確認）
    INSERT INTO post_rarity_scores (post_id, grain_version_id, ruleset_id, rarity_score, breakdown)
    SELECT p.id,
           (SELECT v FROM t_grain WHERE k = 'grain'),
           (SELECT id FROM scoring_rulesets WHERE is_active),
           (calc_rarity_score(w, 0, true, NULL) ->> 'rarity_score')::numeric,
           calc_rarity_score(w, 0, true, NULL)
      FROM posts p
     LIMIT 1;
    RAISE NOTICE '  ok  post_rarity_scores への保存（CHECK 制約通過）';
END;
$$;


-- ===========================================================================
\echo '== 6. calc_community_score — ベイズ縮約 =='
-- ===========================================================================
DO $$
DECLARE w jsonb := (SELECT weights FROM scoring_rulesets WHERE is_active);
BEGIN
    -- 票ゼロは中央値10点。減点にしないのは表示ポリシーとの整合（docs/00 §3）
    PERFORM assert_eq(calc_community_score(w, 1500.0, 0), 10.00, '票ゼロは中央値10点');

    -- 高Eloでも票が少なければ中央に引き戻される
    PERFORM assert_true(
        calc_community_score(w, 1900.0, 2) < calc_community_score(w, 1900.0, 200),
        '同じEloでも票数が少ないほど中央へ縮約される');

    -- 票が十分あれば上限に近づく
    PERFORM assert_true(
        calc_community_score(w, 2100.0, 500) > 18.0,
        '高Elo・多票なら上限20に近づく');

    -- 低Eloでも0にはならず、下限側でも過度に叩かれない
    PERFORM assert_true(
        calc_community_score(w, 1100.0, 500) >= 0.0,
        '低Eloでも負の値にはならない');
END;
$$;


-- ===========================================================================
\echo '== 7. apply_vote — Elo のオンライン更新と重複投票の拒否 =='
-- ===========================================================================
DO $$
DECLARE
    v_a uuid; v_b uuid;
    v_voter uuid := (SELECT id FROM users WHERE handle = 'user3');
    v_elo_a numeric; v_elo_b numeric;
    v_ok boolean := false;
BEGIN
    INSERT INTO posts (author_id, status, captured_at)
    VALUES ((SELECT id FROM users WHERE handle = 'user4'), 'published', now()) RETURNING id INTO v_a;
    INSERT INTO posts (author_id, status, captured_at)
    VALUES ((SELECT id FROM users WHERE handle = 'user5'), 'published', now()) RETURNING id INTO v_b;

    INSERT INTO post_community_scores (post_id, finalize_at)
    VALUES (v_a, now() + interval '24 hours'), (v_b, now() + interval '24 hours');

    PERFORM apply_vote(v_voter, v_a, v_b, 1.0);

    SELECT elo_rating INTO v_elo_a FROM post_community_scores WHERE post_id = v_a;
    SELECT elo_rating INTO v_elo_b FROM post_community_scores WHERE post_id = v_b;

    PERFORM assert_true(v_elo_a > 1500, '勝者のEloが上がる');
    PERFORM assert_true(v_elo_b < 1500, '敗者のEloが下がる');
    PERFORM assert_eq(
        (SELECT vote_count FROM post_community_scores WHERE post_id = v_a), 1,
        '票数がカウントされる');

    -- 同じ人が同じペアに再投票（順序を逆にしても）できない
    BEGIN
        PERFORM apply_vote(v_voter, v_b, v_a, 1.0);
    EXCEPTION WHEN unique_violation THEN
        v_ok := true;
    END;
    PERFORM assert_true(v_ok, '同一ユーザーの同一ペアへの再投票は拒否される');

    -- 別のユーザーなら投票できる
    PERFORM apply_vote((SELECT id FROM users WHERE handle = 'user6'), v_a, v_b, 1.5);
    PERFORM assert_eq(
        (SELECT vote_count FROM post_community_scores WHERE post_id = v_a), 2,
        '別ユーザーの票は加算される');
END;
$$;


-- ===========================================================================
\echo '== 8. ③ の確定スイープ =='
-- ===========================================================================
DO $$
DECLARE v_due int;
BEGIN
    -- 24時間経過したことにする
    UPDATE post_community_scores SET finalize_at = now() - interval '1 minute';

    WITH due AS (
        SELECT post_id FROM post_community_scores
         WHERE finalize_at <= now() AND finalized_at IS NULL
         ORDER BY finalize_at LIMIT 500 FOR UPDATE SKIP LOCKED
    )
    UPDATE post_community_scores s
       SET community_score = calc_community_score(
               (SELECT weights FROM scoring_rulesets WHERE is_active),
               s.elo_rating, s.vote_count),
           finalized_at = now()
      FROM due WHERE s.post_id = due.post_id;

    GET DIAGNOSTICS v_due = ROW_COUNT;
    PERFORM assert_true(v_due > 0, 'スイープが期限到来分を確定させる');
    PERFORM assert_eq(
        (SELECT count(*)::int FROM post_community_scores
          WHERE finalize_at <= now() AND finalized_at IS NULL), 0,
        '確定後は未確定の期限到来行が残らない');
END;
$$;


-- ===========================================================================
\echo '== 9. rebuild_ranking_entries と表示ポリシー =='
-- ===========================================================================
DO $$
DECLARE
    v_grain  smallint := (SELECT v FROM t_grain WHERE k = 'grain');
    v_spot   uuid     := (SELECT v FROM t_ids   WHERE k = 'spot_a');
    v_period integer;
    v_rows   integer;
    v_post   uuid;
    v_ruleset smallint := (SELECT id FROM scoring_rulesets WHERE is_active);
    i        integer;
BEGIN
    -- 同一ファセットに6件（足切り5件を超える）を作る。
    -- 投稿者は3人に散らす。1人の連投ではランキングを成立させない（T-02 / B-03）ため、
    -- 全件を同一ユーザーにするとこのファセットは発見表現へ落ちる。
    FOR i IN 1..6 LOOP
        INSERT INTO posts (author_id, status, captured_at, posted_at, weather, timeslot, season)
        VALUES ((SELECT id FROM users WHERE handle = 'user' || (1 + i % 3)), 'published',
                now(), now(), 'clear', 'golden', 'summer')
        RETURNING id INTO v_post;

        INSERT INTO post_spot_assignment (post_id, grain_version_id, spot_id, h3_index,
                                          bearing_sector, bind_method)
        VALUES (v_post, v_grain, v_spot, 617700169958293503, 2, 'poi');

        -- 点差をつける（① 40..15）
        INSERT INTO post_ai_scores (post_id, model_bundle_version, ai_score)
        VALUES (v_post, 'test-v1', 45 - i * 5);

        INSERT INTO post_rarity_scores (post_id, grain_version_id, ruleset_id, rarity_score)
        VALUES (v_post, v_grain, v_ruleset, 10);

        INSERT INTO post_community_scores (post_id, finalize_at, community_score, finalized_at)
        VALUES (v_post, now(), 10, now());
    END LOOP;

    -- 足切りに掛かる小さいファセット（2件だけ）も作る
    FOR i IN 1..2 LOOP
        INSERT INTO posts (author_id, status, captured_at, posted_at, weather, timeslot, season)
        VALUES ((SELECT id FROM users WHERE handle = 'user8'), 'published',
                now(), now(), 'fog', 'night', 'spring')
        RETURNING id INTO v_post;
        INSERT INTO post_spot_assignment (post_id, grain_version_id, spot_id, h3_index,
                                          bearing_sector, bind_method)
        VALUES (v_post, v_grain, v_spot, 617700169958293503, 6, 'poi');
        INSERT INTO post_ai_scores (post_id, model_bundle_version, ai_score) VALUES (v_post, 'test-v1', 30);
    END LOOP;

    v_period := open_next_ranking_period('weekly');
    v_rows   := rebuild_ranking_entries(v_period, v_grain, 5);

    PERFORM assert_eq(v_rows, 6, '足切り5件以上のファセットだけがランキング化される');

    PERFORM assert_eq(
        (SELECT count(*)::int FROM ranking_entries
          WHERE period_id = v_period AND weather = 'fog'),
        0, '投稿2件しかないファセットは「1位の椅子」を作らない');

    -- 順位が 1..6 で並ぶ
    PERFORM assert_eq(
        (SELECT array_agg(rank ORDER BY rank) FROM ranking_entries WHERE period_id = v_period),
        ARRAY[1,2,3,4,5,6], 'ファセット内で1位から6位まで採番される');

    -- facet_post_count はパーティション全体の件数（累計ではない）
    PERFORM assert_eq(
        (SELECT DISTINCT facet_post_count FROM ranking_entries WHERE period_id = v_period),
        6, 'facet_post_count はファセット全体の件数になる');

    -- 冪等性
    v_rows := rebuild_ranking_entries(v_period, v_grain, 5);
    PERFORM assert_eq(
        (SELECT count(*)::int FROM ranking_entries WHERE period_id = v_period), 6,
        '再実行しても行が重複しない（冪等）');

    -- 表示ポリシー: 上位50%より下は順位を出さない
    PERFORM assert_eq(
        (SELECT count(*)::int FROM v_post_display
          WHERE period_id = v_period AND visible_rank IS NOT NULL),
        3, '下位50%には順位を一切表示しない');

    PERFORM assert_eq(
        (SELECT count(*)::int FROM v_post_display WHERE period_id = v_period AND is_facet_top),
        1, '1位バッジは1件だけ');

    -- 公開ビューに生の合計点の列が存在しないこと
    PERFORM assert_eq(
        (SELECT count(*)::int FROM information_schema.columns
          WHERE table_name = 'v_post_display'
            AND column_name IN ('total_score', 'ai_score', 'rarity_score', 'community_score')),
        0, '公開ビューは生の合計点を一切含まない（docs/00 §3 変更禁止）');

    PERFORM assert_eq(
        (SELECT count(*)::int FROM information_schema.columns
          WHERE table_name = 'v_post_recognition'
            AND column_name IN ('total_score', 'ai_score', 'rarity_score', 'community_score')),
        0, '統合ビューも生の合計点を一切含まない');
END;
$$;


-- ===========================================================================
\echo '== 9b. T-02 フォールバック階段と発見表現 =='
-- ===========================================================================
DO $$
DECLARE
    v_grain  smallint := (SELECT v FROM t_grain WHERE k = 'grain');
    v_spot   uuid     := (SELECT v FROM t_ids   WHERE k = 'spot_a');
    v_period integer  := (SELECT id FROM ranking_periods
                           WHERE kind = 'weekly' ORDER BY starts_at DESC LIMIT 1);
    v_post   uuid;
    i        integer;
    v_rows   integer;
BEGIN
    -- 母数2件の fog ファセットは、どの段まで落ちても成立しない → 発見表現へ
    PERFORM assert_eq(
        (SELECT count(*)::int FROM post_discovery_labels
          WHERE period_id = v_period AND grain_version_id = v_grain),
        2, 'どの段でも成立しないファセットの投稿は発見表現に落ちる');

    PERFORM assert_eq(
        (SELECT DISTINCT kind FROM post_discovery_labels
          WHERE period_id = v_period AND grain_version_id = v_grain),
        'new_scenery'::discovery_kind, '累計投稿の少ないスポットは「新しい景色」として出す');

    -- 完了条件: 順位を出すか発見表現にするかが投稿ごとに一意に決まる
    PERFORM assert_eq(
        (SELECT count(*)::int FROM v_post_recognition
          WHERE period_id = v_period AND grain_version_id = v_grain),
        8, '期間内の全投稿がちょうど1行ずつ統合ビューに出る');

    PERFORM assert_eq(
        (SELECT count(*)::int FROM (
            SELECT post_id FROM v_post_recognition
             WHERE period_id = v_period AND grain_version_id = v_grain
             GROUP BY post_id HAVING count(*) > 1
         ) dup),
        0, '順位と発見表現が同じ投稿に二重に付くことはない');

    -- 1人の連投ではランキングを成立させない（B-03）
    -- 同一ユーザーだけで7件を別ファセットに積んでも、投稿者数の下限3人に届かない
    FOR i IN 1..7 LOOP
        INSERT INTO posts (author_id, status, captured_at, posted_at, weather, timeslot, season)
        VALUES ((SELECT id FROM users WHERE handle = 'user8'), 'published',
                now(), now(), 'rain', 'dusk', 'summer')
        RETURNING id INTO v_post;

        INSERT INTO post_spot_assignment (post_id, grain_version_id, spot_id, h3_index,
                                          bearing_sector, bind_method)
        VALUES (v_post, v_grain, v_spot, 617700169958293503, 3, 'poi');

        INSERT INTO post_ai_scores (post_id, model_bundle_version, ai_score)
        VALUES (v_post, 'test-v1', 20 + i);
    END LOOP;

    v_rows := rebuild_ranking_entries(v_period, v_grain);

    PERFORM assert_eq(
        (SELECT count(*)::int FROM ranking_entries
          WHERE period_id = v_period AND grain_version_id = v_grain AND weather = 'rain'),
        0, '投稿数を満たしても投稿者が1人ならランキングは成立しない');

    PERFORM assert_eq(
        (SELECT count(*)::int FROM post_discovery_labels
          WHERE period_id = v_period AND grain_version_id = v_grain),
        9, '連投で弾かれた投稿も発見表現で受け止める');

    -- 階段の段数が記録され、粗い段に落ちたことが後から分かる
    PERFORM assert_eq(
        (SELECT DISTINCT facet_level FROM ranking_entries
          WHERE period_id = v_period AND grain_version_id = v_grain),
        1::smallint, '最も細かい段で成立したファセットは level=1 で記録される');

    -- 同一投稿に2つの順位を持たせない（T-02 の完了条件を制約で守る）
    DECLARE v_ok boolean := false;
    BEGIN
        BEGIN
            INSERT INTO ranking_entries (
                period_id, grain_version_id, spot_id, spot_identity_id, facet_level,
                post_id, rank, facet_post_count, top_percentile, total_score
            )
            SELECT period_id, grain_version_id, spot_id, spot_identity_id, 3,
                   post_id, 1, 9, 0.1, 50
              FROM ranking_entries
             WHERE period_id = v_period AND grain_version_id = v_grain LIMIT 1;
        EXCEPTION WHEN unique_violation THEN
            v_ok := true;
        END;
        PERFORM assert_true(v_ok, '1投稿に対して順位は1つしか持てない');
    END;
END;
$$;


-- ===========================================================================
\echo '== 10. 粒度バージョンの二重保持 =='
-- ===========================================================================
DO $$
DECLARE
    v_old smallint := (SELECT v FROM t_grain WHERE k = 'grain');
    v_new smallint;
    v_spot_new uuid := gen_random_uuid();
    v_post uuid := (SELECT post_id FROM post_spot_assignment LIMIT 1);
BEGIN
    -- shadow バージョンを立てる（res10 = より細かい粒度）
    INSERT INTO spot_grain_versions (
        code, status, h3_resolution, snap_radius_m, poi_match_radius_m,
        bearing_sector_count, dbscan_eps_m, dbscan_min_points, dbscan_min_users,
        gps_accuracy_reject_m
    ) VALUES ('g2-h3r10-sector8', 'shadow', 10, 60, 150, 8, 50, 5, 3, 100)
    RETURNING id INTO v_new;

    -- 新しい粒度バージョンでも同じ場所は同じ永続IDを引き継ぐ。
    -- これが T-01 の要点で、引き継がないとURLと称号が切れる。
    INSERT INTO spots (id, identity_id, grain_version_id, kind, h3_index, centroid)
    VALUES (v_spot_new, (SELECT v FROM t_ids WHERE k = 'identity_a'),
            v_new, 'h3_cell', 622700169958293503,
            ST_SetSRID(ST_MakePoint(138.7274, 35.3606), 4326)::geography);

    -- 同じ投稿が新旧2つのバージョンに同時に紐づく（不変条件 I-2）
    INSERT INTO post_spot_assignment (post_id, grain_version_id, spot_id, h3_index, bind_method)
    VALUES (v_post, v_new, v_spot_new, 622700169958293503, 'cell');

    PERFORM assert_eq(
        (SELECT count(*)::int FROM post_spot_assignment WHERE post_id = v_post), 2,
        '同一投稿が新旧2つの粒度バージョンに同時に紐づけられる');

    -- 希少性スコアも粒度バージョンごとに別行として共存する（不変条件 I-3）
    INSERT INTO post_rarity_scores (post_id, grain_version_id, ruleset_id, rarity_score)
    VALUES (v_post, v_new, (SELECT id FROM scoring_rulesets WHERE is_active), 25);

    PERFORM assert_eq(
        (SELECT count(*)::int FROM post_rarity_scores WHERE post_id = v_post), 2,
        '希少性スコアが粒度バージョンごとに共存する');

    -- active の差し替え（Blue-Green）がトランザクション内で完結する
    UPDATE spot_grain_versions SET status = 'deprecated', deprecated_at = now() WHERE id = v_old;
    UPDATE spot_grain_versions SET status = 'active',     activated_at  = now() WHERE id = v_new;

    PERFORM assert_eq(
        (SELECT code FROM spot_grain_versions WHERE status = 'active'),
        'g2-h3r10-sector8', 'active ポインタの差し替えだけで粒度を切り替えられる');

    -- 旧バージョンのデータは消えていない → ロールバックはポインタを戻すだけ
    PERFORM assert_true(
        (SELECT count(*) FROM post_spot_assignment WHERE grain_version_id = v_old) > 0,
        '旧バージョンの紐付けは残っており、ロールバック可能');
END;
$$;


-- ===========================================================================
\echo '== 11. 粒度の健全性メトリクス =='
-- ===========================================================================
DO $$
DECLARE v_cnt int;
BEGIN
    SELECT count(*)::int INTO v_cnt FROM v_grain_health;
    PERFORM assert_true(v_cnt >= 2, 'v_grain_health が全バージョンぶん集計される');
END;
$$;


-- ===========================================================================
\echo '== 12. T-01 永続IDは粒度変更をまたいで生き残る =='
-- ===========================================================================
-- ここに到達した時点で、section 10 が active を g1 → g2 に差し替えている。
-- 「粒度を変更しても、スポットのURLと称号履歴が維持される」が T-01 の完了条件。
DO $$
DECLARE
    v_identity uuid := (SELECT v FROM t_ids WHERE k = 'identity_a');
BEGIN
    PERFORM assert_eq(
        (SELECT code FROM spot_grain_versions WHERE status = 'active'),
        'g2-h3r10-sector8', '前提: 粒度は g2 に切り替わっている');

    -- URL
    PERFORM assert_eq(resolve_spot_slug('tenbodai-a'), v_identity,
        '粒度を切り替えてもスポットのURLは同じ identity に解決する');

    -- 称号履歴（旧粒度で取った1位が残っている）
    PERFORM assert_true(
        (SELECT count(*) FROM v_spot_titles WHERE spot_identity_id = v_identity) > 0,
        '粒度を切り替えても過去の称号が残る');

    PERFORM assert_eq(
        (SELECT DISTINCT rank FROM v_spot_titles WHERE spot_identity_id = v_identity),
        1, '称号ビューは1位だけを返す（下位順位を漏らさない）');

    -- スポット詳細ページは新しい粒度の実体を見る
    PERFORM assert_eq(
        (SELECT grain_version_id FROM v_spot_public WHERE identity_id = v_identity),
        (SELECT id FROM spot_grain_versions WHERE status = 'active'),
        'スポット詳細は常にアクティブな粒度の実体を返す');

    PERFORM assert_eq(
        (SELECT display_name FROM v_spot_public WHERE identity_id = v_identity),
        '◯◯展望台', '新しい粒度の実体が未命名でも、永続IDの名前が表示に残る');

    -- 同一粒度に同じ identity の実体は1つだけ
    DECLARE v_ok boolean := false;
    BEGIN
        BEGIN
            INSERT INTO spots (identity_id, grain_version_id, kind, h3_index, centroid)
            VALUES (v_identity, (SELECT id FROM spot_grain_versions WHERE status = 'active'),
                    'h3_cell', 622700169958293999,
                    ST_SetSRID(ST_MakePoint(138.73, 35.36), 4326)::geography);
        EXCEPTION WHEN unique_violation THEN
            v_ok := true;
        END;
        PERFORM assert_true(v_ok, '1つの粒度バージョンに同じ永続IDの実体は1つしか作れない');
    END;
END;
$$;


-- ===========================================================================
\echo '== 13. T-01 改名・統合・系譜 =='
-- ===========================================================================
DO $$
DECLARE
    v_identity uuid := (SELECT v FROM t_ids WHERE k = 'identity_a');
    v_grain    smallint := (SELECT id FROM spot_grain_versions WHERE status = 'active');
    v_other    uuid;
    v_spot     uuid;
BEGIN
    -- 改名しても旧名で辿れる
    PERFORM rename_spot_identity(v_identity, '△△パノラマ台', 'user');
    PERFORM assert_eq(
        (SELECT canonical_name FROM spot_identity WHERE id = v_identity),
        '△△パノラマ台', '命名が採用されると表示名が変わる');
    PERFORM assert_true(
        (SELECT count(*) FROM spot_alias
          WHERE identity_id = v_identity AND alias_kind = 'display_name'
            AND alias_value = '◯◯展望台') = 1,
        '旧名は alias に退避され、検索から消えない');

    -- 日本語名は URL に使えないので座標を種にする
    PERFORM assert_true(
        generate_spot_slug('◯◯展望台',
            ST_SetSRID(ST_MakePoint(138.7274, 35.3606), 4326)::geography) ~ '^spot-',
        'ASCIIに落ちない表示名のときは座標由来の slug を作る');

    -- 新しいスポットを親付きで作ると系譜が繋がる
    v_spot := upsert_spot_with_identity(
        v_grain, 'cluster', 622700169958294111,
        ST_SetSRID(ST_MakePoint(138.7280, 35.3610), 4326)::geography,
        'テスト昇格スポット', 'user', 'user', NULL, NULL, 'create');

    SELECT identity_id INTO v_other FROM spots WHERE id = v_spot;
    PERFORM assert_true(v_other IS DISTINCT FROM v_identity,
        '親を指定しなければ新しい永続IDが発行される');
    PERFORM assert_eq(
        (SELECT op FROM spot_lineage WHERE child_identity_id = v_other),
        'create'::spot_lineage_op, '新規スポットは系譜に create として残る');

    -- 統合すると旧URLが統合先に向く（粒度を粗くしたときの挙動）
    PERFORM merge_spot_identity(v_other, v_identity, v_grain);

    PERFORM assert_eq(
        (SELECT status FROM spot_identity WHERE id = v_other),
        'merged'::spot_identity_status, '統合元は merged になる');

    PERFORM assert_eq(
        resolve_spot_slug((SELECT alias_value FROM spot_alias
                            WHERE identity_id = v_identity AND alias_kind = 'slug'
                            ORDER BY id DESC LIMIT 1)),
        v_identity, '統合された側の旧URLは統合先に解決する');

    PERFORM assert_true(
        (SELECT count(*) FROM spot_lineage
          WHERE op = 'merge' AND parent_identity_id = v_other
            AND child_identity_id = v_identity) = 1,
        '統合が系譜に残り、称号の引き継ぎ判断ができる');

    -- 統合先は公開ビューから消える（詳細ページは統合先へ 301 する想定）
    PERFORM assert_eq(
        (SELECT count(*)::int FROM v_spot_public WHERE identity_id = v_other),
        0, '統合済みの永続IDは公開ビューに出ない');

    -- 自分自身への統合は拒否される
    DECLARE v_ok boolean := false;
    BEGIN
        BEGIN
            PERFORM merge_spot_identity(v_identity, v_identity, v_grain);
        EXCEPTION WHEN others THEN
            v_ok := true;
        END;
        PERFORM assert_true(v_ok, '自分自身への統合は拒否される');
    END;
END;
$$;


-- ===========================================================================
\echo '== 14. T-05 POIソースのライセンス条件（ADR-001 / docs/06） =='
-- ===========================================================================
DO $$
DECLARE v_ok boolean := false;
BEGIN
    -- 完了条件その1: 外部ソースのライセンス条件が全て確認済み（NULL が残っていない）
    PERFORM assert_eq(
        (SELECT count(*)::int FROM spot_source
          WHERE is_external
            AND (cache_allowed IS NULL OR redistribution_allowed IS NULL OR terms_url IS NULL)
            AND code <> 'reverse_geocode'),
        0, '外部POIソースのライセンス条件が全て確認済みになっている');

    -- 完了条件その2: MVPで使う外部ソースが1つに絞られている
    PERFORM assert_eq(
        (SELECT code FROM spot_source WHERE adopted AND is_external),
        'osm', 'MVPで採用する外部POIソースは OpenStreetMap ひとつ');

    PERFORM assert_eq(
        (SELECT attribution_text FROM spot_source WHERE code = 'osm'),
        '© OpenStreetMap contributors', 'ODbL の帰属表示文言が用意されている');

    -- 採用ソースは同時に1つだけ。複数混ぜるとソース間の相互制約を踏む。
    BEGIN
        UPDATE spot_source SET adopted = true WHERE code = 'azure_maps';
    EXCEPTION WHEN unique_violation THEN
        v_ok := true;
    END;
    PERFORM assert_true(v_ok, '外部POIソースを2つ同時に採用状態にはできない');

    -- Azure Maps を却下した理由が条件として残っている（再検討時の根拠）
    PERFORM assert_eq(
        (SELECT cache_max_age_days FROM spot_source WHERE code = 'azure_maps'),
        180, 'Azure Maps の保持上限（6か月）が記録されている');

    PERFORM assert_eq(
        (SELECT cache_allowed FROM spot_source WHERE code = 'google_places'),
        false, 'Google Places は place ID 以外を保存できない');

    PERFORM assert_true(
        (SELECT NOT attribution_missing FROM v_poi_license_compliance WHERE source_code = 'osm'),
        '採用ソースに帰属表示の文言が欠けていない');
END;
$$;


-- ===========================================================================
\echo '== 15. spot_poi_cache の保持上限を制約で守る =='
-- ===========================================================================
DO $$
DECLARE
    v_ok    boolean := false;
    v_purged integer;
BEGIN
    -- 規約上限（6か月）を超える保持期限は INSERT できない。
    -- 運用の注意力ではなくスキーマで守る（docs/06 §4.3）。
    BEGIN
        INSERT INTO spot_poi_cache (cache_key, h3_index, radius_m, provider, response,
                                    fetched_at, expires_at)
        VALUES ('over-retention', 617700169958293503, 150, 'azure_maps', '{}'::jsonb,
                now(), now() + interval '400 days');
    EXCEPTION WHEN check_violation THEN
        v_ok := true;
    END;
    PERFORM assert_true(v_ok, '6か月を超える保持期限のキャッシュ行は作れない');

    -- 期限内なら入る
    INSERT INTO spot_poi_cache (cache_key, h3_index, radius_m, provider, response,
                                fetched_at, expires_at)
    VALUES ('within-retention', 617700169958293503, 150, 'azure_maps', '{}'::jsonb,
            now(), now() + interval '30 days');

    -- 期限切れの掃除
    INSERT INTO spot_poi_cache (cache_key, h3_index, radius_m, provider, response,
                                fetched_at, expires_at)
    VALUES ('already-expired', 617700169958293503, 150, 'azure_maps', '{}'::jsonb,
            now() - interval '200 days', now() - interval '20 days');

    PERFORM assert_eq(
        (SELECT expired_cache_rows::int FROM v_poi_license_compliance
          WHERE source_code = 'azure_maps'),
        1, '保持期限を過ぎた行が監視ビューで検出される');

    v_purged := purge_expired_poi_cache();
    PERFORM assert_eq(v_purged, 1, '期限切れの応答だけが削除される');
    PERFORM assert_eq(
        (SELECT count(*)::int FROM spot_poi_cache WHERE cache_key = 'within-retention'),
        1, '期限内の応答は残る');
END;
$$;


-- ===========================================================================
\echo '== 16. find_scenic_poi — 外部API呼び出しの置き換え =='
-- ===========================================================================
DO $$
DECLARE
    v_ver  smallint;
    v_name text;
    v_dir  real;
    v_cnt  integer;
BEGIN
    INSERT INTO poi_extract_versions (source_code, extract_url, extract_date, is_active, note)
    VALUES ('osm', 'https://download.geofabrik.de/asia/japan-latest.osm.pbf',
            DATE '2026-08-01', true, 'テスト用')
    RETURNING id INTO v_ver;

    -- tourism=viewpoint。direction は「その展望台がどちらを向いているか」（docs/06 §3）
    INSERT INTO poi_reference (extract_version_id, osm_type, osm_id, name, name_ja,
                               category, direction_deg, location, tags)
    VALUES (v_ver, 'node', 100001, 'Fuji Viewpoint', '富士見展望台',
            'viewpoint', 250.0,
            ST_SetSRID(ST_MakePoint(138.7274, 35.3606), 4326)::geography,
            '{"tourism":"viewpoint","direction":"250"}'::jsonb);

    -- 名前の無いPOIは候補にしない（「この付近」と変わらないため）
    INSERT INTO poi_reference (extract_version_id, osm_type, osm_id, name, name_ja,
                               category, location)
    VALUES (v_ver, 'node', 100002, NULL, NULL, 'viewpoint',
            ST_SetSRID(ST_MakePoint(138.7275, 35.3607), 4326)::geography);

    SELECT display_name, direction_deg INTO v_name, v_dir
      FROM find_scenic_poi(35.3606, 138.7274, 150);

    PERFORM assert_eq(v_name, '富士見展望台', '半径内の景観POIを日本語名で引ける');
    PERFORM assert_eq(v_dir, 250.0::real, 'viewpoint の向きが方位セクターの事前情報として取れる');

    -- 半径外は引かない
    SELECT count(*)::int INTO v_cnt FROM find_scenic_poi(35.5000, 139.0000, 150);
    PERFORM assert_eq(v_cnt, 0, '半径外のPOIは返さない');

    -- 抽出バージョンを指定すれば、再計算で当時のデータを再現できる（docs/06 §4.2）
    SELECT count(*)::int INTO v_cnt
      FROM find_scenic_poi(35.3606, 138.7274, 150, (v_ver + 1)::smallint);
    PERFORM assert_eq(v_cnt, 0, '抽出バージョンを指定すると、そのバージョンのPOIだけを見る');

    -- 有効な抽出は同時に1つだけ
    DECLARE v_ok boolean := false;
    BEGIN
        BEGIN
            INSERT INTO poi_extract_versions (source_code, extract_url, extract_date, is_active)
            VALUES ('osm', 'https://example.invalid/other.pbf', DATE '2026-09-01', true);
        EXCEPTION WHEN unique_violation THEN
            v_ok := true;
        END;
        PERFORM assert_true(v_ok, '有効な抽出バージョンは同時に1つだけ');
    END;
END;
$$;


-- ===========================================================================
\echo '== 17. SEC-TRUST calc_trust_score — シグナル合成と帯域 =='
-- ===========================================================================
DO $$
DECLARE
    w jsonb := (SELECT weights FROM trust_rulesets WHERE is_active);
    r jsonb;
BEGIN
    -- 何も分からない投稿は基準値 0.6 のまま（判定不能を減点にしない）
    r := calc_trust_score(w, '{}'::jsonb);
    PERFORM assert_eq((r ->> 'trust_score')::numeric, 0.6000, '判定できないシグナルは減点にしない');
    PERFORM assert_eq(r ->> 'band', 'restricted', '基準値だけでは通常帯に届かない');

    -- 素直な投稿は通常帯に入る
    r := calc_trust_score(w, jsonb_build_object(
        'exif_present', true, 'exif_distance_m', 120, 'exif_time_diff_days', 0.5,
        'duplicate_image', false, 'travel_speed_mps', 12.4,
        'device_attestation', 'pass', 'in_app_capture', true,
        'account_age_hours', 900, 'user_trust_ewma', 0.72));
    PERFORM assert_eq(r ->> 'band', 'normal', 'EXIF整合・アプリ内撮影・端末検証通過なら通常帯');

    -- 転載は単独で保留帯まで落とす
    r := calc_trust_score(w, jsonb_build_object('duplicate_image', true));
    PERFORM assert_eq(r ->> 'band', 'held', '転載検出は単独で保留帯まで落とす');

    -- 位置偽装は抑制帯まで落ちる（断定はしない）
    r := calc_trust_score(w, jsonb_build_object(
        'exif_present', true, 'exif_distance_m', 8000, 'exif_time_diff_days', 0.1));
    PERFORM assert_true((r ->> 'trust_score')::numeric < 0.70,
        'EXIF位置が投稿位置と大きくずれると通常帯から落ちる');

    -- 物理的に不可能な移動
    PERFORM assert_true(
        (calc_trust_score(w, jsonb_build_object('travel_speed_mps', 500)) ->> 'trust_score')::numeric
        < (calc_trust_score(w, jsonb_build_object('travel_speed_mps', 50)) ->> 'trust_score')::numeric,
        '前回投稿から物理的に到達不可能な速度は減点される');

    -- 未対応端末は加点も減点もしない（クライアント実装前は全件ここ）
    PERFORM assert_eq(
        (calc_trust_score(w, jsonb_build_object('device_attestation', 'unsupported'))
           -> 'contributions' ->> 'device_attestation')::numeric,
        0::numeric, '端末検証に未対応な端末は加点も減点もしない');

    -- 0〜1 に収まる
    r := calc_trust_score(w, jsonb_build_object(
        'duplicate_image', true, 'device_attestation', 'fail',
        'exif_present', false, 'exif_distance_m', 99999, 'travel_speed_mps', 9999));
    PERFORM assert_true((r ->> 'trust_score')::numeric >= 0.0, '信頼度は負にならない');

    -- 説明可能性: 内訳が復元できること（docs/04 §6 受け入れ条件）
    PERFORM assert_true(
        (r -> 'contributions') ? 'duplicate_image' AND (r ? 'raw'),
        '寄与の内訳と生値が残り、誤検知の申し立てに答えられる');
END;
$$;


-- ===========================================================================
\echo '== 18. SEC-TRUST 帯域を既存の採点関数へ写す =='
-- ===========================================================================
DO $$
DECLARE
    tw jsonb := (SELECT weights FROM trust_rulesets WHERE is_active);
    sw jsonb := (SELECT weights FROM scoring_rulesets WHERE is_active);
BEGIN
    PERFORM assert_eq(trust_penalty_mult(tw, 'normal'::trust_band),     1.0::real, '通常帯は減衰なし');
    PERFORM assert_eq(trust_penalty_mult(tw, 'restricted'::trust_band), 0.5::real, '抑制帯は希少性を半減させる');
    PERFORM assert_eq(trust_penalty_mult(tw, 'held'::trust_band),       0.0::real, '保留帯は希少性を出さない');

    PERFORM assert_true(trust_first_bonus_eligible('normal'::trust_band),
        '「初」ボーナスは通常帯だけ');
    PERFORM assert_eq(trust_first_bonus_eligible('restricted'::trust_band), false,
        '抑制帯では「初」ボーナスを出さない');

    -- 既存の calc_rarity_score にそのまま渡せること（関数シグネチャは変更不要）
    PERFORM assert_eq(
        (calc_rarity_score(sw, 0, true, 90,
                           trust_penalty_mult(tw, 'restricted'::trust_band)) ->> 'rarity_score')::numeric,
        15.00, '抑制帯の減衰が既存の希少性計算にそのまま接続する');
END;
$$;


-- ===========================================================================
\echo '== 19. SEC-PRIV プライバシーゾーンとブロックリスト =='
-- ===========================================================================
DO $$
DECLARE
    v_user uuid := (SELECT id FROM users WHERE handle = 'user1');
    v_home geography := ST_SetSRID(ST_MakePoint(139.7000, 35.6800), 4326)::geography;
    v_far  geography := ST_SetSRID(ST_MakePoint(138.7274, 35.3606), 4326)::geography;
    v_ok   boolean := false;
    r      record;
    v_rows integer;
    v_post uuid;
    i      integer;
BEGIN
    -- ゾーンの制約
    BEGIN
        INSERT INTO user_privacy_zones (user_id, center, radius_m, policy)
        VALUES (v_user, v_home, 100, 'hidden');
    EXCEPTION WHEN check_violation THEN v_ok := true;
    END;
    PERFORM assert_true(v_ok, '半径200m未満のプライバシーゾーンは作れない');

    v_ok := false;
    BEGIN
        INSERT INTO user_privacy_zones (user_id, center, radius_m, policy)
        VALUES (v_user, v_home, 500, 'exact');
    EXCEPTION WHEN check_violation THEN v_ok := true;
    END;
    PERFORM assert_true(v_ok, '劣化しないゾーン（exact）は作れない');

    INSERT INTO user_privacy_zones (user_id, center, radius_m, policy)
    VALUES (v_user, v_home, 500, 'hidden');

    -- ゾーン内なら exact を要求しても hidden まで落ちる
    SELECT * INTO r FROM resolve_location_privacy(v_user, v_home, 'exact');
    PERFORM assert_eq(r.effective_privacy, 'hidden'::location_privacy,
        'ゾーン内の投稿はユーザーが exact を選んでいても強制的に落とす');
    PERFORM assert_eq(r.rejected, false, 'ゾーンは投稿を拒否はしない');

    -- ゾーン外は要求どおり
    SELECT * INTO r FROM resolve_location_privacy(v_user, v_far, 'exact');
    PERFORM assert_eq(r.effective_privacy, 'exact'::location_privacy,
        'ゾーン外の投稿は要求どおりの公開レベルになる');

    -- ユーザーの選択のほうが厳しければそちらを採る
    SELECT * INTO r FROM resolve_location_privacy(v_user, v_far, 'coarse_500m');
    PERFORM assert_eq(r.effective_privacy, 'coarse_500m'::location_privacy,
        'ユーザーの選択のほうが厳しければそちらを採る');

    -- ブロックリスト（保護区）
    INSERT INTO location_blocklist (area, reason, policy, note)
    VALUES (ST_SetSRID(ST_MakePolygon(ST_GeomFromText(
                'LINESTRING(138.72 35.35, 138.74 35.35, 138.74 35.37, 138.72 35.37, 138.72 35.35)'
            )), 4326)::geography,
            'protected_species', 'reject', 'テスト用の保護区');

    SELECT * INTO r FROM resolve_location_privacy(v_user, v_far, 'exact');
    PERFORM assert_eq(r.rejected, true, '保護区への投稿は受け付けない');
    PERFORM assert_eq(r.reason, 'protected_species', '拒否の理由をユーザーに返せる');

    -- 5個上限。ここまでは通る（自宅ゾーンと合わせて5個）
    FOR i IN 1..4 LOOP
        INSERT INTO user_privacy_zones (user_id, center, radius_m, policy)
        VALUES (v_user, ST_SetSRID(ST_MakePoint(139.70 + i * 0.1, 35.68), 4326)::geography,
                300, 'coarse_500m');
    END LOOP;

    v_ok := false;
    BEGIN
        INSERT INTO user_privacy_zones (user_id, center, radius_m, policy)
        VALUES (v_user, ST_SetSRID(ST_MakePoint(140.50, 35.68), 4326)::geography,
                300, 'coarse_500m');
    EXCEPTION WHEN others THEN v_ok := true;
    END;
    PERFORM assert_true(v_ok, 'プライバシーゾーンは1ユーザーあたり5個まで');

    PERFORM assert_eq(
        (SELECT zone_count::int FROM v_user_privacy_zone_summary WHERE user_id = v_user),
        5, '公開してよいのはゾーンの個数まで（座標と半径は返さない）');

    -- 遡及適用: ゾーン登録より前の投稿にも効く
    INSERT INTO posts (author_id, status, captured_at, location, location_privacy)
    VALUES (v_user, 'published', now(), v_home, 'exact') RETURNING id INTO v_post;

    v_rows := reapply_privacy_zones(v_user);
    PERFORM assert_true(v_rows >= 1, 'ゾーン登録前の投稿にも遡及適用される');
    PERFORM assert_eq(
        (SELECT location_privacy FROM posts WHERE id = v_post),
        'hidden'::location_privacy, '自宅で撮った過去の投稿が後から保護される');
END;
$$;


-- ===========================================================================
\echo '== 20. SEC-PRIV 表示座標はビューでのみ返す =='
-- ===========================================================================
DO $$
DECLARE
    v_user uuid := (SELECT id FROM users WHERE handle = 'user2');
    v_post uuid;
    v_cell bigint := 613196570331971583;   -- H3 res8 相当のダミー
    v_center geography := ST_SetSRID(ST_MakePoint(138.7300, 35.3600), 4326)::geography;
    v_ok boolean := false;
    v_cnt integer;
BEGIN
    INSERT INTO h3_cell_centers (h3_index, resolution, center)
    VALUES (v_cell, 8, v_center);

    INSERT INTO posts (author_id, status, captured_at, location, location_privacy, coarse_h3_r8)
    VALUES (v_user, 'published', now(),
            ST_SetSRID(ST_MakePoint(138.7312, 35.3591), 4326)::geography, 'coarse_500m', v_cell)
    RETURNING id INTO v_post;

    PERFORM assert_eq(
        (SELECT ST_AsText(display_location::geometry) FROM v_post_location_public
          WHERE post_id = v_post),
        ST_AsText(v_center::geometry),
        'coarse_500m の表示座標は生座標ではなくセル中心になる');

    -- 同じセルの別投稿は必ず同じ表示座標になる。投稿側に座標を持たせていないので、
    -- ジッターを入れようとしても入れる場所が無い（SEC-PRIV-02）。
    INSERT INTO posts (author_id, status, captured_at, location, location_privacy, coarse_h3_r8)
    VALUES (v_user, 'published', now(),
            ST_SetSRID(ST_MakePoint(138.7320, 35.3585), 4326)::geography, 'coarse_500m', v_cell);

    PERFORM assert_eq(
        (SELECT count(DISTINCT ST_AsText(display_location::geometry))::int
           FROM v_post_location_public v
           JOIN posts p2 ON p2.id = v.post_id
          WHERE p2.coarse_h3_r8 = v_cell),
        1, '同じセルの投稿は必ず同じ表示座標になる（ジッターを入れる場所が無い）');

    -- セル中心が登録されていない投稿は座標を返さない（未計算のまま公開しない）
    v_ok := false;
    BEGIN
        INSERT INTO posts (author_id, status, captured_at, location, location_privacy, coarse_h3_r8)
        VALUES (v_user, 'published', now(), v_center, 'coarse_500m', 999999999999999999);
    EXCEPTION WHEN foreign_key_violation THEN v_ok := true;
    END;
    PERFORM assert_true(v_ok, '中心座標を持たないセルは投稿に設定できない');

    -- hidden は座標もスポット名も返さない
    INSERT INTO posts (author_id, status, captured_at, location, location_privacy)
    VALUES (v_user, 'published', now(), v_center, 'hidden') RETURNING id INTO v_post;

    SELECT count(*)::int INTO v_cnt FROM v_post_location_public
     WHERE post_id = v_post AND (display_location IS NOT NULL OR display_spot_name IS NOT NULL);
    PERFORM assert_eq(v_cnt, 0, 'hidden の投稿は座標もスポット名も返さない');

    -- 生座標を返す列がビューに存在しないこと
    PERFORM assert_eq(
        (SELECT count(*)::int FROM information_schema.columns
          WHERE table_name = 'v_post_location_public'
            AND column_name IN ('location', 'exif_location')),
        0, '公開ビューは投稿の生座標を一切含まない（SEC-PRIV-02）');
END;
$$;


-- ===========================================================================
\echo '== 21. ルールセットは採点された時点で凍結する =='
-- ===========================================================================
DO $$
DECLARE
    v_active smallint := (SELECT id FROM scoring_rulesets WHERE is_active);
    v_before jsonb    := (SELECT weights FROM scoring_rulesets WHERE is_active);
    v_free   smallint;
    v_new    smallint;
    v_ok     boolean := false;
BEGIN
    -- 前提: ここまでの節で active なルールセットを使った採点行が積まれている
    PERFORM assert_true(
        EXISTS (SELECT 1 FROM post_rarity_scores WHERE ruleset_id = v_active),
        '前提: active なルールセットは既に採点に使われている');

    -- まだ採点に使われていない版は自由に編集できる（seed の調整まで止めない）
    INSERT INTO scoring_rulesets (code, is_active, weights, note)
    VALUES ('r-test-draft', false, '{"rarity_first": 8.0}'::jsonb, '検証用')
    RETURNING id INTO v_free;
    UPDATE scoring_rulesets SET weights = weights || '{"probe": 1}'::jsonb WHERE id = v_free;
    PERFORM assert_true(
        (SELECT weights ? 'probe' FROM scoring_rulesets WHERE id = v_free),
        '採点に使われていないルールセットの重みは編集できる');

    -- 1件でも採点に使われたら、以後は書き換えられない
    BEGIN
        UPDATE scoring_rulesets SET weights = weights || '{"probe": 2}'::jsonb WHERE id = v_active;
    EXCEPTION WHEN others THEN
        v_ok := true;
    END;
    PERFORM assert_true(v_ok, '採点に使われた重みは後から書き換えられない');

    -- 重みを変えない UPDATE は通る（active の差し替えと注記の追記に要る）
    UPDATE scoring_rulesets SET note = COALESCE(note, '') || '/検証' WHERE id = v_active;

    -- 変更は新しい版として積む
    v_new := publish_scoring_ruleset('r-test-next', '{"probe": 2}'::jsonb, '検証用の次版');
    PERFORM assert_true(v_new <> v_active, '新しい版は別の行として作られる');
    PERFORM assert_eq(
        (SELECT weights FROM scoring_rulesets WHERE id = v_active), v_before,
        '旧版の重みは採点当時のまま残る');
    PERFORM assert_eq(
        (SELECT id FROM scoring_rulesets WHERE is_active), v_new,
        'active は新しい版に移る');
    PERFORM assert_eq(
        (SELECT (weights ->> 'rarity_first')::numeric FROM scoring_rulesets WHERE id = v_new),
        (v_before ->> 'rarity_first')::numeric,
        '新しい版は現行の重みを引き継ぐ（差分だけ渡せば済む）');
END;
$$;

-- 信頼度ルールセットも同じ理由で凍結する（誤検知の申し立てに答えられなくなるため）
DO $$
DECLARE
    v_active smallint := (SELECT id FROM trust_rulesets WHERE is_active);
    v_post   uuid;
    v_ok     boolean := false;
BEGIN
    -- この重みで1件判定した状態を作る
    INSERT INTO posts (author_id, status, captured_at)
    VALUES ((SELECT id FROM users WHERE handle = 'user3'), 'published', now())
    RETURNING id INTO v_post;
    INSERT INTO post_trust_scores (post_id, ruleset_id, trust_score, signals, band)
    VALUES (v_post, v_active, 0.7, '{}'::jsonb, 'normal');

    BEGIN
        UPDATE trust_rulesets SET weights = weights || '{"probe": 1}'::jsonb WHERE id = v_active;
    EXCEPTION WHEN others THEN
        v_ok := true;
    END;
    PERFORM assert_true(v_ok, '判定に使われた信頼度の重みは後から書き換えられない');
END;
$$;


-- ===========================================================================
\echo '== 22. 自己ベストは点数を返さない =='
-- ===========================================================================
DO $$
BEGIN
    PERFORM assert_eq(
        (SELECT count(*)::int FROM information_schema.columns
          WHERE table_name = 'v_user_personal_best'
            AND column_name IN ('best_total_score', 'total_score')),
        0, '公開する自己ベストのビューは生の合計点を含まない（docs/00 §3 変更禁止）');

    PERFORM assert_true(
        (SELECT count(*) FROM information_schema.columns
          WHERE table_name = 'v_user_personal_best_internal'
            AND column_name = 'best_total_score') = 1,
        '内部用ビューには点数が残る（通知と再計算の判定に要る）');
END;
$$;


-- ===========================================================================
\echo '== 23. 「初」ボーナスの発行条件（docs/01 §3.3） =='
-- ===========================================================================
DO $$
DECLARE
    v_grain  smallint := (SELECT v FROM t_grain WHERE k = 'grain');
    v_author uuid     := (SELECT id FROM users WHERE handle = 'user7');
    v_other  uuid     := (SELECT id FROM users WHERE handle = 'user8');
    v_truleset smallint := (SELECT id FROM trust_rulesets WHERE is_active);
    v_ident  uuid;
    v_spot   uuid;
    v_post   uuid;
    v_bad    uuid;
BEGIN
    -- 他の節の統計と干渉しないよう、専用のスポットを作る
    INSERT INTO spot_identity (slug, canonical_name, name_source, source_code, representative_point)
    VALUES ('first-bonus-test', '検証用展望台', 'poi', 'azure_maps',
            ST_SetSRID(ST_MakePoint(139.0, 35.0), 4326)::geography)
    RETURNING id INTO v_ident;

    INSERT INTO spots (identity_id, grain_version_id, kind, h3_index, centroid,
                       display_name, name_source, poi_source, source_code, poi_external_id)
    VALUES (v_ident, v_grain, 'poi', 617700169958293999,
            ST_SetSRID(ST_MakePoint(139.0, 35.0), 4326)::geography,
            '検証用展望台', 'poi', 'azure_maps', 'azure_maps', 'poi-test-first')
    RETURNING id INTO v_spot;

    -- 全条件を満たす投稿
    INSERT INTO posts (author_id, status, captured_at, weather, timeslot, season, gps_accuracy_m)
    VALUES (v_author, 'published', now(), 'clear', 'golden', 'summer', 20)
    RETURNING id INTO v_post;
    INSERT INTO post_spot_assignment (post_id, grain_version_id, spot_id, h3_index, bearing_sector, bind_method)
    VALUES (v_post, v_grain, v_spot, 617700169958293999, 2, 'poi');
    INSERT INTO post_integrity_checks (post_id, check_kind, passed) VALUES
        (v_post, 'exif_location_match', true),
        (v_post, 'exif_time_match',     true);
    INSERT INTO post_trust_scores (post_id, ruleset_id, trust_score, signals, band)
    VALUES (v_post, v_truleset, 0.8, '{}'::jsonb, 'normal');

    PERFORM assert_true(is_first_bonus_eligible(v_post, v_grain),
        '全条件を満たす投稿には「初」の発行資格がある');

    -- 未割当の投稿には資格が無い（関数が黙って true を返さないこと）
    INSERT INTO posts (author_id, status, captured_at, weather, timeslot, season, gps_accuracy_m)
    VALUES (v_author, 'published', now(), 'clear', 'golden', 'summer', 20)
    RETURNING id INTO v_bad;
    PERFORM assert_eq(is_first_bonus_eligible(v_bad, v_grain), false,
        'スポット未割当の投稿には発行資格が無い');

    -- 方位不明
    UPDATE post_spot_assignment SET bearing_sector = NULL
     WHERE post_id = v_post AND grain_version_id = v_grain;
    PERFORM assert_eq(
        (first_bonus_eligibility(v_post, v_grain) ->> 'has_bearing')::boolean, false,
        '方位が取れていなければ資格を落とす（方位を消せば全方位で初が取れてしまうため）');
    PERFORM assert_eq(is_first_bonus_eligible(v_post, v_grain), false, '方位不明では「初」を出さない');
    UPDATE post_spot_assignment SET bearing_sector = 2
     WHERE post_id = v_post AND grain_version_id = v_grain;

    -- 天候不明
    UPDATE posts SET weather = NULL WHERE id = v_post;
    PERFORM assert_eq(is_first_bonus_eligible(v_post, v_grain), false, '天候不明では「初」を出さない');
    UPDATE posts SET weather = 'clear' WHERE id = v_post;

    -- 測位精度
    UPDATE posts SET gps_accuracy_m = 101 WHERE id = v_post;
    PERFORM assert_eq(is_first_bonus_eligible(v_post, v_grain), false,
        'gps_accuracy_m が 100m を超えたら「初」を出さない');
    UPDATE posts SET gps_accuracy_m = 100 WHERE id = v_post;
    PERFORM assert_true(is_first_bonus_eligible(v_post, v_grain), '境界の 100m ちょうどは通す');

    -- 低信頼フラグ
    UPDATE post_spot_assignment SET low_confidence = true
     WHERE post_id = v_post AND grain_version_id = v_grain;
    PERFORM assert_eq(is_first_bonus_eligible(v_post, v_grain), false,
        'low_confidence な割当には「初」を出さない');
    UPDATE post_spot_assignment SET low_confidence = false
     WHERE post_id = v_post AND grain_version_id = v_grain;

    -- EXIF整合チェックが未実施なら「通過」扱いにしない
    DELETE FROM post_integrity_checks WHERE post_id = v_post AND check_kind = 'exif_time_match';
    PERFORM assert_eq(
        (first_bonus_eligibility(v_post, v_grain) ->> 'integrity_ok')::boolean, false,
        'EXIF整合チェックが未実施なら通過扱いにしない（チェックを走らせない経路が抜け道になる）');
    INSERT INTO post_integrity_checks (post_id, check_kind, passed)
    VALUES (v_post, 'exif_time_match', true);

    -- チェックに落ちていれば当然だめ
    UPDATE post_integrity_checks SET passed = false
     WHERE post_id = v_post AND check_kind = 'exif_location_match';
    PERFORM assert_eq(is_first_bonus_eligible(v_post, v_grain), false,
        'EXIF位置の整合チェックに落ちた投稿には「初」を出さない');
    UPDATE post_integrity_checks SET passed = true
     WHERE post_id = v_post AND check_kind = 'exif_location_match';

    -- 信頼度の帯域（0011 の trust_first_bonus_eligible をここに畳み込んでいる）
    UPDATE post_trust_scores SET band = 'restricted' WHERE post_id = v_post;
    PERFORM assert_eq(is_first_bonus_eligible(v_post, v_grain), false,
        '抑制帯の投稿には「初」を出さない（SEC-TRUST-02）');
    DELETE FROM post_trust_scores WHERE post_id = v_post;
    PERFORM assert_eq(
        (first_bonus_eligibility(v_post, v_grain) ->> 'trust_ok')::boolean, false,
        '信頼度が未判定なら通過扱いにしない（trust の計算を飛ばす経路が抜け道になる）');
    INSERT INTO post_trust_scores (post_id, ruleset_id, trust_score, signals, band)
    VALUES (v_post, v_truleset, 0.8, '{}'::jsonb, 'normal');

    -- 同一ユーザーが同一スポットで直近24時間に「初」を取っている
    PERFORM record_facet_post(v_grain, v_spot, 6::smallint, 'rain'::weather_kind,
                              'noon'::timeslot_kind, 'summer'::season_kind,
                              v_bad, now(), true);
    PERFORM assert_eq(is_first_bonus_eligible(v_post, v_grain), false,
        '同一ユーザーが同一スポットで24時間以内に「初」を取っていたら出さない（方位を変えた連投を塞ぐ）');

    -- 24時間より前なら再び取れる
    UPDATE spot_facet_stats SET first_post_at = now() - interval '25 hours'
     WHERE grain_version_id = v_grain AND spot_id = v_spot AND bearing_sector = 6;
    PERFORM assert_true(is_first_bonus_eligible(v_post, v_grain),
        '24時間を過ぎていれば同じスポットでも再び「初」を取れる');

    -- 他人が「初」を取っていても自分の資格は落ちない
    UPDATE posts SET author_id = v_other WHERE id = v_bad;
    UPDATE spot_facet_stats SET first_post_at = now()
     WHERE grain_version_id = v_grain AND spot_id = v_spot AND bearing_sector = 6;
    PERFORM assert_true(is_first_bonus_eligible(v_post, v_grain),
        '他人が直前に「初」を取っていても自分の資格には影響しない');
END;
$$;


-- ===========================================================================
\echo '== 24. 配信中の粒度バージョンのスポットは動かない（Blue-Green） =='
-- ===========================================================================
-- 再計算ジョブが対象バージョンを取り違えて active を渡しても、配信中の
-- スポットが黙って移動しないこと（CLAUDE.md「既存行は絶対に UPDATE しない」）。
DO $$
DECLARE
    v_active smallint := (SELECT id FROM spot_grain_versions WHERE status = 'active');
    v_draft  smallint;
    v_ident  uuid;
    v_spot   uuid;
    v_again  uuid;
    v_pt     geography := ST_SetSRID(ST_MakePoint(140.0, 36.0), 4326)::geography;
    v_moved  geography := ST_SetSRID(ST_MakePoint(140.5, 36.5), 4326)::geography;
BEGIN
    -- 通常の取り込みは active に対して走る。新規スポットの作成は止めない
    v_spot := upsert_spot_with_identity(
        v_active, 'cluster'::spot_kind, 617700169958294100::bigint, v_pt,
        NULL, NULL, NULL, NULL, NULL, NULL);
    PERFORM assert_true(v_spot IS NOT NULL, 'active な粒度でも新規スポットは作れる（取り込みを止めない）');

    SELECT identity_id INTO v_ident FROM spots WHERE id = v_spot;

    -- 同じ identity で座標違いを渡しても、配信中のスポットは動かない
    v_again := upsert_spot_with_identity(
        v_active, 'cluster'::spot_kind, 617700169958294199::bigint, v_moved,
        NULL, NULL, NULL, NULL, v_ident, 'carry_over'::spot_lineage_op);
    PERFORM assert_eq(v_again, v_spot, '既存実体があれば同じ実体を返す');
    PERFORM assert_true(
        ST_DWithin((SELECT centroid FROM spots WHERE id = v_spot), v_pt, 1.0),
        'active な粒度では既存スポットの重心が動かない');
    PERFORM assert_eq(
        (SELECT h3_index FROM spots WHERE id = v_spot), 617700169958294100::bigint,
        'active な粒度では h3_index も書き換わらない');

    -- 未命名のスポットに名前を付けるのは配信中でも通す（命名フロー docs/01 §1.4）
    PERFORM upsert_spot_with_identity(
        v_active, 'cluster'::spot_kind, 617700169958294100::bigint, v_pt,
        '△△の桜並木', 'user'::spot_name_source, NULL, NULL, v_ident, 'carry_over'::spot_lineage_op);
    PERFORM assert_eq(
        (SELECT display_name FROM spots WHERE id = v_spot), '△△の桜並木',
        '未命名のスポットには配信中でも名前を付けられる');

    -- 既に付いている名前は上書きしない（改名は rename_spot_identity を通す）
    PERFORM upsert_spot_with_identity(
        v_active, 'cluster'::spot_kind, 617700169958294100::bigint, v_pt,
        '別の名前', 'user'::spot_name_source, NULL, NULL, v_ident, 'carry_over'::spot_lineage_op);
    PERFORM assert_eq(
        (SELECT display_name FROM spots WHERE id = v_spot), '△△の桜並木',
        '既に名前があれば上書きしない（改名は alias に退避してから行う）');

    -- 再計算はこれから組み立てるバージョンで行う。そこでは重心の更新が要る
    INSERT INTO spot_grain_versions (
        code, status, h3_resolution, snap_radius_m, poi_match_radius_m,
        bearing_sector_count, dbscan_eps_m, dbscan_min_points, dbscan_min_users,
        gps_accuracy_reject_m
    ) VALUES ('g3-rebuild', 'draft', 9, 120, 150, 8, 80, 5, 3, 100)
    RETURNING id INTO v_draft;

    PERFORM upsert_spot_with_identity(
        v_draft, 'cluster'::spot_kind, 617700169958294100::bigint, v_pt,
        NULL, NULL, NULL, NULL, v_ident, 'carry_over'::spot_lineage_op);
    PERFORM upsert_spot_with_identity(
        v_draft, 'cluster'::spot_kind, 617700169958294199::bigint, v_moved,
        NULL, NULL, NULL, NULL, v_ident, 'carry_over'::spot_lineage_op);
    PERFORM assert_true(
        ST_DWithin((SELECT centroid FROM spots
                     WHERE grain_version_id = v_draft AND identity_id = v_ident), v_moved, 1.0),
        '組み立て中（draft）の粒度では重心を更新できる');

    -- 配信中の実体は draft をいじっても影響を受けない
    PERFORM assert_true(
        ST_DWithin((SELECT centroid FROM spots WHERE id = v_spot), v_pt, 1.0),
        '新バージョンを組み立てても配信中の実体は元のまま');
END;
$$;


\echo ''
\echo 'ALL SMOKE TESTS PASSED'
ROLLBACK;
