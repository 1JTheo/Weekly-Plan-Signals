# WeeklyPlanEA — Claude's weekly plan, executed on MT5

An experiment, separate from CEA4 and Market Desk Pro. Run it on its own account.

**How it works**
1. Every Monday Claude analyses the week and writes `weekly_plan.txt` (scenarios, levels, risk rules).
2. Claude pushes the file to GitHub. During the week Claude re-checks and pushes updates.
3. `WeeklyPlanEA` downloads the file every 5 minutes, watches price every 15 seconds, and trades the plan.
4. When high-impact data prints (e.g. US core PCE), the EA reads the actual number from the MT5 calendar and switches scenario itself within seconds. Claude confirms or adjusts about 20 minutes later.

## Install (one time)

1. Copy `WeeklyPlanEA.mq5` into `MQL5/Experts/` (MT5: File → Open Data Folder).
2. Open it in MetaEditor and press **Compile** (F7). Fix nothing by hand — if it shows errors, send them to Claude.
3. MT5 → Tools → Options → Expert Advisors:
   - tick **Allow algorithmic trading**
   - tick **Allow WebRequest for listed URL** and add `https://raw.githubusercontent.com`
4. Optional: Tools → Options → Notifications → enter your MetaQuotes ID to get push alerts on your phone.
5. Attach the EA to **one** chart (any symbol, any timeframe). It trades every symbol in the plan.

## Settings (only three)

| Setting | Meaning |
|---|---|
| `InpPlanURL` | Address of the plan file on GitHub |
| `InpAutoTrade` | `true` = places orders. `false` = alert-only: shows and notifies setups, no orders |
| `InpMagic` | Order ID so it never touches other EAs' trades. Keep different from CEA4 |

Everything else (risk %, levels, scenarios, news filter) comes from the plan file.

## What the EA does

- **Scenario tracks** — e.g. `USD=BASE` before PCE, then `SOFT`, `INLINE` or `HOT`. Only setups for the active scenario can trade. On a switch it cancels orders and closes trades that no longer fit.
- **Triggers** — `BREAK`: H4 close beyond a level. `REJECT`: price enters a zone and an H1 candle closes back out. `NOW`: arms as soon as its scenario becomes active (used after a data surprise).
- **Entry** — after the trigger, the first unmitigated **30-minute order block**: limit order at the block edge, stop beyond the block plus a small ATR buffer. Needs at least 1.5R to the final target.
- **Exits** — half off at TP1 and stop to entry; rest at TP2. Invalidation candle close = exit. Optional maximum hold time.
- **Risk** — % per trade × day multiplier × setup multiplier; correlated-group caps (e.g. EUR long + GBP long + gold long share one USD-short budget); max trades per day; weekly stop closes everything and halts until next week; Friday flat time.
- **Protection** — no new entries ±15 min around high-impact news for either currency; cancels pending orders in that window; flat before chosen releases; spread filter; tripwires (e.g. USD/JPY −1.50 in 5 min = treat as intervention, go flat, block 24h).
- **Panel** on the chart shows plan version, scenarios, next events and every setup's status.

## Good to know

- Use a **hedging** account (partial closes rely on it). Test on demo first.
- The MT5 economic calendar does not run in the Strategy Tester, so backtests won't show scenario switching or news blackouts. Forward-test on demo instead.
- If GitHub can't be reached, the EA keeps running on the last plan it saved.
- When the plan expires (Monday 00:00 UTC) it stops opening trades until the next plan arrives.
- Levels come from analyst reports, not a live feed. The EA confirms with real price before acting.

## Files

| File | What it is |
|---|---|
| `weekly_plan.txt` | This week's plan (the EA reads this) |
| `ea/WeeklyPlanEA.mq5` | The EA source |
| `PLAN_FORMAT.md` | Every field in the plan file |
| `ROUTINE.md` | The steps Claude follows on each scheduled run |
| `tools/check_plan.py` | Validates a plan file before it is pushed |
| `plans/` | Archive of past weekly plans |

Analysis of the market backdrop, not financial advice. Entries, stops and sizing are your call.
