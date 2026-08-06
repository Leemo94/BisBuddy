#!/usr/bin/env python3
"""BisBuddy data generator.

Pulls per-spec stat weights + the full item database from coa.bisbeard.com
(the same data the site itself uses) and emits BisBuddy/Data.lua with the
top-N ranked items per slot per spec.

Usage:
  python3 bisbuddy_generate.py                # full online run
  python3 bisbuddy_generate.py --check        # just compare data versions
  python3 bisbuddy_generate.py --cache DIR    # reuse cached items/weights json
  python3 bisbuddy_generate.py --top 25       # ranks per slot (default 25)

The item chunks are transported obfuscated (rotate + keyed XOR + gzip); this
mirrors the site's own client-side decode: for chunk index k the bytes are
un-rotated by k*7, XORed with "bisbeard-gear-planner-2024"+str(k), gunzipped,
and hash-checked as sha256(raw + uint32_be(k)) == chunk name.
"""

import argparse
import concurrent.futures
import gzip
import hashlib
import json
import os
import re
import sys
import time
import urllib.request

SITE = "https://coa.bisbeard.com"
API = "https://gear-planner-api.bisbeard.workers.dev"
OBF_KEY = "bisbeard-gear-planner-2024"
HEADERS = {"Origin": SITE, "User-Agent": "Mozilla/5.0 (BisBuddy generator)"}

MELEE_SLOTS = {"One-Hand", "Two-Hand", "Main Hand", "Off Hand"}
RANGED_SLOTS = {"Ranged"}
SKIP_SLOTS = {"Unknown", ""}
DPS_RE = re.compile(r"\(([\d.]+) damage per second\)")


def fetch(url, binary=False):
    req = urllib.request.Request(url, headers=HEADERS)
    data = urllib.request.urlopen(req, timeout=60).read()
    return data if binary else data.decode("utf-8")


def discover_spec_roles_url():
    html = fetch(SITE + "/")
    m = re.search(r'src="(/assets/index-[^"]+\.js)"', html)
    if not m:
        raise SystemExit("Could not find main bundle in index.html (site layout changed?)")
    bundle = fetch(SITE + m.group(1))
    m = re.search(r'"(assets/specRoles-[^"]+\.js)"', bundle) or re.search(r'(assets/specRoles-[^"\']+\.js)', bundle)
    if not m:
        raise SystemExit("Could not find specRoles module in bundle (site layout changed?)")
    return SITE + "/" + m.group(1)


def spec_roles_ver(url):
    """The content hash baked into the specRoles filename (changes when bisbeard
    updates its stat weights / proficiency)."""
    m = re.search(r"specRoles-([A-Za-z0-9_-]+)\.js", url or "")
    return m.group(1) if m else "?"


def parse_weights(src):
    """Extract {"Class|Spec": {statKey: weight}} from the specRoles module."""
    entries = [(m.group(1), m.start()) for m in re.finditer(r'"([A-Za-z \'-]+\|[A-Za-z \'-]+)":\{', src)]
    weights = {}
    for i, (key, pos) in enumerate(entries):
        end = entries[i + 1][1] if i + 1 < len(entries) else len(src)
        block = src[pos:end]
        m = re.search(r"weights:\{([^}]*)\}", block)
        if not m:
            continue
        w = {}
        for pair in m.group(1).split(","):
            if ":" in pair:
                k, v = pair.split(":", 1)
                try:
                    w[k.strip().strip('"')] = float(v)
                except ValueError:
                    pass
        if w:
            weights[key] = w
    if not weights:
        raise SystemExit("Parsed zero spec weight tables (specRoles format changed?)")
    return weights


# ---- weapon / armor proficiency (so we don't rank gear a spec can't equip) ----
# item `type` (and the client's GetItemInfo subType) use varied/plural names;
# bisbeard's proficiency lists use these singular names.
WEAPON_TYPE_MAP = {
    "Swords": "Sword", "One-Handed Swords": "Sword", "Two-Handed Swords": "Sword",
    "Daggers": "Dagger", "Axes": "Axe", "Two-Handed Axes": "Axe",
    "Maces": "Mace", "Two-Handed Maces": "Mace", "Fist Weapons": "Fist",
    "Staves": "Staff", "Polearms": "Polearm", "Wands": "Wand", "Wand": "Wand",
    "Bows": "Bow", "Guns": "Gun", "Crossbows": "Crossbow", "Thrown": "Thrown",
}
WEAPON_SLOTS = {"One-Hand", "Two-Hand", "Main Hand", "Off Hand", "Ranged"}
ARMOR_SLOTS = {"Head", "Shoulders", "Chest", "Wrists", "Hands", "Waist", "Legs", "Feet"}
RANGED_WEAPON_TYPES = {"Gun", "Bow", "Crossbow", "Wand", "Thrown"}
ARMOR_TYPES = {"Cloth", "Leather", "Mail", "Plate"}


