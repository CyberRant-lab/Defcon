#!/bin/bash
# Streaming replica setup
# Waits for primary, takes base backup, starts streaming

set -e

PRIMARY_HOST="${POSTGRES_PRIMARY_HOST:-demo3-db-pri}"
PRIMARY_PORT="${POSTGRES_PRIMARY_PORT:-5432}"
REPL_USER="${POSTGRES_REPLICATION_USER:-replicator}"
REPL_PASS="${POSTGRES_REPLICATION_PASSWORD:-repl_secret}"
PGDATA="/var/lib/postgresql/data"

echo "  Replica: waiting for primary at ${PRIMARY_HOST}:${PRIMARY_PORT}..."

# Wait for primary to be ready
until pg_isready -h "$PRIMARY_HOST" -p "$PRIMARY_PORT" -U "$REPL_USER" 2>/dev/null; do
    echo "  Replica: primary not ready — retrying in 2s..."
    sleep 2
done

echo "  Replica: primary is up — taking base backup..."

# Clear data dir and take base backup
rm -rf "${PGDATA}"/*

PGPASSWORD="$REPL_PASS" pg_basebackup \
    -h "$PRIMARY_HOST" \
    -p "$PRIMARY_PORT" \
    -U "$REPL_USER" \
    -D "$PGDATA" \
    -Fp -Xs -P -R

# Write recovery config (PostgreSQL 12+ uses standby.signal + postgresql.auto.conf)
cat >> "${PGDATA}/postgresql.auto.conf" << EOF
primary_conninfo = 'host=${PRIMARY_HOST} port=${PRIMARY_PORT} user=${REPL_USER} password=${REPL_PASS} application_name=replica1'
recovery_target_timeline = 'latest'
EOF

chmod 700 "$PGDATA"
chown -R postgres:postgres "$PGDATA"

echo "  Replica: base backup done — starting streaming replication..."

exec gosu postgres postgres -D "$PGDATA"
