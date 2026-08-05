# BisBuddy (private / in-development)

BiS ranks + upgrade hints on tooltips and loot drops for **Ascension WoW – Conquest of Azeroth** (3.3.5a). Data from [coa.bisbeard.com](https://coa.bisbeard.com). Type `/bb` in game.

> **Private repo.** `BisBuddy/Data.lua` is derived from bisbeard's item database + stat weights. Keep this repo private and BisBuddy guild-only until the provenance/permission question with the bisbeard dev is settled.

## Install (test on any machine)

Copy the **`BisBuddy/`** folder into your WoW `Interface/AddOns/` directory, then `/reload`. That's the whole addon — everything else here is dev tooling and is ignored by the game.

## Dev vs. release builds

The DBM-style "you're out of date" broadcast is gated by the `.toc` **Version**:

- **`X.Y.Z-dev`** → **silent**: never broadcasts its version, so your own testing never nags the guild. The login banner shows `[dev - version broadcasts off]`.
- **`X.Y.Z`** (no `-dev`) → the guild **release**: broadcasts normally.

Keep this repo's `BisBuddy/BisBuddy.toc` on a `-dev` version. To cut a guild release:

```sh
./build-bisbuddy.sh        # macOS; writes BisBuddy-X.Y.Z-dev.zip (silent) + BisBuddy-X.Y.Z.zip (release)
```

Give the guild **only** the non-`-dev` zip. Test with the `-dev` one (or just the local `BisBuddy/` folder).

## Refresh the data (when bisbeard updates)

```sh
python3 tools/generator/bisbuddy_generate.py --check                 # did bisbeard change? (1 tiny request)
python3 tools/generator/bisbuddy_generate.py --out BisBuddy/Data.lua --top 25   # regenerate (uses cached chunks)
```

Be considerate — a chunk cache (`tools/generator/.chunkcache/`, gitignored) means a re-scrape only downloads what actually changed. Talents: `python3 tools/generator/talents_generate.py` (ascensionlogs; slower, run sparingly).

## Test (offline harness)

```sh
cd tools && luajit dev/harness_bisbuddy.lua      # loads the real Data.lua + addon in a stub WoW env
```

## Transfer between machines

```sh
git clone git@github.com:Leemo94/BisBuddy.git    # or the https URL
# ...work / test / build...
git add -A && git commit -m "wip" && git push
```
