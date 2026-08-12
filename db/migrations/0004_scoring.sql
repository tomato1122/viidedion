-- 0004_scoring.sql
-- 3層スコア（docs/00 §2）。①AI / ②希少性 / ③コミュニティ を別テーブルに分ける。
-- 分ける理由は「確定タイミングが違う」ことと、「再計算の対象範囲が違う」こと。
--
--   ① 粒度バージョンに依存しない。モデルバンドル差し替え時のみ再計算
--   ② 粒度バージョンに依存する。粒度変更のたびに全件再計算（不変条件 I-3）
--   ③ 投票そのものは不変だが、ファセットが変われば相対順位は変わる

-- ---------------------------------------------------------------------------
-- scoring_rulesets — 配点の重み（docs/00 §8「配点の具体的な重み」は未決定のため外出し）
-- ---------------------------------------------------------------------------
-- 重みはモデルバンドルと同じくバージョンを切って差し替える（docs/02 §2.3）。
-- コード中に定数で埋め込むと、変更したときにどの投稿がどの重みで採点されたか追えなくなる。

CREATE TABLE scoring_rulesets (
    id          smallint    PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    code        text        NOT NULL,
    is_active   boolean     NOT NULL DEFAULT false,
    weights     jsonb       NOT NULL,
    note        text,
    created_at  timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT scoring_ruleset_code_key UNIQUE (code)
);

CREATE UNIQUE INDEX scoring_ruleset_active_uix ON scoring_rulesets ((is_active)) WHERE is_active;


-- ---------------------------------------------------------------------------
-- ① AIベース点（0–50 / 投稿直後に即確定）
-- ---------------------------------------------------------------------------

CREATE TABLE post_ai_scores (
    post_id              uuid         NOT NULL REFERENCES posts (id) ON DELETE CASCADE,
    model_bundle_version text         NOT NULL,
    ai_score             numeric(5,2) NOT NULL,
    -- 特徴量の内訳。「なぜこの点数か」をユーザーに説明するために必ず残す
    -- （docs/00 §6「説明可能性が高く『なぜこの点数か』を語れる」）
    -- 例: {"scenicness":21.4,"fractal_d":1.38,"fractal":9.1,"sky":6.2,"elements":5.0,"tech_mult":0.94}
    features             jsonb        NOT NULL DEFAULT '{}'::jsonb,
    computed_at          timestamptz  NOT NULL DEFAULT now(),

    PRIMARY KEY (post_id, model_bundle_version),
    CONSTRAINT ai_score_range_ck CHECK (ai_score >= 0 AND ai_score <= 50)
);


-- ---------------------------------------------------------------------------
-- ② 希少性ボーナス（0–30 / DB計算・AI不使用）
-- ---------------------------------------------------------------------------
-- 粒度バージョンごとに1行。粒度を変えるとここが総取り替えになる。

CREATE TABLE post_rarity_scores (
    post_id           uuid         NOT NULL REFERENCES posts (id) ON DELETE CASCADE,
    grain_version_id  smallint     NOT NULL REFERENCES spot_grain_versions (id) ON DELETE CASCADE,
    ruleset_id        smallint     NOT NULL REFERENCES scoring_rulesets (id),
    rarity_score      numeric(5,2) NOT NULL,
    -- 例: {"base":12.4,"spot_post_count":37,"first_combination":8.0,"revival":0.0}
    breakdown         jsonb        NOT NULL DEFAULT '{}'::jsonb,
    computed_at       timestamptz  NOT NULL DEFAULT now(),

    PRIMARY KEY (post_id, grain_version_id),
    CONSTRAINT rarity_score_range_ck CHECK (rarity_score >= 0 AND rarity_score <= 30)
);


-- ---------------------------------------------------------------------------
-- ③ コミュニティ加点（0–20 / 24時間で確定）
-- ---------------------------------------------------------------------------
-- Elo は投票のたびにオンライン更新し、24時間後に確定だけを行う（docs/02 §4.3）。