def _balanced(s, start):
    depth = 0
    for i in range(start, len(s)):
        if s[i] == "{":
            depth += 1
        elif s[i] == "}":
            depth -= 1
            if depth == 0:
                return s[start:i + 1]
    return ""


def parse_proficiency(src):
    """Extract weapon + armor proficiency from the specRoles module:
    { 'weap': {Class: {allowedTypes, shield, noOneHanded, noTwoHanded}},
      'armor': {Class: [types]},
      'rangedOverride': {SpecName: [types]} }."""
    prof = {"weap": {}, "armor": {}, "rangedOverride": {}}
    m = re.search(r"\bkt=\{", src)
    if m:
        kt = _balanced(src, m.end() - 1)
        for cm in re.finditer(r'("?[\w \'-]+"?):\{(dualWield:[^}]*?allowedTypes:\[[^\]]*\][^}]*)\}', kt):
            cls = cm.group(1).strip('"')
            body = cm.group(2)
            at = re.search(r"allowedTypes:\[([^\]]*)\]", body)
            no1 = re.search(r"noOneHanded:\[([^\]]*)\]", body)
            no2 = re.search(r"noTwoHanded:\[([^\]]*)\]", body)
            prof["weap"][cls] = {
                "allowedTypes": re.findall(r'"([^"]+)"', at.group(1)) if at else [],
                "shield": "shield:!0" in body,
                "dualWield": "dualWield:!0" in body,
                "noOneHanded": re.findall(r'"([^"]+)"', no1.group(1)) if no1 else [],
                "noTwoHanded": re.findall(r'"([^"]+)"', no2.group(1)) if no2 else [],
            }
    am = re.search(r'\{[A-Za-z"][^{}]*Runemaster:\["Cloth","Leather"\]\}', src)
    if am:
        for a in re.finditer(r'("?[\w \'-]+"?):\[((?:"[^"]+",?)+)\]', am.group(0)):
            prof["armor"][a.group(1).strip('"')] = re.findall(r'"([^"]+)"', a.group(2))
    for rm in re.finditer(r'([\w \'-]+):\{[^{}]*allowedRangedWeaponTypes:\[([^\]]*)\]', src):
        prof["rangedOverride"][rm.group(1).strip('"')] = re.findall(r'"([^"]+)"', rm.group(2))
    return prof


def can_use(spec_key, item, prof):
    """True if the spec can equip this item (weapon type / armor type / shield)."""
    if not prof or not prof.get("weap"):
        return True
    cls, spec = (spec_key.split("|", 1) + [""])[:2]
    w = prof["weap"].get(cls)
    slot = item.get("slot")
    typ = item.get("type")
    if slot == "Shield":
        return bool(w and w["shield"])
    if slot in ARMOR_SLOTS and typ in ARMOR_TYPES:
        return typ in prof["armor"].get(cls, [])
    if slot in WEAPON_SLOTS:
        wt = WEAPON_TYPE_MAP.get(typ)
        if not wt:
            return False  # relics / fishing poles / unknown weapon subtype
        if not w:
            return True
        if slot == "Ranged":
            ov = prof["rangedOverride"].get(spec)
            allowed = set(ov) if ov else (set(w["allowedTypes"]) & RANGED_WEAPON_TYPES)
            return wt in allowed
        if slot == "Off Hand" and not w.get("dualWield"):
            return False  # off-hand-only weapon requires dual-wield
        allowed = set(w["allowedTypes"])
        if slot in ("One-Hand", "Main Hand", "Off Hand"):
            allowed -= set(w["noOneHanded"])
        elif slot == "Two-Hand":
            allowed -= set(w["noTwoHanded"])
        return wt in allowed
    return True


