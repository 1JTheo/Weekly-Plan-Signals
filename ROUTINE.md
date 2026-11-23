# Claude's routine for WeeklyPlanEA

Each scheduled run is a fresh session. It follows these steps exactly.

## Inputs
- Repo: `1JTheo/Weekly-Plan-Signals` (public, branch `main`). The EA reads `weekly_plan.txt` at its root.
- Joseph's method: weekly COT for bias, CLEANNESS framework for data, 30-minute order blocks for entries, max 3 trades a day, avoid high/medium-news pairs. Instruments: majors (USD EUR GBP JPY CHF CAD AUD NZD) and XAUUSD.
- Timezone for anything shown to Joseph: Europe/Tallinn. Plan file times: UTC.

## Run types

**A. Weekly plan (Monday ~06:00 Tallinn)**
1. Research with web search (run searches in parallel): weekly forex outlook, latest CFTC COT (date of positions, crowded longs/shorts), week's economic calendar (high/medium impact, times), central bank expectations, risk sentiment (equities, yields, oil, gold), key levels per pair from 2+ analyst sources.
2. Write a thesis (2–4 lines) and 4–8 setups: each with track, scenario list, trigger (BREAK/REJECT/NOW), invalidation, TP1/TP2, group, risk multiplier. Build scenario tracks + calendar TRIGGERs for the 1–2 releases that decide the week (soft/hot thresholds around the consensus forecast).
3. Risk: `RISK pct=0.5 weekstop=2.0 maxday=3 news=HIGH newsmin=15`; correlated group caps; DAY multipliers (holiday/thin days 0.25, pre-event days 0.5); `flat` = Friday 1–2 h before the US close; `expires` = next Monday 00:00 UTC.
4. Archive last week's file to `plans/<week>.txt`, write the new `weekly_plan.txt` with `ver=<YYYY>W<NN>-01`.

**B. Daily refresh (~08:30 and ~14:30 Tallinn, Mon–Fri)**
1. Read the current `weekly_plan.txt`.
2. Search: overnight/today's drivers, data surprises in the last 12 h, central bank comments, any shock (intervention, geopolitics), today's calendar.
3. Change the plan **only if the thesis or a level is no longer true**. Not changing it is the normal outcome. If changed: keep `made`, set `upd`, bump `ver` (…-02, -03), keep ids of continuing ideas.

**C. Post-event check (~20 min after a TRIGGER release)**
1. Find the actual number and the market reaction (and whether the Fed/central bank pricing moved).
2. Confirm the EA's automatic switch by setting `TRACK ... active=` to the right scenario. Adjust levels/targets for the new scenario if needed. Bump `ver`.

## Every run that changes the file
1. `python3 tools/check_plan.py weekly_plan.txt` must print OK. Fix errors before pushing.
2. Commit with a one-line reason (e.g. `W48-03: PCE hot, USD track HOT, EU_B levels refreshed`) and push to `main`.
3. Finish with a short summary for Joseph in Tallinn time: what changed and why, or "no change".

## Never
- Never touch CEA4, Market Desk Pro, or the `Pro-market-desk-signals` and `CEA4-Trading-Vault` repos.
- Never raise `pct` above 0.5 or `weekstop` above 2.0 without Joseph asking.
- Never invent a number: if a release time or level can't be confirmed, leave it out and say so.
