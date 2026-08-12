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
\echo '== 14. T-05 の受け皿: 出自とライセンス条件 =='
-- ===========================================================================
DO $$
BEGIN
    PERFORM assert_true(
        (SELECT count(*) FROM spot_source WHERE code = 'azure_maps') = 1,
        'POI提供元が spot_source に登録されている');

    -- T-05 が終わるまでライセンス条件は未確認（NULL）のままであることを明示する。
    -- ここが NULL でなくなったら ADR が書かれたということ。
    PERFORM assert_eq(
        (SELECT cache_allowed FROM spot_source WHERE code = 'azure_maps'),
        NULL::boolean, 'Azure Maps のキャッシュ可否は未確認（T-05 で埋める）');
END;
$$;


\echo ''
\echo 'ALL SMOKE TESTS PASSED'
ROLLBACK;