def get_manifest():
    return json.loads(fetch(f"{API}/api/data/manifest?reader=2"))


def decode_chunk(data, index):
    length = len(data)
    n = (index * 7) % max(1, length)
    rot = bytes(data[(a - n + length) % length] for a in range(length))
    key = (OBF_KEY + str(index)).encode()
    x = bytes(b ^ key[j % len(key)] for j, b in enumerate(rot))
    return json.loads(gzip.decompress(x))


CHUNK_CACHE = os.path.join(os.path.dirname(__file__), ".chunkcache")


def fetch_items(manifest, cache_dir=CHUNK_CACHE):
    """Fetch + decode all item chunks. Each chunk name is its own content hash,
    so decoded chunks are cached by name on disk: a re-scrape only downloads the
    chunks bisbeard actually changed (usually a handful, not all 28)."""
    chunks = manifest["chunks"]
    if cache_dir:
        os.makedirs(cache_dir, exist_ok=True)
    stats = {"cached": 0, "fetched": 0}

    def get(i):
        name = chunks[i]
        cpath = os.path.join(cache_dir, name + ".json") if cache_dir else None
        if cpath and os.path.exists(cpath):
            with open(cpath) as fh:
                stats["cached"] += 1
                return json.load(fh)
        data = fetch(f"{API}/api/data/chunks/{name}", binary=True)
        if hashlib.sha256(data + i.to_bytes(4, "big")).hexdigest() != name:
            raise RuntimeError(f"chunk {i} failed hash check")
        part = decode_chunk(data, i)
        if cpath:
            with open(cpath, "w") as fh:
                json.dump(part, fh)
        stats["fetched"] += 1
        return part

    items = []
    with concurrent.futures.ThreadPoolExecutor(8) as ex:
        for part in ex.map(get, range(len(chunks))):
            items.extend(part)
    print(f"chunks: {stats['cached']} unchanged (from cache), {stats['fetched']} downloaded")
    # prune cache files no longer referenced by the manifest
    if cache_dir:
        keep = {c + ".json" for c in chunks}
        for fn in os.listdir(cache_dir):
            if fn.endswith(".json") and fn not in keep:
                try:
                    os.remove(os.path.join(cache_dir, fn))
                except OSError:
                    pass
    return items


def item_dps(item):
    m = DPS_RE.search(item.get("description") or "")
    return float(m.group(1)) if m else None


# Short codes for the weightable stats, so we can bake each ranked item's raw
# stats compactly (for the addon's local weight-override re-ranking). Keys are
# bisbeard stat keys; the addon has the inverse map. Weapon/ranged DPS is baked
# as "dps" and applied by slot. Non-weightable stats (resists, mana, school
# spell power) are intentionally skipped - they never carry a weight.
STAT_CODE = {
    "intellect": "int", "strength": "str", "agility": "agi", "stamina": "sta",
    "spirit": "spi", "spellPower": "sp", "healingPower": "hp", "critRating": "cr",
    "hasteRating": "ht", "hitRating": "hit", "resilienceRating": "res",
    "expertise": "exp", "attackPower": "ap", "rangedAttackPower": "rap",
    "feralAttackPower": "fap", "armorPenetration": "arp", "spellPenetration": "spen",
    "mp5": "mp5", "hp5": "hp5", "defense": "def", "dodge": "dg", "parry": "par",
    "block": "blk", "blockValue": "bv", "shieldBlockValue": "sbv", "armor": "arm",
}


def coded_stats(item):
    """Item's weightable stats as {short_code: value}, plus 'dps' for weapons.
    Matches score_item's inputs, so the addon reproduces the score locally."""
    out = {}
    for k, v in (item.get("stats") or {}).items():
        code = STAT_CODE.get(k)
        if code and isinstance(v, (int, float)) and v != 0:
            out[code] = v
    dps = item_dps(item)
    if dps and item.get("slot") in (MELEE_SLOTS | RANGED_SLOTS):
        out["dps"] = round(dps, 1)
    return out


