"""スポット解決フロー（T-15）の検証。

実際の PostgreSQL + PostGIS に対して実行する。DB が設定されていなければスキップする
（scripts/test.sh と同じ判定）。

各テストはトランザクションを張ってロールバックするので、DBに痕跡を残さない。
"""

from __future__ import annotations

import math
import os
import unittest

_HAS_DB = bool(os.environ.get("DATABASE_URL") or os.environ.get("PGHOST"))

if _HAS_DB:
    from core import db, grain, h3util, spots


def _offset(lat: float, lon: float, north_m: float, east_m: float) -> tuple[float, float]:
    """メートル単位のずらし。テストデータの座標を作るためだけの近似。"""
    dlat = north_m / 111_320.0
    dlon = east_m / (111_320.0 * math.cos(math.radians(lat)))
    return lat + dlat, lon + dlon


def _point_in_neighbouring_cell(
    lat: float, lon: float, resolution: int, max_distance_m: float
) -> tuple[float, float]:
    """近いのにセルが違う点を探す。

    「セル境界で同一展望台が分割される」（docs/01 §1.2 手順4）を再現するために要る。
    res9 のセルは差し渡し400m程度あるので、境界をまたぐ点は決め打ちでは作れない。
    """
    origin_cell = h3util.cell_of(lat, lon, resolution)
    step = 10.0
    while step <= max_distance_m:
        for north, east in ((step, 0), (-step, 0), (0, step), (0, -step)):
            cand_lat, cand_lon = _offset(lat, lon, north, east)
            if h3util.cell_of(cand_lat, cand_lon, resolution) != origin_cell:
                return cand_lat, cand_lon
        step += 10.0
    raise AssertionError("隣接セルの点が見つからない。テストの前提が壊れている")


