#!/usr/bin/env python3
"""
Phoenix App — Tier 2: Application Server
DEFCON Coimbatore 2026 · Venugopal Parameswara

Stateful Flask API with:
  - In-memory transaction counter (shows state loss on kill)
  - Session store (demonstrates persistence problem)
  - DB connectivity check
  - /health endpoint (guardian polls this)
  - /status endpoint (dashboard reads this)
  - /transactions endpoint (shows accumulated state)
"""

from flask import Flask, jsonify, request
import psycopg2
import os
import time
import threading
from datetime import datetime

app = Flask(__name__)

# ── Stateful data — this is what gets LOST when container is killed ──
state = {
    "transactions":     0,
    "sessions":         {},
    "start_time":       time.time(),
    "requests_served":  0,
    "db_connected":     False,
    "last_db_check":    None,
}

DB_CONFIG = {
    "host":     os.getenv("DB_HOST",  "demo3-db-pri"),
    "port":     int(os.getenv("DB_PORT", 5432)),
    "dbname":   os.getenv("DB_NAME",  "phoenix"),
    "user":     os.getenv("DB_USER",  "phoenix"),
    "password": os.getenv("DB_PASS",  "phoenix123"),
    "connect_timeout": 3,
}

def ist():
    from datetime import timezone, timedelta
    return datetime.now(timezone(timedelta(hours=5, minutes=30)))\
                   .strftime("%H:%M:%S IST")

# ── DB connectivity background check ──────────────────────────
def check_db():
    while True:
        try:
            conn = psycopg2.connect(**DB_CONFIG)
            cur  = conn.cursor()
            cur.execute("SELECT COUNT(*) FROM transactions")
            count = cur.fetchone()[0]
            conn.close()
            state["db_connected"]  = True
            state["last_db_check"] = ist()
            state["transactions"]  = count
        except Exception as e:
            state["db_connected"]  = False
            state["last_db_check"] = ist()
        time.sleep(3)

threading.Thread(target=check_db, daemon=True).start()

# ── Routes ────────────────────────────────────────────────────

@app.route("/health")
def health():
    state["requests_served"] += 1
    return jsonify({"status": "healthy", "ts": ist()}), 200

@app.route("/status")
def status():
    state["requests_served"] += 1
    uptime = round(time.time() - state["start_time"], 1)
    return jsonify({
        "status":           "operational",
        "uptime_s":         uptime,
        "transactions":     state["transactions"],
        "sessions_active":  len(state["sessions"]),
        "requests_served":  state["requests_served"],
        "db_connected":     state["db_connected"],
        "db_host":          DB_CONFIG["host"],
        "last_db_check":    state["last_db_check"],
        "ts":               ist(),
        "note": "This state is IN MEMORY — lost when container is killed"
    }), 200

@app.route("/transaction", methods=["POST"])
def add_transaction():
    state["requests_served"] += 1
    amount = request.json.get("amount", 100) if request.is_json else 100
    try:
        conn = psycopg2.connect(**DB_CONFIG)
        cur  = conn.cursor()
        cur.execute(
            "INSERT INTO transactions (amount, created_at) VALUES (%s, NOW())",
            (amount,)
        )
        conn.commit()
        cur.execute("SELECT COUNT(*) FROM transactions")
        total = cur.fetchone()[0]
        conn.close()
        state["transactions"] = total
        return jsonify({"ok": True, "total_transactions": total, "ts": ist()}), 201
    except Exception as e:
        return jsonify({"ok": False, "error": str(e)}), 500

@app.route("/transactions")
def get_transactions():
    state["requests_served"] += 1
    try:
        conn = psycopg2.connect(**DB_CONFIG)
        cur  = conn.cursor()
        cur.execute(
            "SELECT id, amount, created_at FROM transactions "
            "ORDER BY created_at DESC LIMIT 10"
        )
        rows = [{"id": r[0], "amount": float(r[1]),
                 "ts": r[2].strftime("%H:%M:%S")} for r in cur.fetchall()]
        conn.close()
        return jsonify({"transactions": rows, "count": len(rows)}), 200
    except Exception as e:
        return jsonify({"error": str(e)}), 500

@app.route("/session", methods=["POST"])
def create_session():
    import uuid
    state["requests_served"] += 1
    sid = str(uuid.uuid4())[:8]
    state["sessions"][sid] = {"created": ist(), "data": request.json or {}}
    return jsonify({"session_id": sid, "ts": ist()}), 201

if __name__ == "__main__":
    print(f"\n  Phoenix App — Tier 2: Application Server")
    print(f"  Port: 3001  DB: {DB_CONFIG['host']}:{DB_CONFIG['port']}")
    print(f"  Health: http://localhost:3001/health")
    print(f"  Status: http://localhost:3001/status\n")
    app.run(host="0.0.0.0", port=3001, debug=False)
