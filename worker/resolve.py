"""採点ワーカーのスポット解決ステップ（docs/02 §1.3 手順2）。

このデプロイ単位（Container Apps / Consumption）は最終的に Service Bus の
`scoring` キューを KEDA で受けて ①AI採点 → ②希少性 → ③受付開始 まで回すが、
①は T-14、③は T-18 が入るまで存在しない。**今あるのは手順2だけ。**

単体で叩けるようにしてあるのは、粒度パラメータを変えたときの挙動を
本番のキューを通さずに確認するため。

    python -m worker.resolve --post-id <uuid>
    python -m worker.resolve --post-id <uuid> --grain-version-id 2
"""

from __future__ import annotations

import argparse
import json
import sys

from core import db, spots


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="投稿1件をスポットに結び付ける")
    parser.add_argument("--post-id", required=True)
    parser.add_argument(
        "--grain-version-id",
        type=int,
        default=None,
        help="省略時は active。再計算では当時のバージョンを明示する",
    )
    parser.add_argument(
        "--extract-version-id",
        type=int,
        default=None,
        help="省略時は有効な POI 抽出。再計算では当時の抽出を明示する（docs/06 §4.2）",
    )
    parser.add_argument("--dsn", default=None)
    args = parser.parse_args(argv)

    with db.connect(args.dsn) as conn:
        with db.transaction(conn) as cur:
            assignment = spots.bind_post(
                cur,
                args.post_id,
                grain_version_id=args.grain_version_id,
                extract_version_id=args.extract_version_id,
            )

    print(
        json.dumps(
            {
                "post_id": str(assignment.post_id),
                "grain_version_id": assignment.grain_version_id,
                "spot_id": str(assignment.binding.spot_id),
                "spot_identity_id": str(assignment.binding.identity_id),
                "bind_method": assignment.binding.bind_method,
                "bind_distance_m": assignment.binding.bind_distance_m,
                "bearing_sector": assignment.bearing_sector,
                "low_confidence": assignment.low_confidence,
            },
            ensure_ascii=False,
        )
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
