-- ---------------------------------------------------------------------------
-- 0012 — 文章でしか守っていなかった不変条件を、型と関数で守り直す
-- ---------------------------------------------------------------------------
-- ここまでの設計は正しいが、以下の3点が「実装者が規約を覚えていること」に
-- 依存していた。運用に入ると必ず踏むので、DB側で拒否できる形に落とす。
--
--   1. ルールセットの重みを後から書き換えると、過去の採点行が
--      「採点当時と違う重み」を指す（CLAUDE.md 実装上の決定事項）
--   2. v_user_personal_best が生の合計点を返す（表示ポリシー・引継ぎ書§3）
--   3. 「初」ボーナスの発行条件（docs/01 §3.3）を判定する場所がどこにもない
--
-- 追記のみ。既存ファイルは書き換えていない。


-- ---------------------------------------------------------------------------
-- 1. 配点ルールセットは参照された時点で凍結する
-- ---------------------------------------------------------------------------
-- post_rarity_scores.ruleset_id は「この投稿がどの重みで採点されたか」の証拠。
-- 重みを in-place で書き換えると、その証拠が黙って書き換わる。
-- 0009 が active 行に discovery_new_spot_max_posts を足しているが、
-- 参照する採点行がまだ0件の時点だったので影響は無い。以後は同じことを許さない。
--
-- 参照が付いていない間の編集は許す（seed の調整まで禁じると運用が止まるため）。
-- 参照が付いた後は publish_scoring_ruleset() で新しい版を切ること。

CREATE FUNCTION scoring_ruleset_freeze_guard() RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.weights IS DISTINCT FROM OLD.weights
       AND EXISTS (SELECT 1 FROM post_rarity_scores WHERE ruleset_id = OLD.id)
    THEN
        RAISE EXCEPTION
            '採点済みの配点ルールセット(id=%, code=%)の重みは変更できない。publish_scoring_ruleset() で新しい版を作ること',
            OLD.id, OLD.code;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER scoring_rulesets_freeze_trg
    BEFORE UPDATE ON scoring_rulesets
    FOR EACH ROW EXECUTE FUNCTION scoring_ruleset_freeze_guard();

COMMENT ON FUNCTION scoring_ruleset_freeze_guard IS
    '採点に使われた重みを後から書き換えさせない。どの投稿がどの重みで採点されたかを追えなくなるため。';


-- trust_rulesets（0011）も post_trust_scores.ruleset_id から参照される同じ構造なので、
-- 同じ理由で凍結する。誤検知の申し立てに「採点当時の重み」で答えられなくなるため。

CREATE FUNCTION trust_ruleset_freeze_guard() RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.weights IS DISTINCT FROM OLD.weights
       AND EXISTS (SELECT 1 FROM post_trust_scores WHERE ruleset_id = OLD.id)
    THEN
        RAISE EXCEPTION
            '判定済みの信頼度ルールセット(id=%, code=%)の重みは変更できない。新しい版を作ること',
            OLD.id, OLD.code;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trust_rulesets_freeze_trg
    BEFORE UPDATE ON trust_rulesets
    FOR EACH ROW EXECUTE FUNCTION trust_ruleset_freeze_guard();


-- 新しい版を切る唯一の入口。現行の重みを引き継いで差分だけ渡せるようにしてある。
-- is_active の部分一意索引があるので、落としてから立てる順序を守る必要がある。
-- それを毎回手で書かせないための関数。

CREATE FUNCTION publish_scoring_ruleset(
    p_code        text,
    p_weight_diff jsonb,     -- 現行 active の weights にマージする差分
    p_note        text DEFAULT NULL
) RETURNS smallint
LANGUAGE plpgsql
AS $$
DECLARE
    v_base jsonb;
    v_id   smallint;
