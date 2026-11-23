# Plan file format

Plain text, one record per line, `key=value` fields separated by spaces. `#` starts a comment. In text fields `_` means a space. **All times are UTC**, format `YYYY-MM-DDTHH:MM`.

| Record | Fields | Notes |
|---|---|---|
| `PLAN` | `ver week made expires flat note upd` | `ver` must change on every edit or the EA ignores the file. `made` = when the weekly plan was first written; keep it fixed all week (triggers only count candles after it). `upd` = time of the latest edit (info only). `flat` = close everything and stop. |
| `RISK` | `pct weekstop maxday news newsmin spreadx` | `news` = `HIGH` or `MEDIUM`. `spreadx` = skip entries when spread > x × recent average. |
| `GROUP` | `id cap` | Max total risk % of open/pending trades in the group (trades already at break-even don't count). |
| `DAY` | `date mult max` | Size multiplier and max new trades for that UTC date. `mult=0` = no trading. |
| `TRACK` | `name active` | Scenario currently active for this track. A calendar trigger that fires after `made` overrides it. |
| `TRIGGER` | `id track country match soft hot ifsoft ifmid ifhot flatbefore` | `match`: words joined by `+` that must all be in the MT5 calendar event name; `~word` must be absent. `actual <= soft` → `ifsoft`; `>= hot` → `ifhot`; else `ifmid`. `flatbefore` = minutes before release to close that currency's trades (0 = off). |
| `SETUP` | `id track scen sym dir trig lvl zlo zhi inv invtf tp1 tp2 grp rm hold window` | `scen`: comma list or `ALL`. `dir`: `BUY`/`SELL`. `trig`: `BREAK` (needs `lvl`), `REJECT` (needs `zlo zhi`), `NOW`. `inv`+`invtf` (`M30 H1 H4 D1`): candle close beyond = idea dead. `tp1/tp2` optional (defaults 1.5R/3R). `rm` = risk multiplier. `hold` = max hours in trade. `window` = hours an armed setup may wait for an order block. |
| `TRIP` | `id sym dir move min block` | `dir`: `UP`, `DOWN`, `ANY`. `move` in price units within `min` minutes → flat symbol, block `block` hours. |
| `CLOSE` | `sym` | Close all EA trades on the symbol once, when this plan version loads. |

**Rules for editing during the week**
- Keep the same `id` for an idea that continues (its state carries over). Use a new `id` for a new idea.
- Removing a setup cancels its pending order; an open trade keeps its stop and target. Use `CLOSE` to force it out.
- To switch scenario by hand, change `TRACK ... active=` and bump `ver`.