CREATE TABLE post_community_scores (
    post_id           uuid         PRIMARY KEY REFERENCES posts (id) ON DELETE CASCADE,
    elo_rating        numeric(7,2) NOT NULL DEFAULT 1500.00,
    vote_count        integer      NOT NULL DEFAULT 0,
    win_count         integer      NOT NULL DEFAULT 0,
    community_score   numeric(5,2),
    finalize_at       timestamptz  NOT NULL,
    finalized_at      timestamptz,

    CONSTRAINT community_score_range_ck CHECK (community_score IS NULL OR (community_score >= 0 AND community_score <= 20)),
    CONSTRAINT community_counts_ck      CHECK (vote_count >= 0 AND win_count >= 0 AND win_count <= vote_count)
);

-- finalizer（1分間隔のスイープ）が舐める索引。docs/02 §4.2
CREATE INDEX community_due_idx ON post_community_scores (finalize_at)
    WHERE finalized_at IS NULL;


-- ---------------------------------------------------------------------------
-- votes — 2枚並べた比較投票（docs/00 §2③）
-- ---------------------------------------------------------------------------
-- 「いいね」ではなく比較投票にするのは、フォロワー数の暴力を受けにくくするため。

CREATE TABLE votes (
    id                bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    voter_id          uuid        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    winner_post_id    uuid        NOT NULL REFERENCES posts (id) ON DELETE CASCADE,
    loser_post_id     uuid        NOT NULL REFERENCES posts (id) ON DELETE CASCADE,
    -- 同じスポットを訪れたことがあるユーザーの票を重くする（docs/00 §2③）
    weight            real        NOT NULL DEFAULT 1.0,
    -- 監査用。どのファセットの比較として提示したか
    grain_version_id  smallint    REFERENCES spot_grain_versions (id) ON DELETE SET NULL,
    spot_id           uuid        REFERENCES spots (id) ON DELETE SET NULL,
    created_at        timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT votes_distinct_ck CHECK (winner_post_id <> loser_post_id),
    CONSTRAINT votes_weight_ck   CHECK (weight > 0 AND weight <= 3.0)
);

-- 同じ人が同じペアに何度も投票できないようにする（順序は問わない）
CREATE UNIQUE INDEX votes_voter_pair_uix ON votes (
    voter_id,
    least(winner_post_id, loser_post_id),
    greatest(winner_post_id, loser_post_id)
);

CREATE INDEX votes_winner_idx ON votes (winner_post_id, created_at);
CREATE INDEX votes_loser_idx  ON votes (loser_post_id, created_at);


-- ---------------------------------------------------------------------------
-- ② の計算（純SQL・AI不使用）
-- ---------------------------------------------------------------------------
-- p_spot_post_count は「この投稿を含まない」そのスポットの累計投稿数。
--
--   base    = w_base * (1 - ln(1+n) / ln(1+n_ref))        対数逓減
--   first   = w_first                                      初の組み合わせ
--   revival = w_revival                                    直近 revival_days 投稿ゼロ
--
-- 既定の重みは scoring_rulesets.weights に入れる。ここでの数値はフォールバック。