def score_item(item, weights):
    stats = item.get("stats") or {}
    score = 0.0
    hit = False
    for k, v in stats.items():
        w = weights.get(k)
        if w and isinstance(v, (int, float)):
            score += v * w
            hit = True
    slot = item.get("slot")
    dps = item_dps(item)
    if dps:
        if slot in RANGED_SLOTS and weights.get("rangedDps"):
            score += dps * weights["rangedDps"]
            hit = True
        elif slot in MELEE_SLOTS and weights.get("weaponDps"):
            score += dps * weights["weaponDps"]
            hit = True
    return score if hit else None


def lua_str(s):
    return '"' + str(s).replace("\\", "\\\\").replace('"', '\\"') + '"'


# CoA raid-tier phases as bisbeard classifies them (verified against item
# `phase` field vs raid end-boss sources: Ragnaros=2, C'Thun=4, Kel'Thuzad=5).
PHASE_LABELS = {
    1: "Pre-Raid + Zul'Gurub",
    2: "Molten Core",
    3: "Blackwing Lair",
    4: "Ahn'Qiraj",
    5: "Naxxramas",
}


def item_category(it):
    """0 = normal PvE, 1 = PvP, 2 = Bloodforged. Detected from either the
    sourceCategory or the difficulty `version` so both classifications count."""
    sc = it.get("sourceCategory")
    v = it.get("version") or ""
    if sc == "pvp" or v == "PvP":
        return 1
    if sc == "bloodforged" or "Bloodforged" in v:
        return 2
    return 0


# Difficulty tiers. bisbeard's own filter collapses everything Mythic into one
# "Mythic", but on the live realm Mythic+ keystones (Mythic 10-40) aren't out
# yet, so we split base Mythic ("Mythic 0") from the keystones and rank them as
# the highest, opt-in tier. Everything untiered (Crafted, Worldforged "Phase N",
# Vendor, quests, ...) reads as Normal. Cumulative order: 1 < 2 < 3 < 4 < 5.
DIFF_LABELS = {1: "Normal", 2: "Heroic", 3: "Mythic", 4: "Ascended", 5: "Mythic+"}


def difficulty_tier(it):
    v = (it.get("version") or "").strip()
    if v == "Ascended":
        return 4
    if v.startswith("Mythic") and any(c.isdigit() for c in v):
        return 5  # Mythic+ keystones (Mythic 10-40) - not on the live realm yet
    if "Mythic" in v:
        return 3  # base Mythic ("Mythic 0")
    if "Heroic" in v:
        return 2
    return 1  # Normal + all untiered (crafted / worldforged / vendor / quest)


def build(weights, items, topn, prof=None, max_phase_cap=None):
    """Return (cells, pool, phases, skipped_class).

    cells[spec][phase][tier][slot] = [(id, score), ...] where phase and tier are
    EXACT (not cumulative). The addon reconstructs any cumulative (phase-cap,
    difficulty-cap) view by merging every cell with phase <= cap and tier <= cap
    then taking the top of the merged list -- provably the correct top-N because
    any item in the cumulative top-N is in the top-N of its own (phase,tier)
    cell. PvP/Bloodforged are cat-tagged in the pool and filtered by the addon.
    """
    # class-locked leftovers from the original game can't be worn by CoA classes
    usable = []
    skipped_class = 0
    for it in items:
        cls = it.get("classes")
        if cls and cls != ["All"]:
            skipped_class += 1
            continue
        if it.get("slot") in SKIP_SLOTS or not it.get("id"):
            continue
        usable.append(it)

    item_phases = [it["phase"] for it in usable if isinstance(it.get("phase"), int)]
    max_phase = min(max(item_phases or [1]), max_phase_cap or 99)
    phases = list(range(1, max_phase + 1))

    cells = {}
    pool = {}
    for spec, w in sorted(weights.items()):
        buckets = {}  # (phase, tier, slot) -> [(score, item)]
        for it in usable:
            iphase = it.get("phase") if isinstance(it.get("phase"), int) else 1
            if iphase > max_phase:
                continue
            if not can_use(spec, it, prof):   # skip gear this spec can't equip
                continue
            s = score_item(it, w)
            if s and s > 0:
                buckets.setdefault((iphase, difficulty_tier(it), it["slot"]), []).append((s, it))
        spec_cells = {}
        for (iphase, tier, slot), scored in buckets.items():
            scored.sort(key=lambda t: (-t[0], t[1]["name"]))
            top = scored[:topn]
            spec_cells.setdefault(iphase, {}).setdefault(tier, {})[slot] = \
                [(int(it["id"]), round(s, 1)) for s, it in top]
            for s, it in top:
                iid = int(it["id"])
                if iid not in pool:
                    src = (it.get("source") or "?")[:60]
                    pool[iid] = (it.get("name") or "?", it.get("version") or "", src,
                                 iphase, difficulty_tier(it), item_category(it),
                                 coded_stats(it), it.get("sourceCategory") or "",
                                 it.get("type") or "")
        cells[spec] = spec_cells
    return cells, pool, phases, skipped_class


