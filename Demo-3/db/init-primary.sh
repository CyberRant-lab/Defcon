#!/bin/bash
# Runs on first start — creates schema + replication user

set -e

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" << 'SQL'
-- Application schema
CREATE TABLE IF NOT EXISTS transactions (
    id          SERIAL PRIMARY KEY,
    amount      DECIMAL(10,2) NOT NULL,
    created_at  TIMESTAMP DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS sessions (
    id          VARCHAR(8) PRIMARY KEY,
    data        JSONB,
    created_at  TIMESTAMP DEFAULT NOW()
);

-- Seed some initial data
INSERT INTO transactions (amount) VALUES (100.00), (250.50), (75.00);

-- Monitoring view for guardian
CREATE OR REPLACE VIEW replication_status AS
SELECT
    client_addr,
    state,
    sent_lsn,
    write_lsn,
    flush_lsn,
    replay_lsn,
    (sent_lsn - replay_lsn) AS replication_lag_bytes
FROM pg_stat_replication;
SQL

# Create replication user
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" << SQL
CREATE USER replicator REPLICATION LOGIN PASSWORD 'repl_secret';
SQL

echo "Primary DB initialised — schema created, replication user ready"
