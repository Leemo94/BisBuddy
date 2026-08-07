#!/usr/bin/env python3
"""BisBuddy talent-tree data generator.

For each spec, pulls the top-N performers on coa.ascensionlogs.gg (healing
metric for healers, dps otherwise), reads each player's talent build from their
armory, and computes how often each talent is taken. It also unions every
talent node it sees (per class) to reconstruct the full grid layout, so the
addon can draw the whole tree and colour each node by its take-rate:

  green  >= 80%   (basically everyone)
  orange 25-79%   (build-dependent)
  red    <  25%   (almost no one)

Output: BisBuddy/TalentData.lua

  BisBuddyTalents.trees[Class]  = { order = {...}, trees = { slug = {label, nodes=[{id,name,icon,row,col,max}]} } }
  BisBuddyTalents.takeRates[Class|Spec] = { n = <sample>, pct = { [entryId] = 0..100 } }

Usage:
  python3 talents_generate.py                 # all specs (slow, ~1400 fetches)
  python3 talents_generate.py --class Tinker  # one class's specs
  python3 talents_generate.py --top 20 --difficulty mythic
"""

import argparse
import concurrent.futures
import json
import os
import re
import time
import urllib.request

SITE = "https://coa.ascensionlogs.gg"
API = SITE + "/api"
SPECROLES = "https://coa.bisbeard.com"
HEADERS = {"Referer": SITE + "/", "Origin": SITE, "Accept": "application/json",
           "User-Agent": "Mozilla/5.0 (BisBuddy talents)"}

THROTTLE = 0.0   # seconds to pause after each successful request (politeness; set via --throttle)


def get(url, retries=7):
    last = None
    for attempt in range(retries):
        try:
            req = urllib.request.Request(url, headers=HEADERS)
            data = json.load(urllib.request.urlopen(req, timeout=40))
            if THROTTLE:
                time.sleep(THROTTLE)
            return data
        except urllib.error.HTTPError as e:      # back off hard on throttling / 5xx
            last = e
            wait = 6.0 if e.code in (429, 500, 502, 503, 504) else 0.6
            time.sleep(min(20, wait * (attempt + 1)))
        except Exception as e:  # noqa           # timeouts / transient network
            last = e
            time.sleep(min(12, 0.8 * (attempt + 1)))
    raise last


def discover_specroles():
    html = urllib.request.urlopen(urllib.request.Request(SPECROLES + "/", headers=HEADERS), timeout=40).read().decode()
    m = re.search(r'src="(/assets/index-[^"]+\.js)"', html)
    bundle = urllib.request.urlopen(urllib.request.Request(SPECROLES + m.group(1), headers=HEADERS), timeout=40).read().decode()
    m = re.search(r'"(assets/specRoles-[^"]+\.js)"', bundle)
    return urllib.request.urlopen(urllib.request.Request(SPECROLES + "/" + m.group(1), headers=HEADERS), timeout=40).read().decode()


def parse_specs(src):
    """{ 'Class|Spec': role } from the specRoles module."""
    specs = {}
    for m in re.finditer(r'"([A-Za-z \'-]+\|[A-Za-z \'-]+)":\{role:"([a-z-]+)"', src):
        specs[m.group(1)] = m.group(2)
    return specs


def top_performers(cls, spec, metric, difficulty, top):
    url = (f"{API}/encounters/rankings/all-dungeons?metric={metric}"
           f"&difficulty={difficulty}&phase=0"
           f"&class={urllib.parse.quote(cls)}&spec={urllib.parse.quote(spec)}&limit=200")
    try:
        r = get(url)
    except Exception:
        return []
    seen = {}
    for row in r.get("rankings", []):
        cid = row.get("character_id")
        if cid and cid not in seen:  # rankings are score-sorted; keep the best row per char
            seen[cid] = row
        if len(seen) >= top:
            break
    return list(seen.values())[:top]


# ---- Zul'Gurub raid mode ------------------------------------------------------
# ZG is phase 1. The `all` board (phase=1) returns, per boss, a rankingsByDifficulty
# map; we pool the top-N of each difficulty (normal/heroic/mythic/ascended) into one
# per-spec sample of raiders, deduped by character.
ZG_PHASE = 1
ZG_LOCATION = "Zul'Gurub"
ZG_DIFFS = ["normal", "heroic", "mythic", "ascended"]


