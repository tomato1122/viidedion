"""粒度再計算（T-21）の検証。

docs/01 §4.3。実際の PostgreSQL + PostGIS に対して実行し、
各テストはトランザクションをロールバックする。
"""

from __future__ import annotations

import math
import os
import unittest

_HAS_DB = bool(os.environ.get("DATABASE_URL") or os.environ.get("PGHOST"))

if _HAS_DB:
    import psycopg

    from core import db, grain, recalc, spots


def _offset(lat: float, lon: float, north_m: float, east_m: float) -> tuple[float, float]:
    dlat = north_m / 111_320.0
    dlon = east_m / (111_320.0 * math.cos(math.radians(lat)))
    return lat + dlat, lon + dlon


def _same_cell_far_point(lat, lon, coarse_res, fine_res):
    """粗い解像度では同じセル、細かい解像度では別セルになる点を探す。

    分割（split）を再現するのに要る。res9 は差し渡し400m程度あるので、
    決め打ちの距離では「同じ res9 セル」を保証できない。
    """
    from core import h3util

    coarse = h3util.cell_of(lat, lon, coarse_res)
    fine = h3util.cell_of(lat, lon, fine_res)
    for distance in range(40, 200, 10):
        for north, east in ((distance, 0), (0, distance), (-distance, 0), (0, -distance)):
            cand = _offset(lat, lon, north, east)
            if (h3util.cell_of(cand[0], cand[1], coarse_res) == coarse
                    and h3util.cell_of(cand[0], cand[1], fine_res) != fine):
                return cand
    raise AssertionError("分割を再現できる点が見つからない")


@unittest.skipUnless(_HAS_DB, "DATABASE_URL / PGHOST が未設定のためスキップ")
class RecalcBase(unittest.TestCase):
    LAT, LON = 35.3606, 138.7274

    def setUp(self) -> None:
        self.conn = db.connect()
        self.cur = self.conn.cursor()
        self.active = grain.load_active(self.cur)
        self.users = []
        for i in range(4):
            self.cur.execute(
                "INSERT INTO users (handle, display_name) VALUES (%s, %s) RETURNING id",
                (f"recalc-{os.urandom(4).hex()}", f"再計算テスト{i}"),
            )
            self.users.append(self.cur.fetchone()[0])

    def tearDown(self) -> None:
        self.conn.rollback()
        self.conn.close()

    def _shadow(self, resolution=10, snap_radius=60.0):
        self.cur.execute(
            """
            INSERT INTO spot_grain_versions (
                code, status, h3_resolution, snap_radius_m, poi_match_radius_m,
                bearing_sector_count, dbscan_eps_m, dbscan_min_points, dbscan_min_users,
                gps_accuracy_reject_m
            ) VALUES (%s, 'shadow', %s, %s, 150, 8, 50, 5, 3, 100)
            RETURNING id
            """,
            (f"g-recalc-{os.urandom(3).hex()}", resolution, snap_radius),
        )
        return self.cur.fetchone()[0]

    def _post(self, lat, lon, author=None, *, bearing=90.0, weather="clear",
              captured_offset_h=0, accuracy=10.0, bind=True):
        self.cur.execute(
            """
            INSERT INTO posts (author_id, status, captured_at, posted_at, location,
                               gps_accuracy_m, bearing_deg, bearing_src,
                               weather, timeslot, season)
            VALUES (%s, 'published', now() - make_interval(hours => %s), now(),
                    ST_SetSRID(ST_MakePoint(%s, %s), 4326)::geography, %s, %s::real,
                    CASE WHEN %s::real IS NULL THEN NULL ELSE 'true'::bearing_source END,
                    %s::weather_kind, 'golden', 'summer')
            RETURNING id
            """,
            (author or self.users[0], captured_offset_h, lon, lat, accuracy,
             bearing, bearing, weather),
        )
        post_id = self.cur.fetchone()[0]
        # 「初」の条件に EXIF整合チェックの通過が要る（0012 first_bonus_eligibility）
        self.cur.execute(
            """
            INSERT INTO post_integrity_checks (post_id, check_kind, passed) VALUES
                (%s, 'exif_location_match', true), (%s, 'exif_time_match', true)
            """,
            (post_id, post_id),
        )
        self.cur.execute(
            """
            INSERT INTO post_trust_scores (post_id, ruleset_id, trust_score, signals, band)
            VALUES (%s, (SELECT id FROM trust_rulesets WHERE is_active), 0.9, '{}'::jsonb, 'normal')
            """,
            (post_id,),
        )
        if bind:
            spots.bind_post(self.cur, post_id)
        return post_id


