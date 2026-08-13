-- ---------------------------------------------------------------------------
-- 0013 — 配信中の粒度バージョンのスポットを動かさない（I-1〜I-3 のガード）
-- ---------------------------------------------------------------------------
-- 0008 の upsert_spot_with_identity は
--   ON CONFLICT (grain_version_id, identity_id) DO UPDATE SET centroid = ...
-- で、既に存在する実体の重心と h3_index を無条件に書き換える。
--
-- Blue-Green の手順（docs/01 §4.2）どおりに draft / shadow を組み立てている限りは
-- 正しい。しかし対象バージョンを取り違えて active を渡すと、**配信中のスポットが
-- 黙って移動する**。CLAUDE.md の「既存行は絶対に UPDATE しない」が、運用手順を
-- 守っていることだけに依存していた。
--
-- ここでの線引き:
--
--   * 新規スポットの INSERT はどの status でも許す。
--     通常の取り込み（docs/01 §1.2 の [POI] / [CELL]）は active に対して走るので、
--     ここを止めると ingest が動かなくなる。これは「既存行の UPDATE」ではない。
--   * 既存実体の重心・h3_index の書き換えは draft / shadow でだけ許す。
--     再計算はそこでしか起きない。
--   * active / deprecated では重心を動かさず、**未命名（display_name IS NULL）の
--     ときに名前を埋めることだけ**を許す。命名フロー（docs/01 §1.4）は配信中の
--     バージョンに対して走るため。既に付いている名前は上書きしない
--     （改名は rename_spot_identity() が alias に退避してから行う）。
--
-- 例外ではなく無視にしているのは、取り込みが投稿ごとのホットパスで、
-- 再試行のたびに落ちると1件の失敗が投稿全体の失敗になるため。
-- 取り違えは v_grain_health（0006）の実体数の差で見つける。

CREATE OR REPLACE FUNCTION upsert_spot_with_identity(
    p_grain_version_id   smallint,
    p_kind               spot_kind,
    p_h3_index           bigint,
    p_centroid           geography,
    p_display_name       text     DEFAULT NULL,
    p_name_source        spot_name_source DEFAULT NULL,
    p_source_code        text     DEFAULT NULL,
    p_poi_external_id    text     DEFAULT NULL,
    p_parent_identity_id uuid     DEFAULT NULL,
    p_lineage_op         spot_lineage_op DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql
AS $$
DECLARE
    v_identity uuid;
    v_spot     uuid;
    v_op       spot_lineage_op;
    v_status   grain_status;
BEGIN
    IF p_parent_identity_id IS NOT NULL THEN
        -- 既存スポットの続き。slug も称号も引き継がれる。
        v_identity := p_parent_identity_id;
        v_op       := COALESCE(p_lineage_op, 'carry_over');
    ELSE
        INSERT INTO spot_identity (
            slug, canonical_name, name_source, source_code, representative_point
        ) VALUES (
            generate_spot_slug(p_display_name, p_centroid),
            p_display_name, p_name_source, p_source_code, p_centroid
        )
        RETURNING id INTO v_identity;
        v_op := COALESCE(p_lineage_op, 'create');
    END IF;

    INSERT INTO spots (
        grain_version_id, kind, h3_index, centroid,
        display_name, name_source, poi_source, source_code, poi_external_id, identity_id
    ) VALUES (
        p_grain_version_id, p_kind, p_h3_index, p_centroid,
        p_display_name, p_name_source, p_source_code, p_source_code, p_poi_external_id, v_identity
    )
    ON CONFLICT (grain_version_id, identity_id) DO NOTHING
    RETURNING id INTO v_spot;

    IF v_spot IS NULL THEN
        -- 既にこの粒度バージョンでの実体がある。書き換えてよいかは status で決まる。
        SELECT status INTO v_status
          FROM spot_grain_versions WHERE id = p_grain_version_id;

        -- display_name と name_source は必ず一緒に動かす。
        -- spots_name_source_ck（名前があれば出所も要る）に引っかかるため。
        -- 0008 の ON CONFLICT は display_name だけを更新していて、未命名の実体に
        -- 名前を渡すと制約違反で落ちる状態だった。
        IF v_status IN ('draft', 'shadow') THEN
            UPDATE spots
               SET h3_index     = p_h3_index,
                   centroid     = p_centroid,
                   display_name = COALESCE(p_display_name, display_name),
                   name_source  = CASE WHEN p_display_name IS NOT NULL
                                       THEN p_name_source ELSE name_source END
             WHERE grain_version_id = p_grain_version_id
               AND identity_id      = v_identity
            RETURNING id INTO v_spot;
        ELSE
            -- 配信中 / ロールバック先。重心は動かさない。
            UPDATE spots
               SET display_name = COALESCE(display_name, p_display_name),
                   name_source  = CASE WHEN display_name IS NULL AND p_display_name IS NOT NULL
                                       THEN p_name_source ELSE name_source END
             WHERE grain_version_id = p_grain_version_id
               AND identity_id      = v_identity
            RETURNING id INTO v_spot;
        END IF;
    END IF;

    INSERT INTO spot_lineage (
        op, from_grain_version_id, to_grain_version_id, parent_identity_id, child_identity_id
    )
    SELECT v_op,
           (SELECT grain_version_id FROM spots WHERE identity_id = p_parent_identity_id
              AND grain_version_id <> p_grain_version_id ORDER BY grain_version_id DESC LIMIT 1),
           p_grain_version_id,
           CASE WHEN v_op = 'create' THEN NULL ELSE p_parent_identity_id END,
           v_identity
    ON CONFLICT DO NOTHING;

    RETURN v_spot;
END;
$$;

COMMENT ON FUNCTION upsert_spot_with_identity IS
    '粒度バージョンの実体を作る唯一の入口。配信中（active / deprecated）のバージョンでは既存実体の重心を動かさない（docs/01 §4.2 Blue-Green）。';