BEGIN
    SELECT weights INTO v_base FROM scoring_rulesets WHERE is_active;
    IF v_base IS NULL THEN
        RAISE EXCEPTION 'アクティブな配点ルールセットが無い';
    END IF;

    UPDATE scoring_rulesets SET is_active = false WHERE is_active;

    INSERT INTO scoring_rulesets (code, is_active, weights, note)
    VALUES (p_code, true, v_base || COALESCE(p_weight_diff, '{}'::jsonb), p_note)
    RETURNING id INTO v_id;

    RETURN v_id;
END;
$$;

COMMENT ON FUNCTION publish_scoring_ruleset IS
    '配点の重みを変えるときの唯一の入口。既存行を書き換えず新しい版を足して active を差し替える。';


-- ---------------------------------------------------------------------------
-- 2. 自己ベストのビューから生の合計点を外す
-- ---------------------------------------------------------------------------
-- 0005 の v_user_personal_best は「点数そのものは返さない」とコメントしながら
-- total_score を返していた。名前が完全にユーザー向けなので、いずれ API から
-- 引かれる。内部用と公開用を名前で分ける。
--
-- 「自己ベストを更新したか」は点数を出さずに言える（best_post_id が変わったか）。

DROP VIEW v_user_personal_best;

-- 内部用。再計算ジョブと通知の判定だけが使う。API から返さないこと。
CREATE VIEW v_user_personal_best_internal AS
SELECT DISTINCT ON (p.author_id, a.grain_version_id)
    p.author_id,
    a.grain_version_id,
    p.id          AS best_post_id,
    t.total_score AS best_total_score,
    p.posted_at   AS achieved_at
FROM posts p
JOIN post_spot_assignment a ON a.post_id = p.id
JOIN v_post_total_score   t ON t.post_id = a.post_id
                           AND t.grain_version_id = a.grain_version_id
WHERE p.status = 'published'
ORDER BY p.author_id, a.grain_version_id, t.total_score DESC, p.posted_at ASC;

COMMENT ON VIEW v_user_personal_best_internal IS
    '内部専用。生の合計点を含む。API から返さないこと（v_post_total_score と同じ扱い）。';

-- 公開用。どの投稿が自己ベストかと、いつ更新したかだけを返す。
CREATE VIEW v_user_personal_best AS
SELECT
    author_id,
    grain_version_id,
    best_post_id,
    achieved_at
FROM v_user_personal_best_internal;

COMMENT ON VIEW v_user_personal_best IS
    '公開してよい自己ベスト。点数は返さない（引継ぎ書§3・変更禁止）。';


-- ---------------------------------------------------------------------------
-- 3. 「初」ボーナスの発行条件を1か所に固める（docs/01 §3.3）
-- ---------------------------------------------------------------------------
-- 「そのファセットで初めてか」は record_facet_post が spot_facet_stats で
-- 判定している。足りないのは、その手前の **発行資格**（§3.3 の5条件）の判定で、
-- record_facet_post の p_eligible にどこから true を渡すかが未定義だった。
-- ingest を書く人がリテラルの true を渡せば、そこが抜け道になる。
--
-- 呼び出しの連鎖はこうなる:
--   is_first_bonus_eligible() → record_facet_post(p_eligible) → calc_rarity_score(p_is_first)
--
-- 0011 の trust_first_bonus_eligible(band) も「初」のゲートなので、ここに畳み込む。
-- ゲートが2か所に分かれていると、片方だけ呼ぶ実装が必ず出る。
--
-- 判定を jsonb で返すのは、落ちた理由をユーザーに説明できるようにするため
-- （引継ぎ書§6。「なぜこの点数か」を語れることがプロダクト価値そのもの）。
--
-- EXIF整合チェックは「通過していること」を要求する。未実施を通過扱いにすると、
-- チェックを走らせない経路を作るだけで条件が外れてしまう
-- （v_post_integrity.spoofing_clean は未実施を true に倒すので、ここでは使わない）。

