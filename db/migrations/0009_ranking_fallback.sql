-- 0009_ranking_fallback.sql
-- T-02: ランキング成立条件のフォールバック階段（設計レビュー B-03）。
--
-- 0005 の rebuild_ranking_entries は「投稿5件未満のファセットは作らない」で止まっており、
-- 作らなかったときに何を見せるかが未定義だった。ファセットを掛け合わせるほど過疎化するのに
-- 受け皿が無い、というのが指摘の中身。
--
-- ここで入れる規則:
--
--   1. 軸を段階的に落とす（方位×天候×時間帯 → 方位×時間帯 → 時間帯 → スポット全体）
--   2. 各段で「投稿数」と「ユニーク投稿者数」の両方を見る（1人の連投で椅子を作らせない）
--   3. どの段も成立しなければ順位を出さず、発見・記録系の表現に切り替える
--
-- 完了条件は「全ファセットについて、順位を出すか発見表現にするかが一意に決まる」。
-- これは ranking_entries と post_discovery_labels の一意制約で型として守る。


-- ---------------------------------------------------------------------------
-- ranking_facet_levels — 階段の定義
-- ---------------------------------------------------------------------------
-- コードに定数で埋めない。閾値は運用しながら必ず動かすため（0004 の scoring_rulesets と同じ理由）。
-- 季節を軸に入れないのは、週次ランキングの期間内では季節がほぼ一定で、
-- 軸として切っても椅子が増えず過疎化だけが進むため。

CREATE TABLE ranking_facet_levels (
    level              smallint PRIMARY KEY,
    code               text     NOT NULL,
    label              text     NOT NULL,   -- UI に出す部門名

    use_bearing        boolean  NOT NULL,
    use_weather        boolean  NOT NULL,
    use_timeslot       boolean  NOT NULL,
    use_season         boolean  NOT NULL,

    min_posts          smallint NOT NULL,
    -- 1人が連投してもランキングが成立しないようにする下限（B-03）
    min_unique_authors smallint NOT NULL,

    CONSTRAINT ranking_facet_level_code_key UNIQUE (code),
    CONSTRAINT ranking_facet_level_ck       CHECK (level >= 1),
    CONSTRAINT ranking_facet_level_min_ck   CHECK (min_posts >= 2 AND min_unique_authors >= 1)
);

COMMENT ON TABLE ranking_facet_levels IS
    'ランキングの粗さの階段。level が小さいほど細かい。上から順に試し、最初に成立した段で順位を出す。';

INSERT INTO ranking_facet_levels
    (level, code, label, use_bearing, use_weather, use_timeslot, use_season, min_posts, min_unique_authors)
VALUES
    (1, 'spot_bearing_weather_timeslot', '方位×天候×時間帯', true,  true,  true,  false, 5, 3),
    (2, 'spot_bearing_timeslot',         '方位×時間帯',      true,  false, true,  false, 5, 3),
    (3, 'spot_timeslot',                 '時間帯',            false, false, true,  false, 5, 3),
    (4, 'spot_all',                      'スポット全体',      false, false, false, false, 5, 3);


-- ---------------------------------------------------------------------------
-- ranking_entries に「どの段で成立したか」を持たせる
-- ---------------------------------------------------------------------------
-- これが無いと、level 2 で軸を落とした結果 weather が NULL になった行と、
-- 天候が本当に不明だった level 1 の行が同じキーに潰れる。

ALTER TABLE ranking_entries ADD COLUMN facet_level smallint REFERENCES ranking_facet_levels (level);

UPDATE ranking_entries SET facet_level = 1 WHERE facet_level IS NULL;
ALTER TABLE ranking_entries ALTER COLUMN facet_level SET NOT NULL;

-- 旧制約は facet_level を含まないので、上記の潰れを防げない。
-- 代わりに「1投稿・1期間・1粒度につき順位は1つ」を制約にする。
-- これが T-02 の完了条件（順位を出すか発見表現にするかが一意に決まる）そのもの。
ALTER TABLE ranking_entries DROP CONSTRAINT ranking_entry_uix;
ALTER TABLE ranking_entries ADD CONSTRAINT ranking_entry_post_uix
    UNIQUE (period_id, grain_version_id, post_id);

CREATE INDEX ranking_entry_level_idx
    ON ranking_entries (period_id, grain_version_id, facet_level, spot_id, rank);


-- ---------------------------------------------------------------------------
-- post_discovery_labels — どの段でも成立しなかった投稿の受け皿
-- ---------------------------------------------------------------------------
-- 「順位が付かなかった」を欠落として扱うと、過疎ファセットの投稿は画面上で無反応になる。
-- 表示ポリシー（docs/00 §3）は下位順位を出すことを禁じているので、
-- ここは順位の代わりに発見・記録として肯定的に見せるための行。