CREATE FUNCTION calc_rarity_score(
    p_weights           jsonb,
    p_spot_post_count   integer,
    p_is_first          boolean,
    p_days_since_prev   integer,      -- そのスポットの前回投稿からの日数。NULL = 初投稿
    p_penalty_mult      real DEFAULT 1.0  -- 不正チェック失敗時に 0.5 などを渡す
) RETURNS jsonb
LANGUAGE sql
IMMUTABLE
AS $$
    WITH w AS (
        SELECT
            COALESCE((p_weights ->> 'rarity_base_max')::numeric,  18.0) AS base_max,
            COALESCE((p_weights ->> 'rarity_first')::numeric,      8.0) AS first_bonus,
            COALESCE((p_weights ->> 'rarity_revival')::numeric,    4.0) AS revival_bonus,
            COALESCE((p_weights ->> 'rarity_n_ref')::numeric,    500.0) AS n_ref,
            COALESCE((p_weights ->> 'rarity_revival_days')::int,    30) AS revival_days,
            COALESCE((p_weights ->> 'rarity_cap')::numeric,       30.0) AS cap
    ),
    parts AS (
        SELECT
            round(w.base_max * greatest(
                0.0,
                1.0 - ln(1.0 + greatest(p_spot_post_count, 0)) / ln(1.0 + w.n_ref)
            ), 2) AS base,
            CASE WHEN p_is_first THEN w.first_bonus ELSE 0.0 END AS first_bonus,
            CASE
                WHEN p_days_since_prev IS NOT NULL AND p_days_since_prev >= w.revival_days
                THEN w.revival_bonus ELSE 0.0
            END AS revival,
            w.cap
        FROM w
    )
    SELECT jsonb_build_object(
        'rarity_score', least(parts.cap,
                              round((parts.base + parts.first_bonus + parts.revival)
                                    * p_penalty_mult::numeric, 2)),
        'base',              parts.base,
        'first_combination', parts.first_bonus,
        'revival',           parts.revival,
        'spot_post_count',   p_spot_post_count,
        'penalty_mult',      p_penalty_mult
    )
    FROM parts;
$$;

COMMENT ON FUNCTION calc_rarity_score IS
    '② 希少性ボーナス。breakdown 付きで返すのは、ユーザーに理由を提示できるようにするため。';


-- ---------------------------------------------------------------------------
-- ③ の確定計算
-- ---------------------------------------------------------------------------
-- Elo を 0–1 の期待勝率に写し、票数が少ないうちは平均へ縮約する。
-- 縮約が無いと、2票しか入らなかった写真が偶然の連勝で上位に飛ぶ。
-- docs/00 §2③「票数が少ない写真も適正な位置に収束する」はこの縮約とセットで成立する。
--
-- 票ゼロの投稿には中央値（w_cap の半分）が入る。減点にしないのは表示ポリシー
-- （docs/00 §3「減点・下位順位は一切表示しない」）と整合させるため。

CREATE FUNCTION calc_community_score(
    p_weights    jsonb,
    p_elo        numeric,
    p_vote_count integer
) RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $$
    WITH w AS (
        SELECT
            COALESCE((p_weights ->> 'community_max')::numeric,    20.0) AS cap,
            COALESCE((p_weights ->> 'community_elo_ref')::numeric, 1500.0) AS elo_ref,
            COALESCE((p_weights ->> 'community_shrink_m')::numeric,  8.0) AS shrink_m
    ),
    calc AS (
        SELECT
            1.0 / (1.0 + power(10.0, (w.elo_ref - p_elo) / 400.0)) AS expected,
            greatest(p_vote_count, 0)::numeric
                / (greatest(p_vote_count, 0)::numeric + w.shrink_m) AS confidence,
            w.cap
        FROM w
    )
    SELECT round(calc.cap * (calc.expected * calc.confidence
                             + 0.5 * (1.0 - calc.confidence)), 2)
    FROM calc;
$$;

COMMENT ON FUNCTION calc_community_score IS
    '③ コミュニティ加点。Elo期待勝率にベイズ縮約をかけて 0–20 に写す。';


-- ---------------------------------------------------------------------------
-- 投票の適用（Elo オンライン更新）
-- ---------------------------------------------------------------------------
-- K値は票数とともに逓減させる。序盤は速く動き、後半は安定する。

