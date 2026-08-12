-- 0001_extensions.sql
-- 前提: Azure Database for PostgreSQL フレキシブルサーバー / PostgreSQL 16
--
-- 使う拡張は事前に allowlist（サーバーパラメータ azure.extensions）へ登録しておくこと。
-- h3-pg は Azure の対応拡張機能一覧に含まれないため、H3インデックスはアプリ層で計算し
-- bigint として保存する。詳細は docs/01-spot-granularity.md §5。

CREATE EXTENSION IF NOT EXISTS postgis;

-- pg_cron は 'postgres' データベースにのみインストールできる。
-- 週次リセットと ③ の確定スイープで使用する（db/migrations/0006_jobs.sql）。
-- CREATE EXTENSION IF NOT EXISTS pg_cron;

-- 投票ログの月次パーティション運用に使う。MVPでは未使用。
-- CREATE EXTENSION IF NOT EXISTS pg_partman;


-- ---------------------------------------------------------------------------
-- NULL の扱いに関する規約（全テーブル共通）
-- ---------------------------------------------------------------------------
-- ファセット次元（bearing_sector / weather / timeslot / season）の NULL は
-- 「不明」を意味する独立したバケットであり、他の値と混ぜない。
-- 一意制約は UNIQUE NULLS NOT DISTINCT（PostgreSQL 15+）で NULL 同士を
-- 同一視することで、「不明」バケットにも1行しか立たないようにする。
--
-- 「不明」を含むファセットには初回ボーナスを発行しない（0004 の calc_rarity_score）。
-- 理由: 方位や天候を欠落させれば無限に「初」を取れてしまうため。
-- ---------------------------------------------------------------------------
