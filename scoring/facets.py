"""ファセットキーの導出規則。

docs/01-spot-granularity.md §2（方位セクター）と §3.1（時間帯・季節）の
仕様を実行可能な形で固定したもの。ingest ワーカーがここを呼び、
結果を post_spot_assignment.bearing_sector と posts.timeslot / posts.season に入れる。

依存は標準ライブラリのみ。ここを外部ライブラリに依存させると、
DBの再計算ジョブ（docs/01 §4.3）から呼びにくくなる。
"""

from __future__ import annotations

import math
from datetime import date, datetime, timedelta, timezone
from enum import Enum

__all__ = [
    "Timeslot",
    "Season",
    "bearing_sector",
    "sector_label",
    "circular_variance",
    "should_split_by_bearing",
    "season_of",
    "sun_events",
    "timeslot_of",
    "fractal_preference",
]


class Timeslot(str, Enum):
    DAWN = "dawn"
    MORNING = "morning"
    NOON = "noon"
    GOLDEN = "golden"
    DUSK = "dusk"
    NIGHT = "night"


class Season(str, Enum):
    SPRING = "spring"
    SUMMER = "summer"
    AUTUMN = "autumn"
    WINTER = "winter"


# ---------------------------------------------------------------------------
# 方位セクター（docs/01 §2）
# ---------------------------------------------------------------------------

_SECTOR_LABELS_8 = ("N", "NE", "E", "SE", "S", "SW", "W", "NW")
_SECTOR_LABELS_4 = ("N", "E", "S", "W")