CREATE FUNCTION apply_vote(
    p_voter_id   uuid,
    p_winner_id  uuid,
    p_loser_id   uuid,
    p_weight     real     DEFAULT 1.0,
    p_grain_id   smallint DEFAULT NULL,
    p_spot_id    uuid     DEFAULT NULL,
    p_k_base     numeric  DEFAULT 32.0,
    p_k_ref      numeric  DEFAULT 20.0,
    p_k_min      numeric  DEFAULT 8.0
) RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    v_win_elo   numeric;
    v_lose_elo  numeric;
    v_win_n     integer;
    v_lose_n    integer;
    v_expected  numeric;
    v_k_win     numeric;
    v_k_lose    numeric;
    v_delta     numeric;
BEGIN
    INSERT INTO votes (voter_id, winner_post_id, loser_post_id, weight, grain_version_id, spot_id)
    VALUES (p_voter_id, p_winner_id, p_loser_id, p_weight, p_grain_id, p_spot_id);

    -- デッドロック回避のため、常に post_id の昇順で2行をロックしてから読む
    PERFORM 1
       FROM post_community_scores
      WHERE post_id IN (p_winner_id, p_loser_id)
      ORDER BY post_id
        FOR UPDATE;

    SELECT elo_rating, vote_count INTO v_win_elo,  v_win_n
        FROM post_community_scores WHERE post_id = p_winner_id;
    SELECT elo_rating, vote_count INTO v_lose_elo, v_lose_n
        FROM post_community_scores WHERE post_id = p_loser_id;

    IF v_win_elo IS NULL OR v_lose_elo IS NULL THEN
        RAISE EXCEPTION 'post_community_scores row missing for % or %', p_winner_id, p_loser_id;
    END IF;

    v_expected := 1.0 / (1.0 + power(10.0, (v_lose_elo - v_win_elo) / 400.0));
    v_k_win    := greatest(p_k_min, p_k_base * p_k_ref / (p_k_ref + v_win_n));
    v_k_lose   := greatest(p_k_min, p_k_base * p_k_ref / (p_k_ref + v_lose_n));
    v_delta    := (1.0 - v_expected) * p_weight::numeric;

    UPDATE post_community_scores
       SET elo_rating = elo_rating + v_k_win * v_delta,
           vote_count = vote_count + 1,
           win_count  = win_count + 1
     WHERE post_id = p_winner_id;

    UPDATE post_community_scores
       SET elo_rating = elo_rating - v_k_lose * v_delta,
           vote_count = vote_count + 1
     WHERE post_id = p_loser_id;
END;
$$;


-- ---------------------------------------------------------------------------
-- 合計点（サーバー内部専用）
-- ---------------------------------------------------------------------------
-- docs/00 §3【変更禁止】: 生の合計点は絶対に公開しない。
-- このビューはランキング生成とデバッグ専用で、APIから直接返してはいけない。
-- クライアントに出してよいのは 0005 の v_post_display だけ。

CREATE VIEW v_post_total_score AS
SELECT
    a.post_id,
    a.grain_version_id,
    COALESCE(ai.ai_score, 0)                    AS ai_score,
    COALESCE(r.rarity_score, 0)                 AS rarity_score,
    COALESCE(c.community_score, 0)              AS community_score,
    COALESCE(ai.ai_score, 0)
      + COALESCE(r.rarity_score, 0)
      + COALESCE(c.community_score, 0)          AS total_score,
    c.finalized_at IS NOT NULL                  AS community_finalized
FROM post_spot_assignment a
LEFT JOIN LATERAL (
    SELECT ai_score FROM post_ai_scores s
     WHERE s.post_id = a.post_id
     ORDER BY s.computed_at DESC
     LIMIT 1
) ai ON true
LEFT JOIN post_rarity_scores    r ON r.post_id = a.post_id AND r.grain_version_id = a.grain_version_id
LEFT JOIN post_community_scores c ON c.post_id = a.post_id;

COMMENT ON VIEW v_post_total_score IS
    '内部専用。生の合計点はAPIから返さないこと（docs/00 §3 表示ポリシー）。';