@unittest.skipUnless(_HAS_DB, "DATABASE_URL / PGHOST が未設定のためスキップ")
class SpotResolutionTest(unittest.TestCase):
    """docs/01 §1.2 の解決フロー。"""

    def setUp(self) -> None:
        self.conn = db.connect()
        self.cur = self.conn.cursor()
        self.grain = grain.load_active(self.cur)
        self.cur.execute(
            "INSERT INTO users (handle, display_name) VALUES (%s, %s) RETURNING id",
            (f"resolver-{os.urandom(4).hex()}", "解決フローのテスト"),
        )
        self.user_id = self.cur.fetchone()[0]

    def tearDown(self) -> None:
        self.conn.rollback()
        self.conn.close()

    def _new_post(self, lat, lon, *, accuracy=10.0, bearing=90.0):
        self.cur.execute(
            """
            INSERT INTO posts (author_id, status, captured_at, location,
                               gps_accuracy_m, bearing_deg, bearing_src)
            VALUES (%s, 'published', now(),
                    ST_SetSRID(ST_MakePoint(%s, %s), 4326)::geography, %s, %s,
                    CASE WHEN %s::real IS NULL THEN NULL ELSE 'true'::bearing_source END)
            RETURNING id
            """,
            (self.user_id, lon, lat, accuracy, bearing, bearing),
        )
        return self.cur.fetchone()[0]

    # -- POIに当たらない場合 -------------------------------------------------

    def test_POIに当たらない投稿は暫定セルスポットになる(self):
        lat, lon = 35.3606, 138.7274
        post = self._new_post(lat, lon)
        assignment = spots.bind_post(self.cur, post)

        self.assertEqual(assignment.binding.bind_method, "cell")
        self.cur.execute("SELECT kind, display_name FROM spots WHERE id = %s",
                         (assignment.binding.spot_id,))
        kind, display_name = self.cur.fetchone()
        self.assertEqual(kind, "h3_cell")
        self.assertIsNone(display_name, "暫定スポットに名前を付けない（docs/01 §1.4）")

    def test_同じセルの2件目は同じ暫定スポットに集まる(self):
        lat, lon = 35.3606, 138.7274
        first = spots.bind_post(self.cur, self._new_post(lat, lon))
        second_lat, second_lon = _offset(lat, lon, 20, 20)
        second = spots.bind_post(self.cur, self._new_post(second_lat, second_lon))

        self.assertEqual(first.binding.spot_id, second.binding.spot_id)

    # -- 吸着（docs/01 §1.2 手順4。セル境界問題への回答） -------------------

    def _make_poi_spot(self, lat, lon, name="◯◯展望台"):
        """命名済みの正規スポットを1つ置く。"""
        self.cur.execute(
            """
            SELECT upsert_spot_with_identity(
                %s, 'poi', %s, ST_SetSRID(ST_MakePoint(%s, %s), 4326)::geography,
                %s, 'poi', 'osm', %s, NULL, 'create')
            """,
            (
                self.grain.id,
                h3util.cell_of(lat, lon, self.grain.h3_resolution),
                lon,
                lat,
                name,
                f"node/{os.urandom(4).hex()}",
            ),
        )
        return self.cur.fetchone()[0]

    def test_セル境界をまたいでも吸着半径内なら同じスポットになる(self):
        """セル所属で決めていたら割れてしまうケース。"""
        lat, lon = 35.3606, 138.7274
        spot_id = self._make_poi_spot(lat, lon)

        other_lat, other_lon = _point_in_neighbouring_cell(
            lat, lon, self.grain.h3_resolution, self.grain.snap_radius_m
        )
        self.assertNotEqual(
            h3util.cell_of(lat, lon, self.grain.h3_resolution),
            h3util.cell_of(other_lat, other_lon, self.grain.h3_resolution),
            "前提: 2点は別セルにある",
        )

        assignment = spots.bind_post(self.cur, self._new_post(other_lat, other_lon))

        self.assertEqual(assignment.binding.spot_id, spot_id)
        self.assertEqual(assignment.binding.bind_method, "snap")
        self.assertLessEqual(assignment.binding.bind_distance_m, self.grain.snap_radius_m)

    def test_吸着半径を超えると別スポットになる(self):
        lat, lon = 35.3606, 138.7274
        spot_id = self._make_poi_spot(lat, lon)

        far_lat, far_lon = _offset(lat, lon, self.grain.snap_radius_m * 3, 0)
        assignment = spots.bind_post(self.cur, self._new_post(far_lat, far_lon))

        self.assertNotEqual(assignment.binding.spot_id, spot_id)
        self.assertEqual(assignment.binding.bind_method, "cell")

    # -- POIマッチ（ADR-001 で外部APIから自前テーブルに置き換え） -----------

    def _load_poi(self, lat, lon, name="富士見展望台", direction=250.0):
        self.cur.execute(
            """
            INSERT INTO poi_extract_versions (source_code, extract_url, extract_date, is_active)
            VALUES ('osm', 'https://example.invalid/japan.osm.pbf', DATE '2026-08-01', true)
            RETURNING id
            """
        )
        version_id = self.cur.fetchone()[0]
        self.cur.execute(
            """
            INSERT INTO poi_reference (extract_version_id, osm_type, osm_id, name, name_ja,
                                       category, direction_deg, location, tags)
            VALUES (%s, 'node', %s, %s, %s, 'viewpoint', %s,
                    ST_SetSRID(ST_MakePoint(%s, %s), 4326)::geography,
                    '{"tourism":"viewpoint"}'::jsonb)
            """,
            (version_id, 4242, name, name, direction, lon, lat),
        )
        return version_id

    def test_景観POIに一致すれば名前を継承する(self):
        lat, lon = 35.3606, 138.7274
        self._load_poi(lat, lon)

        assignment = spots.bind_post(self.cur, self._new_post(lat, lon))

        self.assertEqual(assignment.binding.bind_method, "poi")
        self.cur.execute(
            "SELECT kind, display_name, poi_source, poi_external_id FROM spots WHERE id = %s",
            (assignment.binding.spot_id,),
        )
        kind, display_name, source, external_id = self.cur.fetchone()
        self.assertEqual(kind, "poi")
        self.assertEqual(display_name, "富士見展望台")
        self.assertEqual(source, "osm", "出自が OSM として残る（ODbL のシェアアライク範囲の判別に要る）")
        self.assertEqual(external_id, "node/4242")

    def test_同じPOIに2件投稿してもスポットは1つしかできない(self):
        lat, lon = 35.3606, 138.7274
        self._load_poi(lat, lon)

        first = spots.bind_post(self.cur, self._new_post(lat, lon))
        second_lat, second_lon = _offset(lat, lon, 15, 0)
        second = spots.bind_post(self.cur, self._new_post(second_lat, second_lon))

        self.assertEqual(first.binding.spot_id, second.binding.spot_id)

    def test_抽出バージョンを指定すると当時のPOIを見る(self):
        """再計算の再現性（docs/06 §4.2）。"""
        lat, lon = 35.3606, 138.7274
        version_id = self._load_poi(lat, lon)

        assignment = spots.bind_post(
            self.cur, self._new_post(lat, lon), extract_version_id=version_id + 99
        )
        self.assertEqual(
            assignment.binding.bind_method, "cell",
            "存在しない抽出バージョンを指定すればPOIには当たらない",
        )

    # -- ファセットと信頼度 --------------------------------------------------

    def test_方位セクターが導出される(self):
        # 90度（東）は sector=2
        assignment = spots.bind_post(self.cur, self._new_post(35.3606, 138.7274, bearing=90.0))
        self.assertEqual(assignment.bearing_sector, 2)

    def test_方位不明は独立バケットになる(self):
        assignment = spots.bind_post(self.cur, self._new_post(35.3606, 138.7274, bearing=None))
        self.assertIsNone(
            assignment.bearing_sector, "方位不明は8セクターのどれにも混ぜない（docs/01 §2.2）"
        )

    def test_方位分割が無効なスポットでは方位を使わない(self):
        lat, lon = 35.3606, 138.7274
        spot_id = self._make_poi_spot(lat, lon)
        self.cur.execute("UPDATE spots SET bearing_split_enabled = false WHERE id = %s", (spot_id,))

        assignment = spots.bind_post(self.cur, self._new_post(lat, lon, bearing=90.0))
        self.assertIsNone(
            assignment.bearing_sector,
            "海岸線や一本道で椅子だけ増えるのを防ぐ（docs/01 §2.3）",
        )

    def test_測位が粗い投稿は低信頼として印を付ける(self):
        accuracy = self.grain.gps_accuracy_reject_m + 50
        assignment = spots.bind_post(
            self.cur, self._new_post(35.3606, 138.7274, accuracy=accuracy)
        )
        self.assertTrue(
            assignment.low_confidence, "「初」ボーナスの対象外にする（docs/01 §3.3）"
        )

    def test_低信頼の判定は呼び出し側が上書きできる(self):
        """trust_score の帯域を見た ingest が渡す（docs/04 SEC-TRUST-02）。"""
        assignment = spots.bind_post(
            self.cur, self._new_post(35.3606, 138.7274, accuracy=5.0), low_confidence=True
        )
        self.assertTrue(assignment.low_confidence)

    def test_位置の無い投稿は解決できない(self):
        self.cur.execute(
            "INSERT INTO posts (author_id, status, captured_at) VALUES (%s, 'pending', now())"
            " RETURNING id",
            (self.user_id,),
        )
        post = self.cur.fetchone()[0]
        with self.assertRaises(ValueError):
            spots.bind_post(self.cur, post)

    # -- 冪等性（docs/01 §4.3 の要件） --------------------------------------

    def test_同じ投稿を2回解決しても行もカウンタも増えない(self):
        lat, lon = 35.3606, 138.7274
        post = self._new_post(lat, lon)
        first = spots.bind_post(self.cur, post)
        second = spots.bind_post(self.cur, post)

        self.assertEqual(first.binding.spot_id, second.binding.spot_id)
        self.cur.execute(
            "SELECT count(*) FROM post_spot_assignment WHERE post_id = %s", (post,)
        )
        self.assertEqual(self.cur.fetchone()[0], 1)

        self.cur.execute(
            "SELECT post_count FROM spots WHERE id = %s", (first.binding.spot_id,)
        )
        self.assertEqual(self.cur.fetchone()[0], 1, "再解決でカウンタが二重に増えない")

    def test_カウンタが投稿数と投稿者数を反映する(self):
        lat, lon = 35.3606, 138.7274
        spots.bind_post(self.cur, self._new_post(lat, lon))
        spots.bind_post(self.cur, self._new_post(*_offset(lat, lon, 10, 10)))

        self.cur.execute(
            "INSERT INTO users (handle, display_name) VALUES (%s, %s) RETURNING id",
            (f"resolver2-{os.urandom(4).hex()}", "別の投稿者"),
        )
        other_user = self.cur.fetchone()[0]
        self.cur.execute(
            """
            INSERT INTO posts (author_id, status, captured_at, location, gps_accuracy_m)
            VALUES (%s, 'published', now(),
                    ST_SetSRID(ST_MakePoint(%s, %s), 4326)::geography, 10)
            RETURNING id
            """,
            (other_user, lon, lat),
        )
        assignment = spots.bind_post(self.cur, self.cur.fetchone()[0])

        self.cur.execute(
            "SELECT post_count, distinct_user_count FROM spots WHERE id = %s",
            (assignment.binding.spot_id,),
        )
        post_count, user_count = self.cur.fetchone()
        self.assertEqual(post_count, 3)
        self.assertEqual(user_count, 2, "希少性の対数逓減と v_grain_health が読む値")