def top_performers_zg(cls, spec, metric, top_per_diff):
    url = (f"{API}/encounters/rankings/all?metric={metric}&phase={ZG_PHASE}"
           f"&class={urllib.parse.quote(cls)}&spec={urllib.parse.quote(spec)}&limit=100")
    try:
        r = get(url)
    except Exception:
        return []
    rankings = r.get("rankings", {})
    if not isinstance(rankings, dict):
        return []
    keyf = "avg_hps" if metric == "healing" else "avg_dps"
    per = {d: {} for d in ZG_DIFFS}          # difficulty -> {cid: (score, row)}
    for _bid, entry in rankings.items():
        if not isinstance(entry, dict):
            continue
        if (entry.get("boss") or {}).get("location") != ZG_LOCATION:
            continue
        for d, rows in (entry.get("rankingsByDifficulty") or {}).items():
            if d not in per:
                continue
            for row in rows or []:
                cid = row.get("character_id")
                if not cid:
                    continue
                sc = row.get(keyf) or 0
                if sc > per[d].get(cid, (-1, None))[0]:   # keep a char's best parse at this difficulty
                    per[d][cid] = (sc, row)
    pooled = {}                               # cid -> (score, row) best across the kept difficulties
    for d in ZG_DIFFS:
        for sc, row in sorted(per[d].values(), key=lambda x: -x[0])[:top_per_diff]:
            cid = row["character_id"]
            if cid not in pooled or sc > pooled[cid][0]:
                pooled[cid] = (sc, row)
    return [row for _sc, row in pooled.values()]


def build_of(cid):
    """Return (taken_entry_ids set, [node dicts]) for a character armory."""
    try:
        a = get(f"{API}/armory/character/{cid}")
    except Exception:
        return set(), []
    spec = a.get("ci_resolved", {}).get("specialization", {})
    trees = spec.get("talents", {}).get("trees", {})
    taken, nodes = set(), []
    for slug, tree in trees.items():
        for t in tree.get("talents", []):
            eid = t.get("entry_id")
            if eid is None:
                continue
            if t.get("rank", 0) > 0:
                taken.add(eid)
            prt = t.get("per_rank_text") or []
            desc = (prt[0] if prt else "") or ""
            desc = re.sub(r"\s+", " ", desc).strip()[:160]
            nodes.append({
                "id": eid, "name": t.get("name") or "?", "icon": t.get("icon") or "",
                # `or` (not get-default) so an explicit null grid value coerces to a number
                "row": t.get("grid_row") or 0, "col": t.get("grid_col") or 0,
                "max": t.get("max_ranks") or 1, "slug": slug,
                "label": tree.get("label") or slug, "desc": desc,
            })
    return taken, nodes


import urllib.parse  # noqa: E402


def lua_str(s):
    return '"' + str(s).replace("\\", "\\\\").replace('"', '\\"') + '"'


def take_rate(cids, builds):
    """{n, pct} take-rate over the given character ids using precomputed builds."""
    counts, n = {}, 0
    for cid in cids:
        taken, _nodes = builds.get(cid, (set(), []))
        if taken:
            n += 1
            for eid in taken:
                counts[eid] = counts.get(eid, 0) + 1
    pct = {eid: round(c * 100 / n) for eid, c in counts.items()} if n else {}
    return {"n": n, "pct": pct}


