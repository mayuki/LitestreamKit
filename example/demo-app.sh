#!/bin/sh
# Stand-in for a real application: records each start and a periodic heartbeat
# in its SQLite database. Replace it with your own application command.
set -eu

db=${APP_DB_PATH:?Set APP_DB_PATH to the database file.}
interval=${APP_HEARTBEAT_INTERVAL:-5}

sql() {
    sqlite3 -cmd '.timeout 5000' "$db" "$@" > /dev/null
}

# Litestream requires WAL mode; set it when the database is first created.
sql 'PRAGMA journal_mode = WAL;' \
    'CREATE TABLE IF NOT EXISTS events (id INTEGER PRIMARY KEY, kind TEXT NOT NULL, at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP);' \
    "INSERT INTO events (kind) VALUES ('start');"
echo "demo-app: started with $db"

trap 'echo "demo-app: stopping"; exit 0' TERM INT
while :; do
    sleep "$interval" &
    wait $!
    sql "INSERT INTO events (kind) VALUES ('heartbeat');"
done