class RunLifecycleTest(RecalcBase):
    """ランの状態管理（docs/01 §4.3「途中で落ちる前提」）。"""

    def test_配信中のバージョンは再計算の対象にできない(self):
        with self.assertRaises(psycopg.errors.RaiseException):
            recalc.start_or_resume(self.cur, self.active.id)

    def test_未完了のランがあれば拾い直す(self):
        shadow = self._shadow()
        first = recalc.start_or_resume(self.cur, shadow)
        second = recalc.start_or_resume(self.cur, shadow)
        self.assertEqual(first.id, second.id, "多重起動しても1本しか走らない")

    def test_開始時点の抽出バージョンを焼き付ける(self):
        """途中で抽出が差し替わっても同じPOIを見る（docs/06 §4.2）。"""
        self.cur.execute(
            """
            INSERT INTO poi_extract_versions (source_code, extract_url, extract_date, is_active)
            VALUES ('osm', 'https://example.invalid/a.pbf', DATE '2026-08-01', true)
            RETURNING id
            """
        )
        extract_id = self.cur.fetchone()[0]

        shadow = self._shadow()
        run = recalc.start_or_resume(self.cur, shadow)
        self.assertEqual(run.poi_extract_version_id, extract_id)

    def test_カーソルで途中から再開できる(self):
        for i in range(6):
            self._post(*_offset(self.LAT, self.LON, i * 5, 0), self.users[i % 3])

        shadow = self._shadow()
        partial = recalc.run_to_completion(
            self.cur, shadow, batch_size=2, max_batches=1
        )
        self.assertEqual(partial["stopped_in"], "assign")
        self.assertEqual(partial["processed_count"], 2)

        # 同じ呼び出しで続きから進み、最後まで行く
        rest = recalc.run_to_completion(self.cur, shadow, batch_size=2)
        self.assertEqual(rest["phase"], "done")
        self.assertEqual(rest["assigned"], 6, "取りこぼしも重複もない")


class FullRecalcTest(RecalcBase):
    """フェーズ全体（docs/01 §4.3 手順1〜6）。"""

    def test_全投稿が新しい粒度に紐づく(self):
        for i in range(4):
            self._post(*_offset(self.LAT, self.LON, i * 30, 0), self.users[i % 3])

        shadow = self._shadow()
        summary = recalc.run_to_completion(self.cur, shadow)

        self.assertEqual(summary["phase"], "done")
        self.cur.execute(
            "SELECT count(*) FROM post_spot_assignment WHERE grain_version_id = %s", (shadow,)
        )
        self.assertEqual(self.cur.fetchone()[0], 4)

    def test_旧粒度の紐付けは残る(self):
        """不変条件 I-2。ロールバックできる状態を壊さない。"""
        self._post(self.LAT, self.LON)
        shadow = self._shadow()
        recalc.run_to_completion(self.cur, shadow)

        self.cur.execute(
            "SELECT count(*) FROM post_spot_assignment WHERE grain_version_id = %s",
            (self.active.id,),
        )
        self.assertEqual(self.cur.fetchone()[0], 1)

    def test_再実行しても結果が変わらない(self):
        """冪等性（docs/01 §4.3 の要件）。"""
        for i in range(4):
            self._post(*_offset(self.LAT, self.LON, i * 30, 0), self.users[i % 3])

        shadow = self._shadow()
        recalc.run_to_completion(self.cur, shadow)

        self.cur.execute(
            "SELECT count(*) FROM post_rarity_scores WHERE grain_version_id = %s", (shadow,)
        )
        first = self.cur.fetchone()[0]

        # ランを完了扱いのまま作り直して、もう一度通す
        self.cur.execute(
            "UPDATE grain_recalc_runs SET completed_at = NULL, phase = 'assign', "
            "cursor_post_id = NULL, processed_count = 0 WHERE grain_version_id = %s",
            (shadow,),
        )
        recalc.run_to_completion(self.cur, shadow)

        self.cur.execute(
            "SELECT count(*) FROM post_rarity_scores WHERE grain_version_id = %s", (shadow,)
        )
        self.assertEqual(self.cur.fetchone()[0], first, "行が二重にならない")

    def test_粒度を粗くすると分割が記録される(self):
        """split の判定（docs/01 §8.3 / T-16 からの持ち越し）。"""
        # active（res9）では1つのセルに収まり、shadow（res11）では分かれる配置
        a = self._post(self.LAT, self.LON, self.users[0])
        b = self._post(
            *_same_cell_far_point(self.LAT, self.LON, self.active.h3_resolution, 11),
            self.users[1],
        )

        self.cur.execute(
            "SELECT count(DISTINCT spot_id) FROM post_spot_assignment"
            " WHERE grain_version_id = %s AND post_id IN (%s, %s)",
            (self.active.id, a, b),
        )
        self.assertEqual(self.cur.fetchone()[0], 1, "前提: 旧粒度では同じスポット")

        shadow = self._shadow(resolution=11, snap_radius=20.0)
        summary = recalc.run_to_completion(self.cur, shadow)

        self.assertGreaterEqual(summary["split_recorded"], 2,
                                "1つの親が2つの子に散ったことが記録される")
        self.cur.execute(
            """
            SELECT count(*), sum(post_share) FROM spot_lineage
             WHERE to_grain_version_id = %s AND op = 'split'
            """,
            (shadow,),
        )
        count, share_total = self.cur.fetchone()
        self.assertEqual(count, 2)
        self.assertAlmostEqual(float(share_total), 1.0, places=3,
                               msg="親の投稿の配分が合計1になる")


