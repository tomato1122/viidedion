-- ---------------------------------------------------------------------------
-- 0015 — 資料間の矛盾 M-1 / M-6 の解消
-- ---------------------------------------------------------------------------
-- docs/04 が MUST として書いた2つの要件が、スキーマ側で実現できない状態だった。
-- どちらも T-13（ingest）・T-19（API）が触る手前なので、着手前に埋める。
--
--   M-1  SEC-VOTE-02「作成24時間未満のアカウントの票は weight 0 で記録する」
--        → votes_weight_ck が weight > 0 を要求していて INSERT できない
--   M-6  SEC-TRUST-02「保留帯（trust_score < 0.40）は非公開 + レビューキュー行き」
--        → band='held' を保存できるだけで、非公開にする仕組みが無い
--
-- 追記のみ。既存ファイルは書き換えていない。


-- ---------------------------------------------------------------------------
-- M-1(a) weight 0 の票を記録できるようにする
-- ---------------------------------------------------------------------------
-- シャドウバンは「拒否せず、受け付けて効かせない」ことで成立する。
-- 拒否すると攻撃者に閾値が伝わる（docs/04 SEC-VOTE-02）。

ALTER TABLE votes DROP CONSTRAINT votes_weight_ck;
ALTER TABLE votes ADD CONSTRAINT votes_weight_ck
    CHECK (weight >= 0 AND weight <= 3.0);

COMMENT ON COLUMN votes.weight IS
    '0 は「受け付けたが効かせない」票（SEC-VOTE-02 のシャドウバン）。拒否ではないので行は残す。';


-- ---------------------------------------------------------------------------
-- M-1(b) weight 0 の票を vote_count に数えない
-- ---------------------------------------------------------------------------
-- 制約を緩めるだけでは要件を満たさない。0004 の apply_vote は weight が 0 でも
-- vote_count を増やす。vote_count は calc_community_score の縮約項
--
--     confidence = vote_count / (vote_count + shrink_m)
--
-- に効くので、票を投げるほど confidence が上がり、③の確定値が中央値から
-- 離れていく。**つまり weight 0 の票でもスコアは動く。**
-- 新規アカウントを並べて連投すれば、狙った投稿の点を押し上げられる。
-- 「受け付けるが効かせない」を実際に成立させるには、ここも止める必要がある。
--
-- votes 行そのものは残す。監査証跡になり、かつ voter × pair のユニーク制約が
-- 効き続けるので、攻撃者からは通常の投票と区別が付かない。

CREATE OR REPLACE FUNCTION apply_vote(
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

    -- 効かせない票はここで終わり。Elo も vote_count も動かさない。
    IF p_weight = 0 THEN
        RETURN;
    END IF;

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

COMMENT ON FUNCTION apply_vote IS
    'Elo のオンライン更新。weight 0 の票は記録だけして Elo にも vote_count にも影響させない（SEC-VOTE-02）。';


-- ---------------------------------------------------------------------------
-- M-6 保留帯（band='held'）を実際に非公開にする
-- ---------------------------------------------------------------------------
-- docs/04 SEC-TRUST-02 は保留帯を「非公開 + レビューキュー行き」と定めているが、
-- band を保存するだけで公開経路のどこもそれを見ていなかった。
--
-- 「非公開」の表現はこのスキーマに既にある（`posts.status = 'hidden'`。0002 で
-- 転載検出用に定義済み）。保留帯を別経路にせず、そこへ合流させる。
-- 経路を1本に保つほうが、公開ビューを足すたびに条件を書き写す設計より壊れにくい。
--
-- レビューキューは既存の索引がそのまま使える
-- （0011 の post_trust_band_idx。band <> 'normal' の部分索引）。

CREATE FUNCTION hide_post_on_held_trust() RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.band = 'held' THEN
        UPDATE posts SET status = 'hidden'
         WHERE id = NEW.post_id AND status <> 'hidden';
    END IF;
    -- 保留から出ても自動では戻さない。復帰はレビューを通す人の判断
    -- （転載検出で hidden にした投稿を、trust の再計算が勝手に公開してしまうため）。
    RETURN NEW;
END;
$$;

CREATE TRIGGER post_trust_held_hides_trg
    AFTER INSERT OR UPDATE OF band ON post_trust_scores
    FOR EACH ROW EXECUTE FUNCTION hide_post_on_held_trust();

COMMENT ON FUNCTION hide_post_on_held_trust IS
    '保留帯の投稿を非公開にする（SEC-TRUST-02）。復帰は自動化しない——レビューの判断を上書きしてしまうため。';


-- ---------------------------------------------------------------------------
-- 公開ビューが posts.status を見るようにする
-- ---------------------------------------------------------------------------
-- rebuild_ranking_entries は `p.status = 'published'` で母数を絞っているので、
-- 次の再生成が走れば held の投稿は ranking_entries から落ちる。
-- ただし再生成までの間、既存の行がビューから返り続ける。**非公開は即時でなければ
-- 意味がない**ので、ビュー側でも見る。
--
-- v_post_location_public は status を一切見ていなかった。pending / hidden の
-- 投稿の粗い位置まで返る状態だったので、ここで塞ぐ。

DROP VIEW v_post_display;
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
JOIN spots s ON s.id = e.spot_id
JOIN posts pp ON pp.id = e.post_id AND pp.status = 'published';

COMMENT ON VIEW v_post_display IS
    '表示ポリシー準拠の唯一の公開ビュー。生の合計点と下位順位は含めない（docs/00 §3）。非公開の投稿は返さない。';


DROP VIEW v_spot_titles;
CREATE VIEW v_spot_titles AS
SELECT
    e.spot_identity_id,
    i.slug,
    COALESCE(i.canonical_name, s.display_name) AS spot_name,
    p.author_id,
    e.post_id,
    e.period_id,
    per.kind        AS period_kind,
    per.starts_at,
    per.ends_at,
    e.bearing_sector,
    e.weather,
    e.timeslot,
    e.season,
    e.rank
FROM ranking_entries e
JOIN spot_identity   i   ON i.id = e.spot_identity_id
JOIN spots           s   ON s.id = e.spot_id
JOIN posts           p   ON p.id = e.post_id
JOIN ranking_periods per ON per.id = e.period_id
-- 称号は1位のみ。順位そのものを晒さないための絞り込みでもある。
WHERE e.rank = 1
  AND p.status = 'published';


DROP VIEW v_post_recognition;
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
JOIN posts                p ON p.id    = e.post_id AND p.status = 'published'

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
JOIN spot_identity i ON i.id = d.spot_identity_id
JOIN posts         p ON p.id = d.post_id AND p.status = 'published';

COMMENT ON VIEW v_post_recognition IS
    '公開中の投稿1件につき必ず1行。順位（rank）か発見表現（discovery）のどちらかが返る（T-02）。非公開の投稿は行を返さない。';


DROP VIEW v_post_location_public;
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
LEFT JOIN h3_cell_centers g ON g.h3_index = p.coarse_h3_r8
WHERE p.status = 'published';

COMMENT ON VIEW v_post_location_public IS
    '座標を返してよい唯一のビュー（SEC-PRIV-02）。表示座標はセル中心で、公開中の投稿だけを返す。';