def bearing_sector(bearing_deg: float | None, sector_count: int = 8) -> int | None:
    """方位角をセクター番号に落とす。

    セクターの「中心」が主要方位に来るようにオフセットする。
    sector_count=8 なら 0=N は 337.5°〜22.5° の範囲になる。

    None（方位が取得できなかった）はそのまま None を返す。呼び出し側は
    これを「不明」という独立バケットとして扱い、「初」ボーナスを出さないこと。
    """
    if bearing_deg is None:
        return None
    if sector_count not in (4, 8, 16):
        raise ValueError(f"sector_count must be 4, 8 or 16 (got {sector_count})")

    step = 360.0 / sector_count
    half = step / 2.0
    return int(((bearing_deg + half) % 360.0) // step)


def sector_label(sector: int | None, sector_count: int = 8) -> str:
    """表示用のラベル。「北向き部門」のような文言を組み立てるのに使う。"""
    if sector is None:
        return "方位不明"
    if sector_count == 8:
        return _SECTOR_LABELS_8[sector]
    if sector_count == 4:
        return _SECTOR_LABELS_4[sector]
    return f"S{sector}"


def circular_variance(bearings: list[float]) -> float:
    """方位の円周分散を 0.0（完全に一方向）〜1.0（一様）で返す。

    docs/01 §2.3: 海岸線や一本道の展望台では方位が実質固定になるため、
    方位で分割しても「椅子」が増えず希少性だけが水増しされる。
    投稿が溜まった時点でこの値を見て bearing_split_enabled を落とす。
    """
    if not bearings:
        return 1.0
    xs = sum(math.cos(math.radians(b)) for b in bearings)
    ys = sum(math.sin(math.radians(b)) for b in bearings)
    r = math.hypot(xs, ys) / len(bearings)
    return 1.0 - r


def should_split_by_bearing(
    bearings: list[float],
    min_samples: int = 20,
    variance_threshold: float = 0.35,
) -> bool:
    """このスポットで方位分割を有効にすべきか。

    サンプルが足りないうちは判断を保留して有効のままにする（True）。
    """
    usable = [b for b in bearings if b is not None]
    if len(usable) < min_samples:
        return True
    return circular_variance(usable) >= variance_threshold


# ---------------------------------------------------------------------------
# 季節（docs/01 §3.1）
# ---------------------------------------------------------------------------

_SEASON_BY_MONTH = {
    3: Season.SPRING, 4: Season.SPRING, 5: Season.SPRING,
    6: Season.SUMMER, 7: Season.SUMMER, 8: Season.SUMMER,
    9: Season.AUTUMN, 10: Season.AUTUMN, 11: Season.AUTUMN,
    12: Season.WINTER, 1: Season.WINTER, 2: Season.WINTER,
}


def season_of(local_dt: datetime) -> Season:
    """撮影地のローカル時刻から季節を決める。

    月ベース。日本を主対象とするため南半球の反転は行っていない。
    海外展開時はここに緯度による分岐を入れること。
    """
    return _SEASON_BY_MONTH[local_dt.month]


# ---------------------------------------------------------------------------
# 日出・日没（時間帯バケットの基準）
# ---------------------------------------------------------------------------
# docs/01 §3.1: timeslot を固定時刻で切ってはいけない。
# 「朝焼け部門」は夏と冬で2時間ずれるため、日出・日没からの相対で決める。

_ZENITH_DEG = -0.833  # 大気差と太陽視半径を含めた見かけの日出・日没高度


def _to_julian(dt_utc: datetime) -> float:
    ts = dt_utc.replace(tzinfo=timezone.utc).timestamp()
    return ts / 86400.0 + 2440587.5


def _from_julian(jd: float) -> datetime:
    ts = (jd - 2440587.5) * 86400.0
    return datetime.fromtimestamp(ts, tz=timezone.utc)


def sun_events(day: date, lat: float, lon: float) -> tuple[datetime, datetime] | None:
    """その日の日出・日没（UTC）を返す。極夜・白夜では None。

    NOAA の簡易日出計算（誤差はおおむね1分程度）。時間帯バケットを
    決めるだけの用途にはこれで十分であり、外部依存を増やす必要はない。
    """
    jd = _to_julian(datetime(day.year, day.month, day.day, 12, tzinfo=timezone.utc))
    n = round(jd - 2451545.0 + 0.0008)
    j_star = n - lon / 360.0

    m = math.radians((357.5291 + 0.98560028 * j_star) % 360.0)
    c = 1.9148 * math.sin(m) + 0.02 * math.sin(2 * m) + 0.0003 * math.sin(3 * m)
    lam = math.radians((math.degrees(m) + c + 180.0 + 102.9372) % 360.0)

    j_transit = 2451545.0 + j_star + 0.0053 * math.sin(m) - 0.0069 * math.sin(2 * lam)
    decl = math.asin(math.sin(lam) * math.sin(math.radians(23.4397)))

    phi = math.radians(lat)
    cos_omega = (
        math.sin(math.radians(_ZENITH_DEG)) - math.sin(phi) * math.sin(decl)
    ) / (math.cos(phi) * math.cos(decl))

    if cos_omega > 1.0 or cos_omega < -1.0:
        return None  # 極夜（太陽が昇らない）/ 白夜（沈まない）

    omega = math.degrees(math.acos(cos_omega))
    return _from_julian(j_transit - omega / 360.0), _from_julian(j_transit + omega / 360.0)


def timeslot_of(captured_at: datetime, lat: float, lon: float) -> Timeslot:
    """撮影時刻・撮影地から時間帯バケットを決める。

    優先順位は dawn > golden > morning > dusk > night > noon。
    日が極端に短い時期に morning と golden が重なった場合、
    docs/01 §3.1 の通り golden（黄金時間）を優先する。
    """
    if captured_at.tzinfo is None:
        raise ValueError("captured_at must be timezone-aware")
    utc = captured_at.astimezone(timezone.utc)

    # 日付境界をまたぐ night を正しく拾うため、前日・当日・翌日を見る
    base = utc.date()
    for offset in (0, -1, 1):
        events = sun_events(base + timedelta(days=offset), lat, lon)
        if events is None:
            continue
        sunrise, sunset = events
        if sunrise - timedelta(minutes=60) <= utc < sunrise:
            return Timeslot.DAWN
        if sunset - timedelta(minutes=60) <= utc < sunset:
            return Timeslot.GOLDEN
        if sunrise <= utc < sunrise + timedelta(minutes=120):
            return Timeslot.MORNING
        if sunset <= utc < sunset + timedelta(minutes=45):
            return Timeslot.DUSK

    today = sun_events(base, lat, lon)
    if today is None:
        # 白夜 / 極夜。太陽高度で二分するしかない
        return Timeslot.NOON if lat_is_polar_day(base, lat, lon) else Timeslot.NIGHT

    sunrise, sunset = today
    if sunrise <= utc < sunset:
        return Timeslot.NOON
    return Timeslot.NIGHT


def lat_is_polar_day(day: date, lat: float, lon: float) -> bool:
    """白夜（太陽が沈まない）なら True、極夜なら False。

    sun_events が None を返したときの分岐にのみ使う。
    """
    jd = _to_julian(datetime(day.year, day.month, day.day, 12, tzinfo=timezone.utc))
    n = round(jd - 2451545.0 + 0.0008)
    j_star = n - lon / 360.0
    m = math.radians((357.5291 + 0.98560028 * j_star) % 360.0)
    c = 1.9148 * math.sin(m) + 0.02 * math.sin(2 * m) + 0.0003 * math.sin(3 * m)
    lam = math.radians((math.degrees(m) + c + 180.0 + 102.9372) % 360.0)
    decl = math.asin(math.sin(lam) * math.sin(math.radians(23.4397)))
    return (lat >= 0) == (decl >= 0)


# ---------------------------------------------------------------------------
# フラクタル次元の選好曲線（docs/00 §6 / docs/02 §2.3）
# ---------------------------------------------------------------------------


def fractal_preference(d: float, peak: float = 1.40, sigma: float = 0.15) -> float:
    """ボックスカウント次元 D に対する選好度を 0.0–1.0 で返す。

    Spehar et al. (2003) / Hagerhall, Purcell & Taylor (2004):
    人間の選好は D = 1.3〜1.5 で一貫してピークを示し、
    D = 1.1〜1.2 および 1.6〜1.9 では低い。山型（ガウス）で近似する。

    ①AIベース点の配点は  ai_fractal * fractal_preference(D)  で求める。
    """
    return math.exp(-((d - peak) ** 2) / (2.0 * sigma**2))
