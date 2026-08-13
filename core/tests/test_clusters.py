"""DBSCAN昇格（T-16）の検証。

docs/01 §1.3。実際の PostgreSQL + PostGIS に対して実行し、
各テストはトランザクションをロールバックする。
"""

from __future__ import annotations

import math
import os
import unittest

_HAS_DB = bool(os.environ.get("DATABASE_URL") or os.environ.get("PGHOST"))

if _HAS_DB:
    from core import clusters, db, grain, spots
    from core.clusters import Candidate


def _offset(lat: float, lon: float, north_m: float, east_m: float) -> tuple[float, float]:
    dlat = north_m / 111_320.0
    dlon = east_m / (111_320.0 * math.cos(math.radians(lat)))
    return lat + dlat, lon + dlon


def _noise_point(lat: float, lon: float, resolution: int, min_distance_m: float):
    """eps より遠いが、同じ H3 セルには収まる点を探す。

    「ノイズ点は暫定セルに残る」を検証するには、クラスタから外れていて、
    かつ同じ暫定セルスポットに属している必要がある。res9 のセルは差し渡し
    400m 程度しかないので、決め打ちだと隣のセルに出てしまう。
    """
    from core import h3util

    origin = h3util.cell_of(lat, lon, resolution)
    distance = min_distance_m * 1.2
    while distance < min_distance_m * 3:
        for north, east in ((distance, 0), (0, distance), (-distance, 0), (0, -distance)):
            cand = _offset(lat, lon, north, east)
            if h3util.cell_of(cand[0], cand[1], resolution) == origin:
                return cand
        distance += min_distance_m * 0.2
    raise AssertionError("同じセル内でクラスタから外れる点が見つからない")


class DbscanAlgorithmTest(unittest.TestCase):
    """近傍集合の与え方に依らないアルゴリズム部分。DBは要らない。"""

    def _candidates(self, n: int) -> list:
        from uuid import uuid4

        cls = Candidate if _HAS_DB else None
        if cls is None:
            self.skipTest("core をインポートできない")
        return [cls(uuid4(), uuid4(), uuid4(), 0.0, 0.0) for _ in range(n)]

    @unittest.skipUnless(_HAS_DB, "core をインポートできないためスキップ")
    def test_密度が足りなければクラスタにならない(self):
        cands = self._candidates(4)
        ids = [c.post_id for c in cands]
        # 全点が相互に近傍でも、4点では minPts=5 に届かない
        neighbours = {i: set(ids) - {i} for i in ids}
        self.assertEqual(clusters.dbscan(cands, neighbours, 5), [])

    @unittest.skipUnless(_HAS_DB, "core をインポートできないためスキップ")
    def test_コア点から到達できる点だけがクラスタに入る(self):
        cands = self._candidates(6)
        ids = [c.post_id for c in cands]
        core_group = set(ids[:5])
        neighbours = {i: (core_group - {i}) for i in ids[:5]}
        # 6点目はどこからも遠い
        neighbours[ids[5]] = set()

        result = clusters.dbscan(cands, neighbours, 5)
        self.assertEqual(len(result), 1)
        self.assertEqual({m.post_id for m in result[0]}, core_group)

    @unittest.skipUnless(_HAS_DB, "core をインポートできないためスキップ")
    def test_境界点から先へは広げない(self):
        """まばらな点が数珠つなぎになって峠一帯が1スポットになるのを防ぐ。"""
        cands = self._candidates(7)
        ids = [c.post_id for c in cands]
        core = set(ids[:5])
        border = ids[5]
        outsider = ids[6]

        neighbours = {i: (core - {i}) | {border} for i in ids[:5]}
        # 境界点はコア点の近傍だが、自身はコア点ではない（近傍が2つしかない）
        neighbours[border] = {ids[0], outsider}
        neighbours[outsider] = {border}

        result = clusters.dbscan(cands, neighbours, 5)
        self.assertEqual(len(result), 1)
        members = {m.post_id for m in result[0]}
        self.assertIn(border, members, "境界点はクラスタに入る")
        self.assertNotIn(outsider, members, "境界点の先までは広げない")