@unittest.skipUnless(_HAS_DB, "DATABASE_URL / PGHOST が未設定のためスキップ")
class LineageTest(unittest.TestCase):
    """粒度を変えたときに永続IDを引き継ぐか（docs/01 §8.3 / 不変条件 I-4）。"""

    def setUp(self) -> None:
        self.conn = db.connect()
        self.cur = self.conn.cursor()
        self.active = grain.load_active(self.cur)
        self.cur.execute(
            "INSERT INTO users (handle, display_name) VALUES (%s, %s) RETURNING id",
            (f"lineage-{os.urandom(4).hex()}", "系譜のテスト"),
        )
        self.user_id = self.cur.fetchone()[0]

    def tearDown(self) -> None:
        self.conn.rollback()
        self.conn.close()

    def _shadow_grain(self, resolution=10, snap_radius=60.0):
        self.cur.execute(
            """
            INSERT INTO spot_grain_versions (
                code, status, h3_resolution, snap_radius_m, poi_match_radius_m,
                bearing_sector_count, dbscan_eps_m, dbscan_min_points, dbscan_min_users,
                gps_accuracy_reject_m
            ) VALUES (%s, 'shadow', %s, %s, 150, 8, 50, 5, 3, 100)
            RETURNING id
            """,
            (f"g-shadow-{os.urandom(3).hex()}", resolution, snap_radius),
        )
        return self.cur.fetchone()[0]

    def _post(self, lat, lon):
        self.cur.execute(
            """
            INSERT INTO posts (author_id, status, captured_at, location, gps_accuracy_m)
            VALUES (%s, 'published', now(),
                    ST_SetSRID(ST_MakePoint(%s, %s), 4326)::geography, 10)
            RETURNING id
            """,
            (self.user_id, lon, lat),
        )
        return self.cur.fetchone()[0]

    def test_新しい粒度でも同じ場所なら永続IDを引き継ぐ(self):
        lat, lon = 35.3606, 138.7274
        post = self._post(lat, lon)
        old = spots.bind_post(self.cur, post)

        shadow_id = self._shadow_grain()
        new = spots.bind_post(self.cur, post, grain_version_id=shadow_id)

        self.assertNotEqual(old.binding.spot_id, new.binding.spot_id,
                            "実体は粒度バージョンごとに別（不変条件 I-2）")
        self.assertEqual(old.binding.identity_id, new.binding.identity_id,
                         "永続IDは引き継がれる。切れるとURLと称号が死ぬ（不変条件 I-4）")

        self.cur.execute(
            "SELECT op FROM spot_lineage WHERE to_grain_version_id = %s AND child_identity_id = %s",
            (shadow_id, new.binding.identity_id),
        )
        self.assertEqual(self.cur.fetchone()[0], "carry_over")

    def test_引き継いだ永続IDはURLとして解決できる(self):
        lat, lon = 35.3606, 138.7274
        post = self._post(lat, lon)
        old = spots.bind_post(self.cur, post)

        self.cur.execute("SELECT slug FROM spot_identity WHERE id = %s", (old.binding.identity_id,))
        slug = self.cur.fetchone()[0]

        shadow_id = self._shadow_grain()
        spots.bind_post(self.cur, post, grain_version_id=shadow_id)

        self.cur.execute("SELECT resolve_spot_slug(%s)", (slug,))
        self.assertEqual(self.cur.fetchone()[0], old.binding.identity_id,
                         "粒度を変えても同じURLが同じスポットを指す（T-01 の完了条件）")

    def test_遠く離れた場所には新しい永続IDを発行する(self):
        first = spots.bind_post(self.cur, self._post(35.3606, 138.7274))

        shadow_id = self._shadow_grain()
        far_lat, far_lon = _offset(35.3606, 138.7274, 5000, 0)
        second = spots.bind_post(self.cur, self._post(far_lat, far_lon),
                                 grain_version_id=shadow_id)

        self.assertNotEqual(first.binding.identity_id, second.binding.identity_id)
        self.cur.execute(
            "SELECT op FROM spot_lineage WHERE child_identity_id = %s", (second.binding.identity_id,)
        )
        self.assertEqual(self.cur.fetchone()[0], "create")

    def test_粗い粒度で2つのスポットが1つに寄る(self):
        """粒度を粗くしたときの merge（docs/01 §8.3）。"""
        lat, lon = 35.3606, 138.7274
        a = spots.bind_post(self.cur, self._post(lat, lon))
        b_lat, b_lon = _offset(lat, lon, 400, 0)
        b = spots.bind_post(self.cur, self._post(b_lat, b_lon))
        self.assertNotEqual(a.binding.identity_id, b.binding.identity_id, "前提: 別スポット")

        # 吸着半径を大きく取った粒度では、両方が候補に入る
        coarse_id = self._shadow_grain(resolution=8, snap_radius=800.0)
        mid_lat, mid_lon = _offset(lat, lon, 200, 0)
        merged = spots.bind_post(self.cur, self._post(mid_lat, mid_lon),
                                 grain_version_id=coarse_id)

        self.cur.execute(
            "SELECT op FROM spot_lineage WHERE to_grain_version_id = %s AND child_identity_id = %s",
            (coarse_id, merged.binding.identity_id),
        )
        self.assertEqual(self.cur.fetchone()[0], "merge")
        self.assertIn(
            merged.binding.identity_id,
            (a.binding.identity_id, b.binding.identity_id),
            "統合先はどちらかの既存の永続ID。新規発行するとURLが切れる",
        )


if __name__ == "__main__":
    unittest.main()