def main():
    global THROTTLE
    ap = argparse.ArgumentParser()
    ap.add_argument("--top", type=int, default=20, help="dungeon mode: top-N performers per spec")
    ap.add_argument("--difficulty", default="mythic", help="dungeon mode difficulty")
    ap.add_argument("--zg", action="store_true",
                    help="Zul'Gurub raid mode: pool the top-N of each difficulty (normal/heroic/mythic/ascended)")
    ap.add_argument("--both", action="store_true",
                    help="bake BOTH raid (ZG) and dungeon take-rates over one shared set of trees (for the in-game toggle)")
    ap.add_argument("--top-per-diff", dest="top_per_diff", type=int, default=10,
                    help="ZG mode: how many top raiders to take from each difficulty (default 10)")
    ap.add_argument("--class", dest="only_class", help="limit to one class's specs")
    ap.add_argument("--throttle", type=float, default=0.5, help="seconds to pause after each request (politeness)")
    ap.add_argument("--workers", type=int, default=2, help="concurrent armory fetches (lower = gentler)")
    ap.add_argument("--out", default=os.path.join(os.path.dirname(__file__), "..", "BisBuddy", "TalentData.lua"))
    args = ap.parse_args()
    THROTTLE = args.throttle

    specs = parse_specs(discover_specroles())
    if args.only_class:
        specs = {k: v for k, v in specs.items() if k.split("|")[0] == args.only_class}
    print(f"specs to process: {len(specs)}")

    # per-class node registry (union of positions/names seen across all its specs)
    class_nodes = {}          # class -> { entry_id: node }
    class_tree_label = {}     # class -> { slug: label }
    take = {}                 # spec_key -> { n, pct{} }

    for spec_key, role in sorted(specs.items()):
        cls, spec = spec_key.split("|", 1)
        metric = "healing" if role == "healer" else "dps"

        # gather ranking rows per source we want to bake
        src_rows = {}                                       # "raid"/"dungeon" -> [rows]
        if args.both or args.zg:
            zg = top_performers_zg(cls, spec, metric, args.top_per_diff)
            if zg:
                src_rows["raid"] = zg
        if args.both or not args.zg:
            dg = top_performers(cls, spec, metric, args.difficulty, args.top)
            if dg:
                src_rows["dungeon"] = dg
        if args.zg and not args.both and "raid" not in src_rows:   # --zg alone: fall back to dungeon
            dg = top_performers(cls, spec, metric, args.difficulty, args.top)
            if dg:
                src_rows["dungeon"] = dg
        if not src_rows:
            print(f"  {spec_key} ({metric}): no rankings, skipped")
            continue

        # fetch each unique character's build ONCE, shared across sources
        all_cids, seen = [], set()
        for rows in src_rows.values():
            for r in rows:
                cid = r["character_id"]
                if cid not in seen:
                    seen.add(cid); all_cids.append(cid)
        builds = {}
        with concurrent.futures.ThreadPoolExecutor(args.workers) as ex:
            for cid, res in zip(all_cids, ex.map(build_of, all_cids)):
                builds[cid] = res

        # tree grid = union of every node seen across all sources' builds
        reg = class_nodes.setdefault(cls, {})
        labels = class_tree_label.setdefault(cls, {})
        for taken, nodes in builds.values():
            for nd in nodes:
                reg.setdefault(nd["id"], nd)               # first-seen position/name wins
                labels.setdefault(nd["slug"], nd["label"])

        # per-source take-rates
        rates = {sn: take_rate([r["character_id"] for r in rows], builds)
                 for sn, rows in src_rows.items()}
        take[spec_key] = rates
        summary = " ".join(f"{sn}={rates[sn]['n']}" for sn in sorted(rates))
        greens = max((sum(1 for p in r["pct"].values() if p >= 80) for r in rates.values()), default=0)
        print(f"  {spec_key} ({metric}): {summary} builds, {greens} green")

    # emit
    present = set()
    for rates in take.values():
        present.update(rates.keys())
    src_list = [s for s in ("raid", "dungeon") if s in present]
    zg_note = "raid=ZG(phase1) top-%d/difficulty pooled" % args.top_per_diff
    dg_note = "dungeon=top-%d %s" % (args.top, args.difficulty)
    source_note = "coa.ascensionlogs.gg - " + " ; ".join(
        [n for n, s in ((zg_note, "raid"), (dg_note, "dungeon")) if s in present])
    lines = ["-- Generated by generator/talents_generate.py - DO NOT EDIT BY HAND",
             "-- Source: " + source_note,
             "BisBuddyTalents = { generatedAt = %s, sources = {%s}, trees = {}, takeRates = {} }"
             % (lua_str(time.strftime("%Y-%m-%d")), ",".join(lua_str(s) for s in src_list))]
    # class tree grids
    tree_order = {}  # from specRoles? fall back to sorted slugs; keep class trees ordered by first-seen col span
    for cls in sorted(class_nodes):
        nodes = list(class_nodes[cls].values())
        by_slug = {}
        for nd in nodes:
            by_slug.setdefault(nd["slug"], []).append(nd)
        order = sorted(by_slug.keys())
        lines.append("BisBuddyTalents.trees[%s] = (function() return {" % lua_str(cls))
        lines.append("  order = {%s}," % ",".join(lua_str(s) for s in order))
        lines.append("  trees = {")
        for slug in order:
            lines.append("    [%s] = { label = %s, nodes = {" % (lua_str(slug), lua_str(class_tree_label[cls].get(slug, slug))))
            for nd in sorted(by_slug[slug], key=lambda x: (x["row"], x["col"])):
                lines.append("      {id=%d,name=%s,icon=%s,row=%d,col=%d,max=%d,desc=%s}," % (
                    nd["id"], lua_str(nd["name"]), lua_str(nd["icon"]), nd["row"], nd["col"],
                    nd["max"], lua_str(nd.get("desc", ""))))
            lines.append("    } },")
        lines.append("  },")
        lines.append("} end)()")
    # per-spec take-rates, nested by source (raid / dungeon)
    for spec_key in sorted(take):
        rates = take[spec_key]
        parts = []
        for sn in ("raid", "dungeon"):
            if sn in rates:
                r = rates[sn]
                body = ",".join("[%d]=%d" % (eid, p) for eid, p in sorted(r["pct"].items()))
                parts.append("%s={n=%d,pct={%s}}" % (sn, r["n"], body))
        lines.append("BisBuddyTalents.takeRates[%s] = { %s }" % (lua_str(spec_key), ", ".join(parts)))

    out = os.path.abspath(args.out)
    with open(out, "w") as f:
        f.write("\n".join(lines) + "\n")
    size = os.path.getsize(out)
    print(f"\nwrote {out}: {len(class_nodes)} class trees, {len(take)} specs, {size//1024} KB")


if __name__ == "__main__":
    main()