CREATE FUNCTION first_bonus_eligibility(
    p_post_id          uuid,
    p_grain_version_id smallint
) RETURNS jsonb
LANGUAGE sql
STABLE
AS $$
    WITH ctx AS (
        SELECT
            p.id, p.author_id, p.weather,
            p.gps_accuracy_m, p.captured_at,
            a.spot_id, a.bearing_sector, a.low_confidence
        FROM posts p
        JOIN post_spot_assignment a ON a.post_id = p.id
                                   AND a.grain_version_id = p_grain_version_id
        WHERE p.id = p_post_id
    ),
    checks AS (
        SELECT
            ctx.*,
            (ctx.bearing_sector IS NOT NULL)                             AS has_bearing,
            (ctx.weather IS NOT NULL)                                    AS has_weather,
            (ctx.gps_accuracy_m IS NOT NULL AND ctx.gps_accuracy_m <= 100) AS accuracy_ok,
            (NOT ctx.low_confidence)                                     AS confidence_ok,
            -- 位置・時刻の整合チェックが両方とも実施済みで、かつ通過している
            (SELECT count(*) FILTER (WHERE c.passed) = 2
               FROM post_integrity_checks c
              WHERE c.post_id = ctx.id
                AND c.check_kind IN ('exif_location_match', 'exif_time_match')
            ) AS integrity_ok,
            -- 同一ユーザーが同一スポットで直近24時間に「初」を取っていない。
            -- 「取った」の記録は spot_facet_stats.first_post_id が持っている。
            -- 1人が同じ峠で方位を変えて8連投すると8回「初」が出る、という
            -- 一番踏まれやすい抜け道を塞ぐ条件（docs/01 §3.3）。
            NOT EXISTS (
                SELECT 1
                  FROM spot_facet_stats s
                  JOIN posts fp ON fp.id = s.first_post_id
                 WHERE s.grain_version_id = p_grain_version_id
                   AND s.spot_id   = ctx.spot_id
                   AND fp.author_id = ctx.author_id
                   AND fp.id       <> ctx.id
                   AND s.first_post_at > ctx.captured_at - interval '24 hours'
            ) AS no_recent_first,
            -- 信頼度の帯域（0011 / docs/04 §6 SEC-TRUST-02）。通常帯だけ通す。
            -- 未判定を通過扱いにしないのは EXIF と同じ理由で、trust の計算を
            -- 飛ばす経路がそのまま抜け道になるため。
            COALESCE(
                (SELECT trust_first_bonus_eligible(t.band)
                   FROM post_trust_scores t WHERE t.post_id = ctx.id),
                false
            ) AS trust_ok
        FROM ctx
    )
    SELECT jsonb_build_object(
        'eligible',        has_bearing AND has_weather AND accuracy_ok AND confidence_ok
                           AND integrity_ok AND no_recent_first AND trust_ok,
        'has_bearing',     has_bearing,
        'has_weather',     has_weather,
        'accuracy_ok',     accuracy_ok,
        'confidence_ok',   confidence_ok,
        'integrity_ok',    integrity_ok,
        'no_recent_first', no_recent_first,
        'trust_ok',        trust_ok
    )
    FROM checks;
$$;

COMMENT ON FUNCTION first_bonus_eligibility IS
    '「初」ボーナスの発行条件（docs/01 §3.3）。落ちた理由を jsonb で返す。';


-- record_facet_post の p_eligible に渡すのはこれ。呼び出し側で true を作らせない。
-- 投稿がまだスポットに割り当たっていない（該当行なし）なら false。

CREATE FUNCTION is_first_bonus_eligible(
    p_post_id          uuid,
    p_grain_version_id smallint
) RETURNS boolean
LANGUAGE sql
STABLE
AS $$
    SELECT COALESCE(
        (first_bonus_eligibility(p_post_id, p_grain_version_id) ->> 'eligible')::boolean,
        false
    );
$$;

COMMENT ON FUNCTION is_first_bonus_eligible IS
    'record_facet_post の p_eligible はこの関数の戻り値を渡すこと。boolean を直接組み立てない。';