@unittest.skipUnless(_HAS_DB, "DATABASE_URL / PGHOST が未設定のためスキップ")
class PromotionTest(unittest.TestCase):
    """暫定セル → 独自スポットの昇格（docs/01 §1.3 手順3〜6）。"""

    LAT, LON = 35.3606, 138.7274

    def setUp(self) -> None:
        self.conn = db.connect()
        self.cur = self.conn.cursor()
        self.grain = grain.load_active(self.cur)
        self.users = []
        for i in range(4):
            self.cur.execute(
                "INSERT INTO users (handle, display_name) VALUES (%s, %s) RETURNING id",
                (f"cluster-{os.urandom(4).hex()}", f"昇格テスト{i}"),
            )
            self.users.append(self.cur.fetchone()[0])

    def tearDown(self) -> None:
        self.conn.rollback()
        self.conn.close()

    def _post_at(self, lat, lon, author, accuracy=10.0):
        self.cur.execute(
            """
            INSERT INTO posts (author_id, status, captured_at, location, gps_accuracy_m)
            VALUES (%s, 'published', now(),
                    ST_SetSRID(ST_MakePoint(%s, %s), 4326)::geography, %s)
            RETURNING id
            """,
            (author, lon, lat, accuracy),
        )
        post_id = self.cur.fetchone()[0]
        return spots.bind_post(self.cur, post_id)

    def _tight_cluster(self, n=6, authors=3, spread_m=20.0, accuracy=10.0):
        """半径 spread_m 以内に n 件を置く。"""
        result = []
        for i in range(n):
            lat, lon = _offset(self.LAT, self.LON, (i % 3) * spread_m / 3, (i % 2) * spread_m / 3)
            result.append(self._post_at(lat, lon, self.users[i % authors], accuracy))
        return result

    def test_密集した投稿が独自スポットに昇格する(self):
        assignments = self._tight_cluster()
        cell_spot_id = assignments[0].binding.spot_id

        promotions = clusters.promote_cell_spot(self.cur, self.grain, cell_spot_id)

        self.assertEqual(len(promotions), 1)
        promotion = promotions[0]
        self.assertEqual(promotion.moved_post_count, 6)
        self.assertEqual(promotion.distinct_author_count, 3)

        self.cur.execute("SELECT kind FROM spots WHERE id = %s", (promotion.cluster_spot_id,))
        self.assertEqual(self.cur.fetchone()[0], "cluster")

    def test_昇格すると投稿の紐付けが張り替わる(self):
        assignments = self._tight_cluster()
        cell_spot_id = assignments[0].binding.spot_id
        promotion = clusters.promote_cell_spot(self.cur, self.grain, cell_spot_id)[0]

        self.cur.execute(
            """
            SELECT count(*) FROM post_spot_assignment
             WHERE spot_id = %s AND bind_method = 'cluster'
            """,
            (promotion.cluster_spot_id,),
        )
        self.assertEqual(self.cur.fetchone()[0], 6)

    def test_昇格スポットは以後の吸着候補になる(self):
        """docs/01 §1.3 の「以後その場所の投稿はセル境界に関係なく同じスポットに集まる」。"""
        assignments = self._tight_cluster()
        promotion = clusters.promote_cell_spot(
            self.cur, self.grain, assignments[0].binding.spot_id
        )[0]

        later = self._post_at(*_offset(self.LAT, self.LON, 30, 0), self.users[0])
        self.assertEqual(later.binding.spot_id, promotion.cluster_spot_id)
        self.assertEqual(later.binding.bind_method, "snap")

    def test_1人の連投では昇格しない(self):
        """dbscan_min_users。これが無いと自分専用スポットが量産される。"""
        assignments = self._tight_cluster(n=8, authors=1)
        promotions = clusters.promote_cell_spot(
            self.cur, self.grain, assignments[0].binding.spot_id
        )
        self.assertEqual(promotions, [])

    def test_件数が足りなければ昇格しない(self):
        assignments = self._tight_cluster(n=3, authors=3)
        promotions = clusters.promote_cell_spot(
            self.cur, self.grain, assignments[0].binding.spot_id
        )
        self.assertEqual(promotions, [])

    def test_測位の粗い投稿はクラスタ判定に使わない(self):
        """重心がぶれるため（docs/01 §1.3 手順1）。"""
        accuracy = self.grain.gps_accuracy_reject_m + 50
        assignments = self._tight_cluster(n=8, authors=3, accuracy=accuracy)
        promotions = clusters.promote_cell_spot(
            self.cur, self.grain, assignments[0].binding.spot_id
        )
        self.assertEqual(promotions, [])

    def test_離れた投稿はノイズとして暫定セルに残る(self):
        """docs/01 §1.3 手順5。"""
        assignments = self._tight_cluster()
        cell_spot_id = assignments[0].binding.spot_id

        # eps の3倍離れた点。同じセル内だがクラスタには入らない
        far = self._post_at(
            *_noise_point(self.LAT, self.LON, self.grain.h3_resolution, self.grain.dbscan_eps_m),
            self.users[0],
        )
        self.assertEqual(far.binding.spot_id, cell_spot_id, "前提: 同じ暫定セルにいる")

        clusters.promote_cell_spot(self.cur, self.grain, cell_spot_id)

        self.cur.execute(
            "SELECT spot_id, bind_method FROM post_spot_assignment WHERE post_id = %s",
            (far.post_id,),
        )
        spot_id, method = self.cur.fetchone()
        self.assertEqual(spot_id, cell_spot_id, "ノイズ点は暫定セルに残る")
        self.assertEqual(method, "cell")

    def test_カウンタが張り替え後の実態に合う(self):
        assignments = self._tight_cluster()
        cell_spot_id = assignments[0].binding.spot_id
        far = self._post_at(
            *_noise_point(self.LAT, self.LON, self.grain.h3_resolution, self.grain.dbscan_eps_m),
            self.users[0],
        )
        self.assertEqual(far.binding.spot_id, cell_spot_id)

        promotion = clusters.promote_cell_spot(self.cur, self.grain, cell_spot_id)[0]

        self.cur.execute("SELECT post_count FROM spots WHERE id = %s", (promotion.cluster_spot_id,))
        self.assertEqual(self.cur.fetchone()[0], 6, "昇格スポットのカウンタ")
        self.cur.execute("SELECT post_count FROM spots WHERE id = %s", (cell_spot_id,))
        self.assertEqual(self.cur.fetchone()[0], 1, "元のセルにはノイズ点だけ残る")

    def test_最多投稿者に命名権が渡る(self):
        """docs/01 §1.3 手順6。通知そのものは T-27。"""
        for _ in range(4):
            self._post_at(self.LAT, self.LON, self.users[0])
        assignment = self._post_at(*_offset(self.LAT, self.LON, 10, 0), self.users[1])
        self._post_at(*_offset(self.LAT, self.LON, 0, 10), self.users[2])

        promotion = clusters.promote_cell_spot(
            self.cur, self.grain, assignment.binding.spot_id
        )[0]
        self.assertEqual(promotion.top_contributor_id, self.users[0])

    def test_昇格スポットは未命名のまま作られる(self):
        """逆ジオコーディングの出所が未確定なので、暫定名を勝手に付けない（docs/06 §6）。"""
        assignments = self._tight_cluster()
        promotion = clusters.promote_cell_spot(
            self.cur, self.grain, assignments[0].binding.spot_id
        )[0]
        self.cur.execute(
            "SELECT display_name FROM spots WHERE id = %s", (promotion.cluster_spot_id,)
        )
        self.assertIsNone(self.cur.fetchone()[0])

    # -- 永続IDと系譜（不変条件 I-4） ---------------------------------------

    def test_昇格スポットは新しい永続IDを持ち系譜が残る(self):
        assignments = self._tight_cluster()
        cell_spot_id = assignments[0].binding.spot_id
        self.cur.execute("SELECT identity_id FROM spots WHERE id = %s", (cell_spot_id,))
        cell_identity = self.cur.fetchone()[0]

        # ノイズ点を1つ残して、元セルが空にならないようにする
        self._post_at(
            *_noise_point(self.LAT, self.LON, self.grain.h3_resolution, self.grain.dbscan_eps_m),
            self.users[0],
        )

        promotion = clusters.promote_cell_spot(self.cur, self.grain, cell_spot_id)[0]

        self.assertNotEqual(promotion.cluster_identity_id, cell_identity,
                            "同一粒度では identity を再利用できない（spots_identity_uix）")
        self.cur.execute(
            """
            SELECT op, parent_identity_id, moved_post_count
              FROM spot_lineage WHERE child_identity_id = %s
            """,
            (promotion.cluster_identity_id,),
        )
        op, parent, moved = self.cur.fetchone()
        self.assertEqual(op, "split")
        self.assertEqual(parent, cell_identity, "どのセルから生えたかを残す（称号の継承判断に要る）")
        self.assertEqual(moved, 6)

    def test_セルが空になったら旧URLを昇格スポットへ向ける(self):
        """「この付近」のURLが既に配られている可能性があるので死なせない。"""
        assignments = self._tight_cluster()
        cell_spot_id = assignments[0].binding.spot_id
        self.cur.execute(
            "SELECT identity_id, (SELECT slug FROM spot_identity WHERE id = identity_id)"
            "  FROM spots WHERE id = %s",
            (cell_spot_id,),
        )
        cell_identity, cell_slug = self.cur.fetchone()

        promotion = clusters.promote_cell_spot(self.cur, self.grain, cell_spot_id)[0]

        self.assertEqual(promotion.lineage_op, "merge")
        self.cur.execute("SELECT resolve_spot_slug(%s)", (cell_slug,))
        self.assertEqual(self.cur.fetchone()[0], promotion.cluster_identity_id,
                         "旧 slug が昇格スポットに解決する")
        self.cur.execute("SELECT status FROM spot_identity WHERE id = %s", (cell_identity,))
        self.assertEqual(self.cur.fetchone()[0], "merged")

    # -- バッチの走査 --------------------------------------------------------

    def test_昇格が起きたセルにだけ印が付く(self):
        assignments = self._tight_cluster()
        cell_spot_id = assignments[0].binding.spot_id
        clusters.promote_cell_spot(self.cur, self.grain, cell_spot_id)

        self.cur.execute("SELECT promoted_at FROM spots WHERE id = %s", (cell_spot_id,))
        self.assertIsNotNone(self.cur.fetchone()[0])

    def test_昇格しなかったセルは次回また評価される(self):
        assignments = self._tight_cluster(n=8, authors=1)
        cell_spot_id = assignments[0].binding.spot_id
        clusters.promote_cell_spot(self.cur, self.grain, cell_spot_id)

        self.cur.execute("SELECT promoted_at FROM spots WHERE id = %s", (cell_spot_id,))
        self.assertIsNone(self.cur.fetchone()[0],
                          "投稿者が増えれば昇格しうるので、印を付けて締め切らない")

    def test_走査は対象セルを拾って昇格させる(self):
        self._tight_cluster()
        promotions = clusters.promote_pending(self.cur, self.grain)
        self.assertGreaterEqual(len(promotions), 1)

    def test_走査は冪等(self):
        self._tight_cluster()
        first = clusters.promote_pending(self.cur, self.grain)
        second = clusters.promote_pending(self.cur, self.grain)
        self.assertGreaterEqual(len(first), 1)
        self.assertEqual(second, [], "2回目は昇格対象が残らない")


if __name__ == "__main__":
    unittest.main()
