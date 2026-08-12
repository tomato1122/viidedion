#!/usr/bin/env bash
# スキーマとスコアリング規則の検証をまとめて実行する。
#
#   ./scripts/test.sh
#
# PostgreSQL のテストは接続先が設定されているときだけ実行する。
# 接続先は標準の libpq 環境変数（PGHOST / PGPORT / PGUSER）か DATABASE_URL で指定する。
# PostGIS 拡張が使えるサーバーが必要。

set -euo pipefail
cd "$(dirname "$0")/.."

echo "== Python: ファセット導出規則 =="
python3 -m unittest discover -s scoring/tests -t .

if [[ -z "${DATABASE_URL:-}" && -z "${PGHOST:-}" ]]; then
    echo
    echo "== PostgreSQL: スキップ（DATABASE_URL / PGHOST が未設定） =="
    exit 0
fi

DB_NAME="${TEST_DB_NAME:-viidedion_test}"
PSQL=(psql -v ON_ERROR_STOP=1 -q)
if [[ -n "${DATABASE_URL:-}" ]]; then
    PSQL+=(-d "$DATABASE_URL")
    ADMIN=("${PSQL[@]}")
else
    ADMIN=(psql -v ON_ERROR_STOP=1 -q -d postgres)
fi

echo
echo "== PostgreSQL: マイグレーション適用 =="
"${ADMIN[@]}" -c "DROP DATABASE IF EXISTS ${DB_NAME};"
"${ADMIN[@]}" -c "CREATE DATABASE ${DB_NAME};"

for f in db/migrations/*.sql; do
    psql -v ON_ERROR_STOP=1 -q -d "$DB_NAME" -f "$f"
    echo "  applied: $f"
done

echo
echo "== PostgreSQL: スモークテスト =="
psql -v ON_ERROR_STOP=1 -d "$DB_NAME" -f db/tests/smoke_test.sql 2>&1 \
    | grep -E '^(psql:.*NOTICE:|==|ALL SMOKE)' \
    | sed -E 's/^psql:[^ ]+ NOTICE: //'
