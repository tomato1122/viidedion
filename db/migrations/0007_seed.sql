-- 0007_seed.sql
-- 初期の粒度バージョンと配点ルールセット。
-- どちらも「暫定値であり、実データを見て動かす前提」であることを note に明記しておく。

INSERT INTO spot_grain_versions (
    code, status, note,
    h3_resolution, snap_radius_m, poi_match_radius_m, bearing_sector_count,
    dbscan_eps_m, dbscan_min_points, dbscan_min_users, gps_accuracy_reject_m
) VALUES (
    'g1-h3r9-sector8', 'active',
    'MVP初期値。h3 res9（辺長≒174m）+ 吸着120m + 8方位。docs/01 §1.1 / §7 の指標で見直す',
    9, 120.0, 150.0, 8,
    80.0, 5, 3, 100.0
);

INSERT INTO scoring_rulesets (code, is_active, weights, note) VALUES (
    'r1-mvp', true,
    jsonb_build_object(
        -- ① AIベース点（0–50）。内訳は推論ワーカー側の weights.yaml と一致させること（docs/02 §2.3）
        'ai_max',              50.0,
        'ai_scenicness',       24.0,   -- Scenic-Or-Not 転移学習のベースライン
        'ai_fractal',          10.0,   -- D=1.4 を頂点とする山型関数
        'ai_fractal_peak',      1.40,  -- Spehar et al. (2003) / Hagerhall et al. (2004)
        'ai_fractal_sigma',     0.15,
        'ai_sky',               8.0,   -- 空比率は正、過剰な雲は負
        'ai_elements',          8.0,   -- 水域・山・建造物の加点テーブル
        -- 技術品質は加点ではなく足切りの係数として掛ける（docs/00 §2①「配点は小さく」）
        'ai_tech_mult_floor',   0.70,

        -- ② 希少性ボーナス（0–30）
        'rarity_cap',          30.0,
        'rarity_base_max',     18.0,
        'rarity_first',         8.0,
        'rarity_revival',       4.0,
        'rarity_n_ref',       500.0,   -- 累計500投稿で base がほぼ 0 になる
        'rarity_revival_days',   30,

        -- ③ コミュニティ加点（0–20）
        'community_max',       20.0,
        'community_elo_ref', 1500.0,
        'community_shrink_m',   8.0,   -- 票数8でおおよそ半分だけ Elo を信用する
        'community_window_h',    24,

        -- ランキング配信の足切り（docs/01 §3.2）
        'ranking_min_facet_posts', 5
    ),
    'MVP暫定。docs/00 §8「配点の具体的な重み」は未決定のため、ここを動かして調整する'
);