class RarityRecomputeTest(RecalcBase):
    """②希少性の一括再計算（docs/01 §4.3 手順3・5）。"""

    def test_希少性が全投稿に付く(self):
        for i in range(3):
            self._post(*_offset(self.LAT, self.LON, i * 5, 0), self.users[i])

        count = recalc.recompute_rarity(self.cur, self.active.id)
        self.assertEqual(count, 3)

        self.cur.execute(
            "SELECT count(*) FROM post_rarity_scores WHERE grain_version_id = %s",
            (self.active.id,),
        )
        self.assertEqual(self.cur.fetchone()[0], 3)

    def test_同じスポットの後発ほど希少性が下がる(self):
        """対数逓減が実データに当たっていること。"""
        posts = [
            self._post(*_offset(self.LAT, self.LON, i * 5, 0), self.users[i % 3],
                       captured_offset_h=100 - i)
            for i in range(3)
        ]
        recalc.recompute_rarity(self.cur, self.active.id)

        self.cur.execute(
            """
            SELECT (breakdown ->> 'base')::numeric
              FROM post_rarity_scores WHERE post_id = ANY(%s) AND grain_version_id = %s
             ORDER BY (breakdown ->> 'spot_post_count')::int
            """,
            (posts, self.active.id),
        )
        bases = [row[0] for row in self.cur.fetchall()]
        self.assertEqual(len(bases), 3)
        self.assertTrue(bases[0] > bases[1] > bases[2], "累計が増えるほど base が下がる")

    def test_ファセットの初回だけに初ボーナスが出る(self):
        posts = [
            self._post(*_offset(self.LAT, self.LON, i * 5, 0), self.users[i % 3],
                       captured_offset_h=100 - i)
            for i in range(3)
        ]
        recalc.recompute_rarity(self.cur, self.active.id)

        self.cur.execute(
            """
            SELECT count(*) FROM post_rarity_scores
             WHERE grain_version_id = %s AND post_id = ANY(%s)
               AND (breakdown ->> 'first_combination')::numeric > 0
            """,
            (self.active.id, posts),
        )
        self.assertEqual(self.cur.fetchone()[0], 1,
                         "同じファセットで「初」は1件だけ")

    def test_方位不明の投稿には初ボーナスを出さない(self):
        """0012 の first_bonus_eligibility が効いていること（docs/01 §3.3）。"""
        post = self._post(self.LAT, self.LON, self.users[0], bearing=None)
        recalc.recompute_rarity(self.cur, self.active.id)

        self.cur.execute(
            "SELECT (breakdown ->> 'first_combination')::numeric"
            "  FROM post_rarity_scores WHERE post_id = %s",
            (post,),
        )
        self.assertEqual(self.cur.fetchone()[0], 0)

    def test_ファセット統計が作り直される(self):
        self._post(self.LAT, self.LON, self.users[0])
        recalc.recompute_rarity(self.cur, self.active.id)
        self.cur.execute(
            "SELECT count(*) FROM spot_facet_stats WHERE grain_version_id = %s",
            (self.active.id,),
        )
        self.assertEqual(self.cur.fetchone()[0], 1)

        # 2回目で二重にならない
        recalc.recompute_rarity(self.cur, self.active.id)
        self.cur.execute(
            "SELECT count(*) FROM spot_facet_stats WHERE grain_version_id = %s",
            (self.active.id,),
        )
        self.assertEqual(self.cur.fetchone()[0], 1)

    def test_配信中バージョンの希少性は直せる(self):
        """T-16 の持ち越し回収。スポットを動かさないので active でも安全。"""
        self._post(self.LAT, self.LON, self.users[0])
        count = recalc.recompute_rarity(self.cur, self.active.id)
        self.assertEqual(count, 1, "start_or_resume のガードには掛からない")


if __name__ == "__main__":
    unittest.main()