CREATE TYPE discovery_kind AS ENUM (
    'new_scenery',     -- スポット自体がまだ新しい →「新しい景色を発見」
    'first_in_facet',  -- この条件では初の記録    →「雪の◯◯、最初の1枚」
    'few_records'      -- 記録はあるが母数が足りない →「まだ記録の少ない場所」
);

CREATE TABLE post_discovery_labels (
    period_id        integer        NOT NULL REFERENCES ranking_periods (id) ON DELETE CASCADE,
    grain_version_id smallint       NOT NULL REFERENCES spot_grain_versions (id) ON DELETE CASCADE,
    post_id          uuid           NOT NULL REFERENCES posts (id) ON DELETE CASCADE,

    spot_id          uuid           NOT NULL REFERENCES spots (id) ON DELETE CASCADE,
    spot_identity_id uuid           NOT NULL REFERENCES spot_identity (id) ON DELETE CASCADE,
    kind             discovery_kind NOT NULL,
    -- UIの文言組み立て用。順位や合計点は入れない。
    detail           jsonb          NOT NULL DEFAULT '{}'::jsonb,
    computed_at      timestamptz    NOT NULL DEFAULT now(),

    PRIMARY KEY (period_id, grain_version_id, post_id)
);

CREATE INDEX post_discovery_identity_idx
    ON post_discovery_labels (spot_identity_id, period_id DESC);

COMMENT ON TABLE post_discovery_labels IS
    'ランキングが成立しなかった投稿に出す発見表現。減点や下位順位を見せない代替（docs/00 §3 / T-02）。';


-- ---------------------------------------------------------------------------
-- ランキング再生成（階段つき）
-- ---------------------------------------------------------------------------
-- 段ごとに「まだ順位が付いていない投稿」だけを対象にして評価する。
-- 全投稿を対象に段を下げると、上の段で既に順位が付いた投稿を母数に数えてしまい、
-- 「6件で成立」と判定したのに実際は残り2件しか並ばない、という嘘が出る。
--
-- p_min_facet_posts に値を渡すと全段の投稿数下限を上書きする（0005 との後方互換）。
-- NULL なら ranking_facet_levels の段ごとの設定を使う。

CREATE OR REPLACE FUNCTION rebuild_ranking_entries(
    p_period_id        integer,
    p_grain_version_id smallint,
    p_min_facet_posts  integer DEFAULT NULL
) RETURNS integer
LANGUAGE plpgsql
AS $$
--
-- 「まだ順位が付いていない投稿」の判定には ranking_entries そのものを使う。
-- 一時テーブルに退避すると、同一セッションで2回呼んだときに plpgsql のプランキャッシュが
-- 消えた一時テーブルを掴んだままになる。段ごとに文が分かれていれば、
-- 前の段の INSERT は次の段の文から見えるので退避先は要らない。

DECLARE
    v_start     timestamptz;
    v_end       timestamptz;
    v_rows      integer := 0;
    v_n         integer;
    v_lv        RECORD;
    v_new_spot_max integer;
