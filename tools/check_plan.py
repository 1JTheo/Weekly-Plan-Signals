#!/usr/bin/env python3
"""Validate a WeeklyPlanEA plan file before it is pushed.

Usage: python3 check_plan.py weekly_plan.txt
Exit code 0 = OK, 1 = errors found. Mirrors the parsing rules of WeeklyPlanEA.mq5.
"""
import sys
from datetime import datetime

RECORDS = {"PLAN", "RISK", "GROUP", "DAY", "TRACK", "TRIGGER", "SETUP", "TRIP", "CLOSE"}
TRIGS = {"BREAK", "REJECT", "NOW"}
TFS = {"M30", "H1", "H4", "D1"}


def parse(path):
    recs = []
    for n, raw in enumerate(open(path, encoding="utf-8"), 1):
        line = raw.strip().replace("\t", " ")
        if not line or line.startswith("#"):
            continue
        parts = [p for p in line.split(" ") if p]
        kv = {}
        for p in parts[1:]:
            if "=" in p:
                k, v = p.split("=", 1)
                kv[k] = v
        recs.append((n, parts[0], kv))
    return recs


def t(s):
    return datetime.strptime(s, "%Y-%m-%dT%H:%M")


def main(path):
    errs, warns = [], []
    recs = parse(path)
    plans = [r for r in recs if r[1] == "PLAN"]
    if len(plans) != 1:
        errs.append("need exactly one PLAN line")
    else:
        _, _, p = plans[0]
        for k in ("ver", "week", "made", "expires"):
            if k not in p:
                errs.append(f"PLAN missing {k}=")
        try:
            made, exp = t(p["made"]), t(p["expires"])
            if exp <= made:
                errs.append("PLAN expires must be after made")
            if "flat" in p and not (made < t(p["flat"]) <= exp):
                errs.append("PLAN flat must be between made and expires")
        except (KeyError, ValueError) as e:
            errs.append(f"PLAN bad time: {e}")

    tracks = {kv.get("name"): kv.get("active") for _, r, kv in recs if r == "TRACK"}
    groups = {kv.get("id") for _, r, kv in recs if r == "GROUP"}
    scen_names = {"BASE"} | set(tracks.values())
    for n, r, kv in recs:
        if r == "TRIGGER":
            for k in ("id", "track", "country", "match", "soft", "hot"):
                if k not in kv:
                    errs.append(f"line {n}: TRIGGER missing {k}=")
            if kv.get("track") not in tracks:
                errs.append(f"line {n}: TRIGGER track {kv.get('track')} has no TRACK line")
            if float(kv.get("soft", 0)) >= float(kv.get("hot", 0)):
                errs.append(f"line {n}: TRIGGER soft must be < hot")
            scen_names |= {kv.get("ifsoft", "SOFT"), kv.get("ifmid", "INLINE"), kv.get("ifhot", "HOT")}

    ids = set()
    for n, r, kv in recs:
        if r not in RECORDS:
            errs.append(f"line {n}: unknown record {r}")
            continue
        if r != "SETUP":
            continue
        sid = kv.get("id", "")
        if not sid or sid in ids:
            errs.append(f"line {n}: SETUP id missing or duplicate")
        ids.add(sid)
        if len("WP:" + sid) > 25:
            warns.append(f"line {n}: id {sid} is long; brokers may cut order comments")
        if kv.get("track", "USD") not in tracks:
            errs.append(f"line {n}: {sid} track has no TRACK line")
        for s in kv.get("scen", "ALL").split(","):
            if s != "ALL" and s not in scen_names:
                errs.append(f"line {n}: {sid} scenario {s} can never become active")
        d = kv.get("dir")
        if d not in ("BUY", "SELL"):
            errs.append(f"line {n}: {sid} dir must be BUY or SELL")
            continue
        sign = 1 if d == "BUY" else -1
        trig = kv.get("trig", "BREAK")
        if trig not in TRIGS:
            errs.append(f"line {n}: {sid} trig must be one of {TRIGS}")
        if kv.get("invtf", "H4") not in TFS:
            errs.append(f"line {n}: {sid} invtf must be one of {TFS}")
        f = {k: float(kv[k]) for k in ("lvl", "zlo", "zhi", "inv", "tp1", "tp2") if k in kv}
        if trig == "BREAK" and "lvl" not in f:
            errs.append(f"line {n}: {sid} BREAK needs lvl=")
        if trig == "REJECT":
            if "zlo" not in f or "zhi" not in f or f["zlo"] >= f["zhi"]:
                errs.append(f"line {n}: {sid} REJECT needs zlo < zhi")
        ref = f.get("lvl") if trig == "BREAK" else (f.get("zhi") if sign > 0 else f.get("zlo"))
        if ref is not None:
            if "tp1" in f and sign * (f["tp1"] - ref) <= 0:
                errs.append(f"line {n}: {sid} tp1 is on the wrong side")
            if "tp1" in f and "tp2" in f and sign * (f["tp2"] - f["tp1"]) < 0:
                errs.append(f"line {n}: {sid} tp2 must be beyond tp1")
            if "inv" in f and sign * (ref - f["inv"]) < 0:
                warns.append(f"line {n}: {sid} invalidation is beyond the trigger level - check")
        if kv.get("grp") and kv["grp"] not in groups:
            warns.append(f"line {n}: {sid} group {kv['grp']} has no GROUP cap (uncapped)")

    for w in warns:
        print("WARN ", w)
    for e in errs:
        print("ERROR", e)
    print(f"{len(ids)} setups, {len(tracks)} tracks, {sum(1 for r in recs if r[1]=='TRIGGER')} triggers, "
          f"{sum(1 for r in recs if r[1]=='TRIP')} tripwires -> {'OK' if not errs else 'FAILED'}")
    return 1 if errs else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "weekly_plan.txt"))
