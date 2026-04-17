# DEFCON Coimbatore 2026 — Demo-3 Resource Kit
## "The Art of the Graceful Fail" — Three-Tier Edition
### Venugopal Parameswara — CISO & Cyber Strategist

> *"Cyber resilience is not a taller wall. Cyber resilience is a city that can rebuild itself while it is still on fire."*

---

## Why a Demo-3 kit?

Demo-2 proved the graceful-fail pattern on a **single stateless tier** — an immutable nginx container respawned from a golden image in under 2 seconds. That is the easy case. Attackers don't pick the easy case.

Demo-3 takes the same pattern and extends it across a **realistic three-tier stack**:

- **WEB** — nginx:alpine (immutable, stateless — Demo-2 pattern)
- **APP** — Flask API on Python 3.11 (stateful: in-memory sessions, connected to Postgres)
- **DB** — PostgreSQL 15 primary + streaming replica (stateful: WAL-replicated)
- **WAF** — ModSecurity + OWASP CRS in front of WEB (real HTTP 403s)

Five real Docker containers on an isolated `demo3-net` bridge. Every attack, every detection, every recovery event is real — no mocks, no simulated JSON. The audience can verify every claim with `docker ps`, `curl`, and `psql`.

---

## Quick Start

```bash
cd /Users/kuttanadan/Documents/defcon-demo/Demo-3
./setup_and_run3.sh setup      # builds all 5 images (once, ~10-15 min)
./setup_and_run3.sh start      # launches stack + guardian + agent
open http://localhost:7880      # live B-V-R dashboard
```

Trigger scenarios from the dashboard buttons or CLI:
```bash
./setup_and_run3.sh attack web    # wipeout → respawn  (measured R ≈ 0.63s)
./setup_and_run3.sh attack app    # kill    → restart  (measured R ≈ 0.73s)
./setup_and_run3.sh attack db     # T1486   → fence    (measured R ≈ 12.56s)
./setup_and_run3.sh attack waf    # curl campaign      (13/15 blocked — real 403s)
```

---

## B-V-R Win Condition — Measured, Not Estimated

| Variable | Value | How derived |
|---|---|---|
| **B** — Bleed Rate | $5,000 / min | FAIR Monte Carlo on $3B revenue; conservative round-down of $5,707/min |
| **V** — Attacker Velocity | 30 seconds | CrowdStrike GTR 2024 fastest breakout: 2m 7s; 30s is the conservative full-stack compromise |
| **R₁** — Web MTTR | 0.61–0.66s | `guardian3.sh` on M5, from DRIFT_DETECTED → HTTP 200 |
| **R₂** — App MTTR | 0.73–0.76s | `guardian3.sh`, from HEALTH_FAIL → HTTP 200 on port 3001 |
| **R₃** — DB MTTR | ~12.56s | `guardian3.sh`, from `pg_wal_replay_pause()` → `pg_wal_replay_resume()` after 10 quiet ticks |
| **R (rollup)** | 4.6s avg | Σ MTTRs / total attacks (3 attacks across the stack) |

**Win condition holds with ~6.5× margin even when the slowest DB tier is included.**

---

## Folder Structure

```
defcon_resource_kit_demo3/
|
|-- 01_presentation/              PPTX with speaker notes (Demo-3 three-tier arc)
|   └-- defcon_graceful_fail_demo3.pptx
|
|-- 02_demo3_stack/               Pointers + quick-ref for the live stack source
|   └-- README.md
|
|-- 03_reference_docs/            Seven parallel reference docs (md + pdf)
|   |-- bvr-scorecard              measured R₁/R₂/R₃, combined stack MTTR
|   |-- chaos-gameday-lab          4-tier attack cards (WEB, APP, DB, WAF)
|   |-- ciso-conversation-guide    translations for stateful tiers + board Qs
|   |-- ctf-guardian-gap-hunt      §9 honest gaps — bulk-insert leak, fence timing
|   |-- homelab-setup-guide        5-container setup on MacBook / Linux / WSL2
|   |-- mitre-attack-mapping       T1486, T1485, T1190, T1548, T1552.001
|   └-- reading-list               + Postgres replication, Patroni, ModSecurity CRS
|
|-- 04_expanded_concepts/         Extended slide deck (PDF)
|   └-- expanded-concepts-demo3.pdf
|
└-- README.md                     (this file)
```

---

## The Uncomfortable Truths — Preserved Honest

Demo-3 is a proof of concept, not a production system. These limitations are carried through every document in this kit; they are the article's "uncomfortable truth" tone.

| Limitation | Why we keep it in the story |
|---|---|
| **~500 DB rows still reach the replica before fence engages** | The 1-second poll cycle is faster than corruption replication, but the bulk INSERT phase lands inside a single tick before the velocity threshold computes. Real defence needs sub-100ms CDC monitoring. The demo shows *detection + containment*, not bleed-zero. |
| **DB recovery is fence-and-resume, not full promote** | `pg_wal_replay_pause` + auto-resume is measured. `pg_ctl promote` path exists (`db_promote_replica`) but is intentionally manual — upgrade target is Patroni/Stolon. |
| **WAF 86% not 100% block rate** | 1/15 requests returned HTTP 404 — route did not exist. Classified as PASSED for honesty. Zero successful exploits across all runs. |
| **Single-host deployment** | Five containers on one MacBook; sub-second MTTR is partly loopback networking. Production: each tier on separate hosts across AZs. |
| **Golden image supply-chain gap** | If the Dockerfile, CI/CD pipeline, or base image is compromised, every respawn ships poisoned. Mitigation: cosign, SBOM, immutable registries. That is the Level 4 CTF challenge. |

---

## The Demo-2 → Demo-3 Upgrade

| Dimension | Demo-2 | Demo-3 |
|---|---|---|
| Containers | 1 (nginx only) | 5 (web, app, db-primary, db-replica, waf) |
| State surface | None | In-memory sessions + Postgres WAL |
| Recovery pattern | Respawn from golden image | Respawn + DB fence/resume + WAF block-in-flight |
| Attack types | 1 (rm -rf web root) | 4 (wipeout, kill, ransomware, curl campaign) |
| Tiers proven | Stateless | Stateless + Stateful + Data |
| MTTR measurement | Single number | Per-tier + avg-per-attack + combined-stack rollup |

**The thesis doesn't change. The surface area does.** If the graceful-fail pattern survives Postgres WAL streaming and Flask session loss, it survives most of what production can actually throw at it.

---

*DEFCON Coimbatore 2026 · RESILIENCE · RECOVERY · RESPAWN*
*github.com/CyberRant-lab/Defcon*