BEGIN
    SELECT starts_at, ends_at INTO v_start, v_end
      FROM ranking_periods WHERE id = p_period_id;

    IF v_start IS NULL THEN
        RAISE EXCEPTION 'ranking_period % not found', p_period_id;
    END IF;

    -- 「新しい景色」とみなすスポットの累計投稿数の上限
    SELECT COALESCE((weights ->> 'discovery_new_spot_max_posts')::int, 3)
      INTO v_new_spot_max
      FROM scoring_rulesets WHERE is_active;
    v_new_spot_max := COALESCE(v_new_spot_max, 3);

    DELETE FROM ranking_entries
     WHERE period_id = p_period_id AND grain_version_id = p_grain_version_id;
    DELETE FROM post_discovery_labels
     WHERE period_id = p_period_id AND grain_version_id = p_grain_version_id;

    FOR v_lv IN SELECT * FROM ranking_facet_levels ORDER BY level LOOP
        WITH pool AS (
            -- この段の母数。上の段で順位が付いた投稿は既に除かれている。
            SELECT
                a.spot_id,
                s.identity_id  AS spot_identity_id,
                a.bearing_sector,
                p.weather,
                p.timeslot,
                p.season,
                p.id           AS post_id,
                p.author_id,
                t.total_score
            FROM post_spot_assignment a
            JOIN posts p              ON p.id = a.post_id
            JOIN spots s              ON s.id = a.spot_id
            JOIN v_post_total_score t ON t.post_id = a.post_id
                                     AND t.grain_version_id = a.grain_version_id
            WHERE a.grain_version_id = p_grain_version_id
              AND p.status = 'published'
              AND p.posted_at >= v_start
              AND p.posted_at <  v_end
              AND NOT EXISTS (
                    SELECT 1 FROM ranking_entries e
                     WHERE e.period_id        = p_period_id
                       AND e.grain_version_id = p_grain_version_id
                       AND e.post_id          = p.id
              )
        ),
        keyed AS (
            SELECT
                t.*,
                CASE WHEN v_lv.use_bearing  THEN t.bearing_sector END AS f_bearing,
                CASE WHEN v_lv.use_weather  THEN t.weather        END AS f_weather,
                CASE WHEN v_lv.use_timeslot THEN t.timeslot       END AS f_timeslot,
                CASE WHEN v_lv.use_season   THEN t.season         END AS f_season,
                -- NULL（不明バケット）同士を同じファセットとして扱うため、
                -- 結合キーは NULL を含まない文字列に畳んでおく
                concat_ws('|',
                    t.spot_id::text,
                    COALESCE((CASE WHEN v_lv.use_bearing  THEN t.bearing_sector END)::text, '~'),
                    COALESCE((CASE WHEN v_lv.use_weather  THEN t.weather        END)::text, '~'),
                    COALESCE((CASE WHEN v_lv.use_timeslot THEN t.timeslot       END)::text, '~'),
                    COALESCE((CASE WHEN v_lv.use_season   THEN t.season         END)::text, '~')
                ) AS facet_key
            FROM pool t
        ),
        agg AS (
            SELECT facet_key,
                   count(*)                  AS facet_n,
                   count(DISTINCT author_id) AS author_n
            FROM keyed
            GROUP BY facet_key
        ),
        qualified AS (
            SELECT k.*, g.facet_n
            FROM keyed k
            JOIN agg g ON g.facet_key = k.facet_key
            WHERE g.facet_n  >= COALESCE(p_min_facet_posts, v_lv.min_posts)
              AND g.author_n >= v_lv.min_unique_authors
        ),
        ranked AS (
            SELECT q.*,
                   rank() OVER (PARTITION BY q.facet_key ORDER BY q.total_score DESC) AS rnk
            FROM qualified q
        )
        INSERT INTO ranking_entries (
            period_id, grain_version_id, spot_id, spot_identity_id, facet_level,
            bearing_sector, weather, timeslot, season,
            post_id, rank, facet_post_count, top_percentile, total_score
        )
        SELECT
            p_period_id, p_grain_version_id, r.spot_id, r.spot_identity_id, v_lv.level,
            r.f_bearing, r.f_weather, r.f_timeslot, r.f_season,
            r.post_id, r.rnk, r.facet_n,
            round(r.rnk::numeric / r.facet_n, 4),
            r.total_score
        FROM ranked r;

        GET DIAGNOSTICS v_n = ROW_COUNT;
        v_rows := v_rows + v_n;
    END LOOP;

    -- どの段でも成立しなかった投稿 → 発見表現。
    -- ここで拾えなかった投稿が出ると「順位も発見表現も無い投稿」が生まれるため、
    -- 条件は上のループの母数と厳密に同じにしておくこと。
    INSERT INTO post_discovery_labels (
        period_id, grain_version_id, post_id, spot_id, spot_identity_id, kind, detail
    )
    SELECT
        p_period_id, p_grain_version_id, p.id, a.spot_id, s.identity_id,
        CASE
            WHEN s.post_count <= v_new_spot_max THEN 'new_scenery'
            WHEN f.first_post_id = p.id         THEN 'first_in_facet'
            ELSE 'few_records'
        END::discovery_kind,
        jsonb_build_object(
            'spot_post_count', s.post_count,
            'bearing_sector',  a.bearing_sector,
            'weather',         p.weather,
            'timeslot',        p.timeslot,
            'season',          p.season
        )
    FROM post_spot_assignment a
    JOIN posts p ON p.id = a.post_id
    JOIN spots s ON s.id = a.spot_id
    LEFT JOIN spot_facet_stats f
           ON f.grain_version_id = p_grain_version_id
          AND f.spot_id          = a.spot_id
          AND f.bearing_sector IS NOT DISTINCT FROM a.bearing_sector
          AND f.weather        IS NOT DISTINCT FROM p.weather
          AND f.timeslot       IS NOT DISTINCT FROM p.timeslot
          AND f.season         IS NOT DISTINCT FROM p.season
    WHERE a.grain_version_id = p_grain_version_id
      AND p.status = 'published'
      AND p.posted_at >= v_start
      AND p.posted_at <  v_end
      AND NOT EXISTS (
            SELECT 1 FROM ranking_entries e
             WHERE e.period_id        = p_period_id
               AND e.grain_version_id = p_grain_version_id
               AND e.post_id          = p.id
      );

    RETURN v_rows;
