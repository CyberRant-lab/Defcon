# B-V-R Scorecard — Demo-3 Three-Tier Edition
## DEFCON Coimbatore 2026 · Venugopal Parameswara

> *"The wall that was supposed to be the strategy was the entire strategy. There was no plan for the day it fell."*

---

## The Equation

```
B (Bleed Rate $/min)  ×  time_service_dark (min)   =   Loss in USD

                    IF   R < V   →  DEFENDER WINS
                    IF   R ≥ V   →  DEFENDER LOSES
```

**B** is how fast revenue bleeds. **V** is how fast the attacker moves. **R** is how fast you recover. The entire model reduces to whether a simple inequality holds in live production, not on a slide.

---

## Demo-3 Measured Values

All values are **measured, not estimated**. Every R value in this scorecard has a `mttr_ms` field in `/tmp/demo3_guardian.jsonl` you can verify after any attack run.

### B — Bleed Rate

| Input | Value | Source |
|---|---|---|
| Annual revenue | $3,000,000,000 | Tier-1 service at a mid-size enterprise (model input) |
| Minutes per year | 525,600 | Standard |
| Revenue per minute | $5,707 | $3B ÷ 525,600 |
| Loss form additions | Productivity + IR cost + reputational + regulatory | FAIR Loss Magnitude components |
| **B** | **$5,000 / min** | Rounded conservatively |

**Real-world anchors:**
- British Airways (2018 ICO fine + remediation): ~$53,000 / min
- Maersk (NotPetya, $300M over 14 days): ~$15,000 / min
- MGM Resorts (2023 SEC filings): ~$7,000 / min

---

### V — Attacker Velocity

| Phase | Observed | Cited benchmark |
|---|---|---|
| Initial access → wipeout (web tier) | ~5s live (`docker exec` + `rm -rf` + HTTP 404) | — |
| Full-stack compromise | Budgeted 30s | — |
| Fastest recorded breakout (CrowdStrike GTR 2024) | 2m 7s | Fastest observed eCrime |
| Average eCrime breakout time | 62 min (down from 84 min) | CrowdStrike GTR 2024 |
| **V (headline)** | **30 seconds** | Conservative full-stack compromise |

As AI-assisted exploit generation matures, V collapses further. A fully automated attacker can hit this in **under 10 seconds**. The V on this card is the ceiling, not the floor.

---

### R — Recovery Runway (measured live)

| Tier | R | Recovery mechanism | Evidence |
|---|---|---|---|
| **R₁** — Web | **0.61–0.66s** | `docker rm -f demo3-web` → `docker run demo3-web:golden` → HTTP 200 | `RESPAWN_SUCCESS` with `mttr_ms` |
| **R₂** — App | **0.73–0.76s** | `docker rm -f demo3-app` → respawn → Flask up → Postgres reconnect | `RESTART_SUCCESS` with `mttr_ms` |
| **R₃** — DB | **~12.56s** | `pg_wal_replay_pause()` → 10 quiet ticks → `pg_wal_replay_resume()` | `REPLICA_RESUMED` with `mttr_ms` |

### Rollups (dashboard footer)

| Metric | Value | Meaning |
|---|---|---|
| **R (avg per attack)** | **~4.6s** | Σ all MTTRs / total attacks across the stack |
| **C (combined cascade)** | **~13.9s** | Σ of each tier's avg MTTR — full cascade if every tier fell once |
| **W (win)** | **✓ WIN** | R < V → 4.6s < 30s → ~6.5× margin |

---

## Worked Example — A Single Demo Run

Three attacks in sequence, as they happen on stage:

```
[09:35:58] WEB drift detected       → respawn  → R₁ = 0.606s
[09:37:17] APP health fail           → restart  → R₂ = 0.728s
[09:39:19] DB mass write detected    → fence
[09:39:31] DB quiet ticks exhausted  → resume   → R₃ = 12.504s

Total bleed-time: 0.606 + 0.728 + 12.504 = 13.838 seconds
Bleed:            13.838s × ($5,000/60s) = ~$1,153.17

Without B-V-R:    Same stack down for SLA target 30 min
                  Bleed = 30 × $5,000 = $150,000

Delta:            $150,000 - $1,153 = $148,847 prevented, per full-stack incident.
```

