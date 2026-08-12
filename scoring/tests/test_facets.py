"""facets.py の仕様テスト。

    python3 -m unittest discover -s scoring/tests -v
"""

import math
import sys
import unittest
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from scoring.facets import (  # noqa: E402
    Season,
    Timeslot,
    bearing_sector,
    circular_variance,
    fractal_preference,
    season_of,
    sector_label,
    should_split_by_bearing,
    sun_events,
    timeslot_of,
)

JST = timezone(timedelta(hours=9))

# 富士山五合目付近（日本の代表的な景観スポットとして）
FUJI_LAT, FUJI_LON = 35.3606, 138.7274


class TestBearingSector(unittest.TestCase):
    def test_north_is_centered_on_sector_zero(self):
        """セクター0(N)は境界ではなく中心に真北が来る。"""
        self.assertEqual(bearing_sector(0.0), 0)
        self.assertEqual(bearing_sector(359.9), 0)
        self.assertEqual(bearing_sector(22.4), 0)
        self.assertEqual(bearing_sector(337.5), 0)

    def test_sector_boundaries(self):
        self.assertEqual(bearing_sector(22.5), 1)   # NE の始まり
        self.assertEqual(bearing_sector(45.0), 1)   # NE の中心
        self.assertEqual(bearing_sector(90.0), 2)   # E
        self.assertEqual(bearing_sector(180.0), 4)  # S
        self.assertEqual(bearing_sector(270.0), 6)  # W

    def test_all_sectors_reachable_and_in_range(self):
        seen = {bearing_sector(float(b)) for b in range(0, 360)}
        self.assertEqual(seen, set(range(8)))

    def test_four_sector_mode(self):
        self.assertEqual(bearing_sector(0.0, 4), 0)
        self.assertEqual(bearing_sector(90.0, 4), 1)
        self.assertEqual(bearing_sector(180.0, 4), 2)
        self.assertEqual(bearing_sector(270.0, 4), 3)
        self.assertEqual(bearing_sector(315.0, 4), 0)

    def test_unknown_bearing_stays_unknown(self):
        """方位不明は None のまま。他のセクターに混ぜない（docs/01 §2.2）。"""
        self.assertIsNone(bearing_sector(None))
        self.assertEqual(sector_label(None), "方位不明")

    def test_invalid_sector_count_rejected(self):
        with self.assertRaises(ValueError):
            bearing_sector(0.0, 7)


class TestBearingSplitDecision(unittest.TestCase):
    def test_uniform_bearings_have_high_variance(self):
        bearings = [float(b) for b in range(0, 360, 10)]
        self.assertGreater(circular_variance(bearings), 0.9)

    def test_single_direction_has_near_zero_variance(self):
        """海岸線の展望台のように方位が固定されているケース。"""
        bearings = [178.0, 180.0, 182.0, 179.0, 181.0]
        self.assertLess(circular_variance(bearings), 0.01)

    def test_variance_handles_wraparound(self):
        """真北付近（359度と1度）が「離れている」と誤判定されない。"""
        bearings = [359.0, 0.0, 1.0, 358.0, 2.0]
        self.assertLess(circular_variance(bearings), 0.01)

    def test_split_disabled_for_fixed_direction_spot(self):
        bearings = [180.0 + (i % 5) for i in range(25)]
        self.assertFalse(should_split_by_bearing(bearings))

    def test_split_kept_when_samples_are_few(self):
        """サンプル不足のうちは判断を保留して分割を維持する。"""
        self.assertTrue(should_split_by_bearing([180.0, 181.0]))

    def test_split_enabled_for_panoramic_spot(self):
        bearings = [float(b) for b in range(0, 360, 15)]
        self.assertTrue(should_split_by_bearing(bearings))


class TestSeason(unittest.TestCase):
    def test_month_mapping(self):
        cases = {
            1: Season.WINTER, 2: Season.WINTER, 3: Season.SPRING,
            5: Season.SPRING, 6: Season.SUMMER, 8: Season.SUMMER,
            9: Season.AUTUMN, 11: Season.AUTUMN, 12: Season.WINTER,
        }
        for month, expected in cases.items():
            with self.subTest(month=month):
                self.assertEqual(season_of(datetime(2026, month, 15, tzinfo=JST)), expected)