END;
$$;

COMMENT ON FUNCTION rebuild_ranking_entries IS
    'ファセット別ランキングを階段付きで再生成する。冪等。成立しなかった投稿は post_discovery_labels に落ちる（T-02）。';


-- ---------------------------------------------------------------------------
-- 公開ビューの更新
-- ---------------------------------------------------------------------------
-- 既存の列名・型・順序は変えない（0005 の契約を壊さない）。末尾に階段の情報を足す。

CREATE OR REPLACE VIEW v_post_display AS
SELECT
    e.post_id,
    e.period_id,
    COALESCE(i.canonical_name, s.display_name)  AS spot_name,
    e.bearing_sector,
    e.weather,
    e.timeslot,
    e.season,
    -- 上位50%に入っているときだけ順位を出す
    CASE WHEN e.top_percentile <= 0.5 THEN e.rank END           AS visible_rank,
    CASE WHEN e.top_percentile <= 0.5 THEN e.top_percentile END AS visible_top_percentile,
    e.facet_post_count,
    -- 「◯◯部門1位」バッジ用
    (e.rank = 1)                                AS is_facet_top,
    e.computed_at,
    -- ここから 0009 で追加
    e.facet_level,
    l.label                                     AS facet_label,
    e.spot_identity_id,
    i.slug                                      AS spot_slug
FROM ranking_entries e
JOIN spots               s ON s.id    = e.spot_id
JOIN spot_identity       i ON i.id    = e.spot_identity_id
JOIN ranking_facet_levels l ON l.level = e.facet_level;

COMMENT ON VIEW v_post_display IS
    '表示ポリシー準拠の公開ビュー。生の合計点と下位順位は含めない（docs/00 §3）。順位が付かない投稿は v_post_recognition 側に出る。';


-- ---------------------------------------------------------------------------
-- v_post_recognition — 「この投稿に何を表示するか」の唯一の答え
-- ---------------------------------------------------------------------------
-- 順位が付いた投稿と発見表現に落ちた投稿を1つに束ねる。
-- API がこれだけを見れば、投稿ごとに必ず1行が返り、分岐が漏れない。
-- （T-02 の完了条件「順位を出すか発見表現にするかが一意に決まる」の確認点）

CREATE VIEW v_post_recognition AS
SELECT
    e.post_id,
    e.period_id,
    e.grain_version_id,
    e.spot_identity_id,
    i.slug                                      AS spot_slug,
    COALESCE(i.canonical_name, s.display_name)  AS spot_name,
    'rank'::text                                AS recognition,
    e.facet_level,
    l.label                                     AS facet_label,
    CASE WHEN e.top_percentile <= 0.5 THEN e.rank END           AS visible_rank,
    CASE WHEN e.top_percentile <= 0.5 THEN e.top_percentile END AS visible_top_percentile,
    e.facet_post_count,
    (e.rank = 1)                                AS is_facet_top,
    NULL::discovery_kind                        AS discovery_kind,
    '{}'::jsonb                                 AS discovery_detail
FROM ranking_entries e
JOIN spots                s ON s.id    = e.spot_id
JOIN spot_identity        i ON i.id    = e.spot_identity_id
JOIN ranking_facet_levels l ON l.level = e.facet_level

UNION ALL

SELECT
    d.post_id,
    d.period_id,
    d.grain_version_id,
    d.spot_identity_id,
    i.slug,
    COALESCE(i.canonical_name, s.display_name),
    'discovery'::text,
    NULL::smallint,
    NULL::text,
    NULL::integer,
    NULL::numeric(5,4),
    NULL::integer,
    false,
    d.kind,
    d.detail
FROM post_discovery_labels d
JOIN spots         s ON s.id = d.spot_id
JOIN spot_identity i ON i.id = d.spot_identity_id;

COMMENT ON VIEW v_post_recognition IS
    '投稿1件につき必ず1行。順位（rank）か発見表現（discovery）のどちらかが返る。APIの分岐漏れを防ぐ（T-02）。';


-- ---------------------------------------------------------------------------
-- 配点ルールセットの追補
-- ---------------------------------------------------------------------------
-- 0007 の ranking_min_facet_posts は ranking_facet_levels.min_posts に移った。
-- 値は残すが、参照するのは rebuild_ranking_entries の引数で明示的に上書きする場合だけ。

UPDATE scoring_rulesets
   SET weights = weights || jsonb_build_object(
           -- 発見表現で「新しい景色」と呼ぶスポットの累計投稿数の上限
           'discovery_new_spot_max_posts', 3
       ),
       note = COALESCE(note, '') ||
              ' / ranking_min_facet_posts は ranking_facet_levels に移設（T-02）'
 WHERE is_active;