**This is not a theoretical savings.** Every incident logged to the JSONL has a `mttr_ms` field. The agent aggregates them into `state.agent.total_saved_usd`, shown live on the dashboard next to the confidence bar.

---

## Your Own B-V-R Worksheet

Fill in the right column for your own Tier-1 service. Print this page.

```
╔════════════════════════════════════════════════════════════════╗
║                    B-V-R SCORECARD — YOUR STACK                ║
╠════════════════════════════════════════════════════════════════╣
║                                                                ║
║  SERVICE NAME:                                                 ║
║  DATE OF MEASUREMENT:                                          ║
║                                                                ║
║  B — BLEED RATE                                                ║
║     Annual revenue (your number):   $ ___________________      ║
║     ÷ 525,600 minutes             = $ ___________ / min        ║
║     + productivity loss/min       = $ ___________ / min        ║
║     + avg IR cost per min         = $ ___________ / min        ║
║     + regulatory exposure/min     = $ ___________ / min        ║
║     ──────────────────────────────────────────────             ║
║     B (total):                      $ ___________ / min        ║
║                                                                ║
║  V — ATTACKER VELOCITY                                         ║
║     Last red team full wipeout:     ______ seconds             ║
║     Or industry benchmark (30s):    ______ seconds             ║
║     V (headline):                   ______ seconds             ║
║                                                                ║
║  R — RECOVERY (per Tier-1 tier)                                ║
║     Tier 1 name:                                               ║
║     Tier 1 measured MTTR:           ______ seconds             ║
║     Tier 2 name:                                               ║
║     Tier 2 measured MTTR:           ______ seconds             ║
║     Tier 3 name:                                               ║
║     Tier 3 measured MTTR:           ______ seconds             ║
║     ──────────────────────────────────────────────             ║
║     R (avg per attack):             ______ seconds             ║
║     C (combined cascade):           ______ seconds             ║
║                                                                ║
║  VERDICT                                                       ║
║     R < V?   ☐ YES — DEFENDER WINS                             ║
║              ☐ NO  — gap: V - R = ______ seconds               ║
║                                                                ║
║     Cost of one average incident:   $ ___________              ║
║     Cost without B-V-R (SLA MTTR):  $ ___________              ║
║     Delta prevented per incident:   $ ___________              ║
║                                                                ║
╚════════════════════════════════════════════════════════════════╝
```

---

## Red Flags — Your Scorecard Is Broken If…

| Red flag | What it means |
|---|---|
| "R is 99.9% uptime" | You're measuring the wrong thing. Uptime ≠ MTTR. An SLA that allows 8.7 hours/year of downtime says nothing about how fast you recover per incident. |
| "V is unknown — we haven't done a red team" | Your scorecard is a fiction. V has to be measured, not assumed. |
| "R requires a human on-call" | Human MTTR is never under 5 minutes. Automated MTTR can be under 2 seconds. The gap is your most actionable improvement. |
| "B is 'critical'" | If you can't put a dollar on it, you can't prioritise it. Every Tier-1 service needs a number, even a rough one. |
| "We blocked 10M attacks this year" | Vanity metric. Ignore unless it's paired with: how fast did we recover the one that got through? |

---

## How Demo-3 Proves Each R

| R | Mechanism | Script | Verification |
|---|---|---|---|
| R₁ | Immutable image — wipe container → respawn from `demo3-web:golden` | `attack3_web.sh` | `grep RESPAWN_SUCCESS /tmp/demo3_guardian.jsonl \| tail -1` |
| R₂ | Kill + restart; DB state outlives the container | `attack3_app.sh` | Session count goes to 0, transaction count preserved |
| R₃ | Fence replica mid-corruption via `pg_wal_replay_pause`; auto-resume after 10 quiet ticks | `attack3_db.sh` | `grep REPLICA_RESUMED /tmp/demo3_guardian.jsonl` — `mttr_ms` field populated |

You do not have to trust any number on this card. Run the attack, grep the log, do the arithmetic.

---

*DEFCON Coimbatore 2026 · Venugopal Parameswara · CISO & Cyber Strategist*