class TestSunEvents(unittest.TestCase):
    def test_fuji_summer_solstice(self):
        """夏至の富士山周辺: 日出は概ね 4:25 JST、日没は 19:00 JST 前後。"""
        events = sun_events(date(2026, 6, 21), FUJI_LAT, FUJI_LON)
        self.assertIsNotNone(events)
        sunrise, sunset = events
        sr, ss = sunrise.astimezone(JST), sunset.astimezone(JST)
        self.assertEqual(sr.hour, 4)
        self.assertTrue(15 <= sr.minute <= 40, f"日出 {sr}")
        self.assertEqual(ss.hour, 19)
        self.assertTrue(0 <= ss.minute <= 20, f"日没 {ss}")

    def test_fuji_winter_solstice(self):
        """冬至: 日出は概ね 6:50 JST、日没は 16:35 JST 前後。"""
        events = sun_events(date(2026, 12, 21), FUJI_LAT, FUJI_LON)
        self.assertIsNotNone(events)
        sunrise, sunset = events
        sr, ss = sunrise.astimezone(JST), sunset.astimezone(JST)
        self.assertEqual(sr.hour, 6)
        self.assertEqual(ss.hour, 16)

    def test_daylight_is_longer_in_summer(self):
        summer = sun_events(date(2026, 6, 21), FUJI_LAT, FUJI_LON)
        winter = sun_events(date(2026, 12, 21), FUJI_LAT, FUJI_LON)
        self.assertGreater(summer[1] - summer[0], winter[1] - winter[0])

    def test_polar_night_returns_none(self):
        """北緯78度の冬至は極夜。"""
        self.assertIsNone(sun_events(date(2026, 12, 21), 78.0, 15.0))


class TestTimeslot(unittest.TestCase):
    def _slot(self, y, mo, d, h, mi=0):
        return timeslot_of(datetime(y, mo, d, h, mi, tzinfo=JST), FUJI_LAT, FUJI_LON)

    def test_dawn_shifts_with_season(self):
        """同じ「朝焼け」でも夏と冬で2時間ずれる。固定時刻で切ってはいけない理由。"""
        # 夏至: 日出 4:25 頃 → 4:00 は dawn
        self.assertEqual(self._slot(2026, 6, 21, 4, 0), Timeslot.DAWN)
        # 冬至: 日出 6:50 頃 → 4:00 はまだ night
        self.assertEqual(self._slot(2026, 12, 21, 4, 0), Timeslot.NIGHT)
        # 冬至の dawn は 6:20 頃
        self.assertEqual(self._slot(2026, 12, 21, 6, 20), Timeslot.DAWN)

    def test_summer_and_winter_dawn_are_both_dawn(self):
        """季節が違っても「日出直前」は同じ dawn バケットに入る。"""
        self.assertEqual(self._slot(2026, 6, 21, 4, 0), Timeslot.DAWN)
        self.assertEqual(self._slot(2026, 12, 21, 6, 20), Timeslot.DAWN)

    def test_morning_after_sunrise(self):
        self.assertEqual(self._slot(2026, 6, 21, 5, 30), Timeslot.MORNING)

    def test_noon_is_the_fallback(self):
        self.assertEqual(self._slot(2026, 6, 21, 12, 0), Timeslot.NOON)

    def test_golden_before_sunset(self):
        # 夏至の日没は 19:00 頃 → 18:30 は golden
        self.assertEqual(self._slot(2026, 6, 21, 18, 30), Timeslot.GOLDEN)

    def test_dusk_after_sunset(self):
        self.assertEqual(self._slot(2026, 6, 21, 19, 20), Timeslot.DUSK)

    def test_night_after_dusk(self):
        self.assertEqual(self._slot(2026, 6, 21, 23, 0), Timeslot.NIGHT)

    def test_night_across_midnight(self):
        """日付境界をまたいでも night は night のまま（前日の日没を参照する）。"""
        self.assertEqual(self._slot(2026, 6, 22, 1, 0), Timeslot.NIGHT)

    def test_naive_datetime_rejected(self):
        with self.assertRaises(ValueError):
            timeslot_of(datetime(2026, 6, 21, 12, 0), FUJI_LAT, FUJI_LON)

    def test_every_hour_of_the_year_is_classified(self):
        """どの時刻でも必ずどれかのバケットに落ちる（NULL漏れがない）。"""
        d = datetime(2026, 1, 1, 0, 0, tzinfo=JST)
        for _ in range(0, 366 * 24, 7):
            slot = timeslot_of(d, FUJI_LAT, FUJI_LON)
            self.assertIsInstance(slot, Timeslot)
            d += timedelta(hours=7)


class TestFractalPreference(unittest.TestCase):
    def test_peak_at_1_4(self):
        self.assertAlmostEqual(fractal_preference(1.40), 1.0, places=6)

    def test_preferred_band_stays_high(self):
        """D = 1.3〜1.5 は一貫して高い選好を示す（Spehar et al. 2003）。"""
        for d in (1.30, 1.35, 1.45, 1.50):
            with self.subTest(d=d):
                self.assertGreater(fractal_preference(d), 0.70)

    def test_low_and_high_bands_are_penalized(self):
        """D = 1.1〜1.2 および 1.6〜1.9 では選好が低い。"""
        for d in (1.10, 1.20, 1.70, 1.90):
            with self.subTest(d=d):
                self.assertLess(fractal_preference(d), 0.45)

    def test_monotone_falloff_on_both_sides(self):
        self.assertGreater(fractal_preference(1.35), fractal_preference(1.20))
        self.assertGreater(fractal_preference(1.45), fractal_preference(1.60))

    def test_symmetry_around_peak(self):
        self.assertAlmostEqual(fractal_preference(1.25), fractal_preference(1.55), places=6)

    def test_output_is_bounded(self):
        for d in [x / 100 for x in range(100, 200)]:
            self.assertTrue(0.0 <= fractal_preference(d) <= 1.0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