def emit_lua(out_path, manifest, weights, cells, pool, phases, total_items, prof=None, specroles_ver="?",
             enchants=None):
    specAlias = {k.split("|")[1]: k for k in weights}
    lines = []
    push = lines.append
    push("-- Generated by generator/bisbuddy_generate.py - DO NOT EDIT BY HAND")
    push("-- Data source: coa.bisbeard.com (stat weights + item database)")
    push("-- cells[spec][phase][tier][slot] = { {itemId, score}, ... } (EXACT")
    push("-- phase + difficulty tier; the addon merges cells <= its phase/diff caps)")
    push("BisBuddyData = {")
    push('  dataVersion = %s,' % lua_str(manifest["version"][:12]))
    push('  specRolesVer = %s,' % lua_str(specroles_ver))
    push('  publishedAt = %s,' % lua_str(manifest.get("publishedAt", "?")))
    push('  generatedAt = %s,' % lua_str(time.strftime("%Y-%m-%d")))
    push("  totalItems = %d," % total_items)
    push("  maxPhase = %d," % (max(phases) if phases else 1))
    push("  maxDiff = %d," % max(DIFF_LABELS))
    push("  weights = {},")
    push("  specAlias = {},")
    push("  phaseLabels = {},")
    push("  diffLabels = {},")
    push("  cells = {},")
    push("  items = {},")
    push("  prof = { classes = {}, rangedOverride = {} },")
    push("  enchants = {},")
    push("}")
    # weapon/armor proficiency, so the addon can also skip unusable hovered items
    if prof and prof.get("weap"):
        def lualist(xs):
            return "{" + ",".join(lua_str(x) for x in xs) + "}"
        for cls in sorted(prof["weap"]):
            w = prof["weap"][cls]
            push("BisBuddyData.prof.classes[%s] = { weap = %s, armor = %s, shield = %s, dw = %s, no1 = %s, no2 = %s }" % (
                lua_str(cls), lualist(w["allowedTypes"]), lualist(prof["armor"].get(cls, [])),
                "true" if w["shield"] else "false", "true" if w.get("dualWield") else "false",
                lualist(w["noOneHanded"]), lualist(w["noTwoHanded"])))
        for spec in sorted(prof.get("rangedOverride", {})):
            push("BisBuddyData.prof.rangedOverride[%s] = %s" % (
                lua_str(spec), lualist(prof["rangedOverride"][spec])))
    # weights + alias + phase/diff labels (small, plain)
    for spec in sorted(weights):
        w = weights[spec]
        body = ", ".join("%s = %g" % (k, w[k]) for k in sorted(w))
        push("BisBuddyData.weights[%s] = { %s }" % (lua_str(spec), body))
    for name in sorted(specAlias):
        push("BisBuddyData.specAlias[%s] = %s" % (lua_str(name), lua_str(specAlias[name])))
    for p in phases:
        push("BisBuddyData.phaseLabels[%d] = %s" % (p, lua_str(PHASE_LABELS.get(p, "Phase %d" % p))))
    for d in sorted(DIFF_LABELS):
        push("BisBuddyData.diffLabels[%d] = %s" % (d, lua_str(DIFF_LABELS[d])))
    # cells: one function-wrapped constructor per spec, nested phase -> tier ->
    # slot (keeps per-proto Lua 5.1 constant counts small).
    for spec in sorted(cells):
        push("BisBuddyData.cells[%s] = (function() return {" % lua_str(spec))
        for phase in sorted(cells[spec]):
            push("  [%d] = {" % phase)
            for tier in sorted(cells[spec][phase]):
                push("    [%d] = {" % tier)
                for slot in sorted(cells[spec][phase][tier]):
                    row = ",".join("{%d,%g}" % (iid, s) for iid, s in cells[spec][phase][tier][slot])
                    push("      [%s] = {%s}," % (lua_str(slot), row))
                push("    },")
            push("  },")
        push("} end)()")
    # item pool in function-wrapped batches:
    #   {name, version, source, phase, tier, cat, {statcode=val,...}, sourceCategory}
    # cat: 0 normal PvE, 1 PvP, 2 Bloodforged. The 7th field is the item's raw
    # weightable stats (+ "dps"), used only for local weight-override re-ranking.
    # The 8th field is bisbeard's sourceCategory (raid/dungeon/worldforged/rep/
    # quest/crafting/...), grouped by the addon into the Sources filter buckets.
    # The 9th field is bisbeard's item type (Cloth/Plate/Swords/...), used with the
    # baked proficiency to filter the wide slotPool for custom-weight re-ranking.
    ids = sorted(pool)
    BATCH = 1500
    for start in range(0, len(ids), BATCH):
        push("do local t = (function() return {")
        for iid in ids[start:start + BATCH]:
            n, v, src, ph, tier, cat, stats, scat, typ = pool[iid]
            statstr = "{" + ",".join("%s=%g" % (c, val) for c, val in sorted(stats.items())) + "}"
            push("  [%d] = {%s,%s,%s,%d,%d,%d,%s,%s,%s}," % (
                iid, lua_str(n), lua_str(v), lua_str(src), ph, tier, cat, statstr, lua_str(scat), lua_str(typ)))
        push("} end)() for k, v in pairs(t) do BisBuddyData.items[k] = v end end")
    # per-slot candidate pool (spec-agnostic): every pooled item grouped by slot, so
    # the addon can rank the WIDE usable pool when the user sets custom weights
    # (default weights still use bisbeard's curated cells; proficiency is applied in
    # the addon from each item's baked type = items[id][9]).
    slot_pool = {}
    for spec_cells in cells.values():
        for phase_map in spec_cells.values():
            for tier_map in phase_map.values():
                for slot, rows in tier_map.items():
                    bucket = slot_pool.setdefault(slot, set())
                    for iid, _s in rows:
                        bucket.add(iid)
    push("BisBuddyData.slotPool = {}")
    for slot in sorted(slot_pool):
        push("BisBuddyData.slotPool[%s] = {%s}" % (
            lua_str(slot), ",".join(str(i) for i in sorted(slot_pool[slot]))))
    # enchants: { {name, slot, {statcode=val,...}}, ... } - scored at runtime by
    # the active spec's weights (same stat codes as items[id][7]).
    if enchants:
        push("do local e = (function() return {")
        for name, slot, stats in enchants:
            statstr = "{" + ",".join("%s=%g" % (c, v) for c, v in sorted(stats.items())) + "}"
            push("  {%s,%s,%s}," % (lua_str(name), lua_str(slot), statstr))
        push("} end)() for i = 1, #e do BisBuddyData.enchants[i] = e[i] end end")
    with open(out_path, "w") as f:
        f.write("\n".join(lines) + "\n")
    return len(ids)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--top", type=int, default=25)
    ap.add_argument("--phase", type=int, help="only rank items from phases <= N (default: all phases)")
    ap.add_argument("--out", default=os.path.join(os.path.dirname(__file__), "..", "BisBuddy", "Data.lua"))
    ap.add_argument("--cache", help="dir with items_full.json + weights.json (skip downloads)")
    ap.add_argument("--check", action="store_true", help="only compare live data version vs current Data.lua")
    args = ap.parse_args()

    manifest = get_manifest()
    live_ver = manifest["version"][:12]
    if args.check:
        baked_item, baked_sr = "<no Data.lua>", "?"
        try:
            with open(args.out) as f:
                txt = f.read()
            m = re.search(r'dataVersion = "([^"]+)"', txt)
            baked_item = m.group(1) if m else "?"
            m = re.search(r'specRolesVer = "([^"]+)"', txt)
            baked_sr = m.group(1) if m else "?"
        except OSError:
            pass
        live_sr = spec_roles_ver(discover_spec_roles_url())
        items_ok = baked_item == live_ver
        weights_ok = baked_sr == live_sr and baked_sr != "?"
        print(f"item DB:  live {live_ver} (published {manifest.get('publishedAt')})  baked {baked_item}  -> "
              + ("up to date" if items_ok else "CHANGED"))
        print(f"weights:  live {live_sr}  baked {baked_sr}  -> "
              + ("up to date" if weights_ok else ("CHANGED" if baked_sr != "?" else "unknown (regenerate online once to enable)")))
        print("ALL UP TO DATE" if (items_ok and weights_ok) else "REGENERATE (run without --check)")
        return

    specroles_ver = "?"
    if args.cache:
        weights = json.load(open(os.path.join(args.cache, "weights.json")))
        items = json.load(open(os.path.join(args.cache, "items_full.json")))
        try:
            prof = json.load(open(os.path.join(args.cache, "proficiency.json")))
        except OSError:
            prof = None
        print(f"cache: {len(items)} items, {len(weights)} specs, "
              f"proficiency {'loaded' if prof else 'MISSING'}")
    else:
        url = discover_spec_roles_url()
        print("specRoles:", url)
        src = fetch(url)
        specroles_ver = spec_roles_ver(url)
        weights = parse_weights(src)
        prof = parse_proficiency(src)
        print(f"parsed weights for {len(weights)} specs, "
              f"proficiency for {len(prof['weap'])} classes (specRolesVer {specroles_ver})")
        items = fetch_items(manifest)
        print(f"fetched {len(items)} items (version {live_ver}, published {manifest.get('publishedAt')})")

    if not prof or not prof.get("weap"):
        print("WARNING: no weapon/armor proficiency parsed - rankings will NOT be equip-filtered")

    cells, pool, phases, skipped_class = build(weights, items, args.top, prof, args.phase)

    # enchants (sourceCategory == "enchants"): keep those with weightable stats,
    # de-dup by (slot, name) preferring the richest-stat version.
    ench_map = {}
    for it in items:
        if it.get("sourceCategory") != "enchants":
            continue
        slot, name = it.get("slot"), it.get("name")
        if not slot or not name:
            continue
        st = coded_stats(it)
        if not st:
            continue  # resist-only / no-stat enchants aren't rankable
        k = (slot, name)
        prev = ench_map.get(k)
        if prev is None or sum(abs(v) for v in st.values()) > sum(abs(v) for v in prev.values()):
            ench_map[k] = st
    enchants = sorted(([name, slot, st] for (slot, name), st in ench_map.items()),
                      key=lambda e: (e[1], e[0]))
    print(f"enchants: {len(enchants)} rankable (of "
          f"{sum(1 for it in items if it.get('sourceCategory') == 'enchants')} total)")

    n_ids = emit_lua(os.path.abspath(args.out), manifest, weights, cells, pool, phases, len(items), prof,
                     specroles_ver, enchants)
    size = os.path.getsize(os.path.abspath(args.out))
    print(f"wrote {args.out}: {len(cells)} specs x {len(phases)} phases x {len(DIFF_LABELS)} tiers, "
          f"{n_ids} unique ranked items, {size//1024} KB "
          f"(skipped {skipped_class} old-class-locked items)")

    # sanity: merge cells like the addon would, PvE-only, and show #1 Two-Hand
    # per phase at each difficulty cap
    inv = cells.get("Tinker|Invention", {})

    def merged_top1(phase_cap, diff_cap, slot):
        acc = []
        for ph in range(1, phase_cap + 1):
            for ti in range(1, diff_cap + 1):
                for iid, s in inv.get(ph, {}).get(ti, {}).get(slot, []):
                    if pool[iid][5] == 0:  # PvE only
                        acc.append((s, iid))
        if not acc:
            return "(none)"
        acc.sort(reverse=True)
        s, iid = acc[0]
        return f"{pool[iid][0]} [{pool[iid][1]}] {s:g}"

    print("\nInvention #1 Two-Hand (PvE), rows=phase cap, cols=difficulty cap:")
    print("  %-16s | %-30s | %-30s | %-30s | %s" % ("phase\\diff", "Normal", "Mythic (default)", "Ascended", "Mythic+"))
    for cap in phases:
        cols = [merged_top1(cap, d, "Two-Hand") for d in (1, 3, 4, 5)]
        print("  %-16s | %-30s | %-30s | %-30s | %s" % (PHASE_LABELS.get(cap, cap), *cols))


if __name__ == "__main__":
    main()
