--[[
	BisBuddy (Ascension WoW - Conquest of Azeroth, 3.3.5a)

	Uses coa.bisbeard.com's own stat weights + item database (baked into
	Data.lua by generator/bisbuddy_generate.py) to:
	  - show "#N BiS <slot> for <spec>" + upgrade % on item tooltips
	  - alert when a loot drop / loot roll is top-N BiS or an upgrade
	  - list the best items per slot: /bb top <slot>

	Spec is auto-detected via Ascension's SpecializationUtil; override with
	/bb spec <name>. Ranks are pure stat-weight math (like the site): procs
	and set bonuses are not scored.
]]

local ADDON_NAME = ...

local f = CreateFrame("Frame")
local db
local D -- BisBuddyData

-- active-spec state
local specKey = nil            -- e.g. "Tinker|Invention"
local specWeights = nil
local rankIndex = {}           -- itemId -> { slot=, rank=, score= } for the active spec
local specCheckedAt = 0
local warnedNoSpec = false

-- curated supplement (items bisbeard doesn't index) — see Extras.lua + db.userExtras
local extrasList = {}          -- { {id=, slot=, class=}, ... } injected into BuildRankIndex
local extraIds = {}            -- set of ids that came from the supplement (for tooltip tag)
local bbExtraLine = ""         -- last /bb extra capture line (for the copy popup)

-- caches
local equippedScoreCache = {}  -- invSlotId -> score (false = unscorable)
local dpsCache = {}            -- itemId -> dps (false = none)
local alertRecent = {}         -- itemId -> GetTime() of last alert

local function Print(msg)
	DEFAULT_CHAT_FRAME:AddMessage("|cff69ccf0BisBuddy:|r " .. msg)
end

--------------------------------------------------------------------------------
-- Out-of-date check (DBM-style): peers running the addon exchange versions over
-- hidden addon messages; if someone in your guild/group has a newer build, you
-- get told once in chat. Addons can't reach the internet, so this is how the
-- "you're out of date" nudge works.
--------------------------------------------------------------------------------

local ADDON_MSG_PREFIX = "BisBuddyVer"
local myVersion = (GetAddOnMetadata and GetAddOnMetadata(ADDON_NAME, "Version")) or nil
-- Dev builds carry a "-dev" suffix in the .toc Version and stay SILENT: they never
-- broadcast their version, so your own testing never nags the guild that they're
-- "out of date". The guild release (build-release.sh strips "-dev") broadcasts normally.
local DEV_BUILD = ((myVersion or ""):lower():find("dev")) ~= nil
local warnedOutOfDate = false
local lastVersionCast = 0
local lastRollLink              -- most recent loot-roll item (for "/bb loot" with no arg)

-- is version string a strictly newer than b? (numeric, e.g. "1.2.0" > "1.1.9")
local function VersionNewer(a, b)
	local ta, tb = {}, {}
	for n in string.gmatch(a or "", "%d+") do ta[#ta + 1] = tonumber(n) end
	for n in string.gmatch(b or "", "%d+") do tb[#tb + 1] = tonumber(n) end
	for i = 1, math.max(#ta, #tb) do
		local x, y = ta[i] or 0, tb[i] or 0
		if x ~= y then return x > y end
	end
	return false
end

local function GroupChannel()
	if GetNumRaidMembers and GetNumRaidMembers() > 0 then
		return "RAID"
	elseif GetNumPartyMembers and GetNumPartyMembers() > 0 then
		return "PARTY"
	end
	return nil
end

local function BroadcastVersion()
	if DEV_BUILD or not myVersion or not SendAddonMessage then
		return   -- dev builds never announce themselves (no "you're out of date" nudge)
	end
	local now = GetTime and GetTime() or 0
	if now - lastVersionCast < 8 then
		return -- throttle
	end
	lastVersionCast = now
	if IsInGuild and IsInGuild() then
		SendAddonMessage(ADDON_MSG_PREFIX, "V" .. myVersion, "GUILD")
		SendAddonMessage(ADDON_MSG_PREFIX, "Q", "GUILD")
	end
	local ch = GroupChannel()
	if ch then
		SendAddonMessage(ADDON_MSG_PREFIX, "V" .. myVersion, ch)
		SendAddonMessage(ADDON_MSG_PREFIX, "Q", ch)
	end
end

local function OnVersionMessage(prefix, msg, channel, sender)
	if prefix ~= ADDON_MSG_PREFIX or not msg or not myVersion then
		return
	end
	if UnitName and sender == UnitName("player") then
		return -- ignore our own broadcast
	end
	if msg == "Q" then -- a peer is asking; tell just them our version (dev stays quiet)
		if not DEV_BUILD and sender and SendAddonMessage then
			SendAddonMessage(ADDON_MSG_PREFIX, "V" .. myVersion, "WHISPER", sender)
		end
		return
	end
	local ver = string.match(msg, "^V(.+)$")
	if ver and not warnedOutOfDate and VersionNewer(ver, myVersion) then
		warnedOutOfDate = true
		Print(format("|cffff8800a newer version (v%s) is out|r - you have v%s. Grab the latest from wherever you got it (ask your guild).", ver, myVersion))
	end
end

--------------------------------------------------------------------------------
-- Stat mapping: GetItemStats() keys -> bisbeard weight keys
--------------------------------------------------------------------------------

local STAT_KEY_MAP = {
	ITEM_MOD_INTELLECT_SHORT = "intellect",
	ITEM_MOD_STRENGTH_SHORT = "strength",
	ITEM_MOD_AGILITY_SHORT = "agility",
	ITEM_MOD_STAMINA_SHORT = "stamina",
	ITEM_MOD_SPIRIT_SHORT = "spirit",
	ITEM_MOD_SPELL_POWER_SHORT = "spellPower",
	ITEM_MOD_SPELL_DAMAGE_DONE_SHORT = "spellPower",
	ITEM_MOD_SPELL_HEALING_DONE_SHORT = "healingPower",
	ITEM_MOD_CRIT_RATING_SHORT = "critRating",
	ITEM_MOD_CRIT_MELEE_RATING_SHORT = "critRating",
	ITEM_MOD_CRIT_SPELL_RATING_SHORT = "critRating",
	ITEM_MOD_HASTE_RATING_SHORT = "hasteRating",
	ITEM_MOD_HIT_RATING_SHORT = "hitRating",
	ITEM_MOD_RESILIENCE_RATING_SHORT = "resilienceRating",
	ITEM_MOD_EXPERTISE_RATING_SHORT = "expertise",
	ITEM_MOD_ATTACK_POWER_SHORT = "attackPower",
	ITEM_MOD_RANGED_ATTACK_POWER_SHORT = "rangedAttackPower",
	ITEM_MOD_FERAL_ATTACK_POWER_SHORT = "feralAttackPower",
	ITEM_MOD_MANA_REGENERATION_SHORT = "mp5",
	ITEM_MOD_POWER_REGEN0_SHORT = "mp5",
	ITEM_MOD_HEALTH_REGENERATION_SHORT = "hp5",
	ITEM_MOD_HEALTH_REGEN_SHORT = "hp5",
	ITEM_MOD_ARMOR_PENETRATION_RATING_SHORT = "armorPenetration",
	ITEM_MOD_SPELL_PENETRATION_SHORT = "spellPenetration",
	ITEM_MOD_DEFENSE_SKILL_RATING_SHORT = "defense",
	ITEM_MOD_DODGE_RATING_SHORT = "dodge",
	ITEM_MOD_PARRY_RATING_SHORT = "parry",
	ITEM_MOD_BLOCK_RATING_SHORT = "block",
	ITEM_MOD_BLOCK_VALUE_SHORT = "blockValue",
	RESISTANCE0_NAME = "armor",
}

-- Fallback: map by the game's localized stat LABEL (_G[key]) as well, the way
-- GearWeights does for reliable detection on this custom client. These label
-- strings are the ones Ascension's client actually reports (confirmed against
-- GearWeights' bisbeard import table). If GetItemStats() ever returns a raw
-- key our STAT_KEY_MAP doesn't list, the label still resolves the weight.
local LABEL_TO_BIS_KEY = {
	["Intellect"] = "intellect", ["Strength"] = "strength", ["Agility"] = "agility",
	["Stamina"] = "stamina", ["Spirit"] = "spirit",
	["Spell Power"] = "spellPower", ["Bonus Healing"] = "healingPower",
	["Critical Strike Rating"] = "critRating", ["Haste Rating"] = "hasteRating",
	["Hit Rating"] = "hitRating", ["Resilience Rating"] = "resilienceRating",
	["Mana Per 5 Sec."] = "mp5", ["Health Per 5 Sec."] = "hp5",
	["Attack Power"] = "attackPower", ["Ranged Attack Power"] = "rangedAttackPower",
	["Feral Attack Power"] = "feralAttackPower",
	["Armor Penetration Rating"] = "armorPenetration", ["Spell Penetration"] = "spellPenetration",
	["Expertise Rating"] = "expertise", ["Armor"] = "armor",
	["Defense Rating"] = "defense", ["Dodge Rating"] = "dodge", ["Parry Rating"] = "parry",
	["Block Rating"] = "block", ["Block Value"] = "blockValue",
}

-- equip locations -> bisbeard slot names (for baseline + weapon dps kind)
local EQUIPLOC_TO_SLOT = {
	INVTYPE_HEAD = "Head", INVTYPE_NECK = "Neck", INVTYPE_SHOULDER = "Shoulders",
	INVTYPE_CLOAK = "Back", INVTYPE_CHEST = "Chest", INVTYPE_ROBE = "Chest",
	INVTYPE_WRIST = "Wrists", INVTYPE_HAND = "Hands", INVTYPE_WAIST = "Waist",
	INVTYPE_LEGS = "Legs", INVTYPE_FEET = "Feet", INVTYPE_FINGER = "Finger",
	INVTYPE_TRINKET = "Trinket", INVTYPE_2HWEAPON = "Two-Hand",
	INVTYPE_WEAPON = "One-Hand", INVTYPE_WEAPONMAINHAND = "Main Hand",
	INVTYPE_WEAPONOFFHAND = "Off Hand", INVTYPE_SHIELD = "Shield",
	INVTYPE_HOLDABLE = "Held In Off-hand", INVTYPE_RANGED = "Ranged",
	INVTYPE_RANGEDRIGHT = "Ranged", INVTYPE_THROWN = "Ranged",
}

local MELEE_SLOT = { ["One-Hand"] = true, ["Two-Hand"] = true, ["Main Hand"] = true, ["Off Hand"] = true }

-- inverse of the generator's STAT_CODE: baked short code -> bisbeard weight key.
-- Used to re-score baked item stats when the user sets custom weights.
local STAT_CODE_TO_KEY = {
	int = "intellect", str = "strength", agi = "agility", sta = "stamina", spi = "spirit",
	sp = "spellPower", hp = "healingPower", cr = "critRating", ht = "hasteRating",
	hit = "hitRating", res = "resilienceRating", exp = "expertise", ap = "attackPower",
	rap = "rangedAttackPower", fap = "feralAttackPower", arp = "armorPenetration",
	spen = "spellPenetration", mp5 = "mp5", hp5 = "hp5", def = "defense", dg = "dodge",
	par = "parry", blk = "block", bv = "blockValue", sbv = "shieldBlockValue", arm = "armor",
}

-- inverse of the above: bisbeard weight key -> short code, for /bb extra capture
local KEY_TO_STAT_CODE = {}
for code, key in pairs(STAT_CODE_TO_KEY) do
	if not KEY_TO_STAT_CODE[key] then KEY_TO_STAT_CODE[key] = code end
end

-- Fold the curated supplement (baked Extras.lua + personal db.userExtras) into
-- D.items so those items get names/stats, and build extrasList/extraIds so
-- BuildRankIndex can score + rank them alongside bisbeard's data. Idempotent.
local function MergeExtras()
	extrasList = {}
	extraIds = {}
	local function add(id, e)
		id = tonumber(id)
		if not id or extraIds[id] then return end
		if type(e) ~= "table" or not e.slot or type(e.stats) ~= "table" then return end
		if D and D.items and not D.items[id] then
			-- baked item shape: {name, version, source, phase, diff, category, stats}
			D.items[id] = { e.name or ("item " .. id), "Extra", e.source or "Extra", 1, 1, 0, e.stats }
		end
		extraIds[id] = true
		extrasList[#extrasList + 1] = { id = id, slot = e.slot, class = e.class }
	end
	if type(BisBuddyExtras) == "table" then          -- baked, shipped to everyone
		for id, e in pairs(BisBuddyExtras) do add(id, e) end
	end
	if db and type(db.userExtras) == "table" then    -- personal, captured via /bb extra save
		for id, e in pairs(db.userExtras) do add(id, e) end
	end
end

-- Stats shown (in order) in the /bb weights panel: bisbeard key + display label.
local WEIGHT_STATS = {
	{ "intellect", "Intellect" }, { "strength", "Strength" }, { "agility", "Agility" },
	{ "stamina", "Stamina" }, { "spirit", "Spirit" },
	{ "spellPower", "Spell Power" }, { "spellDamage", "Spell Damage" }, { "healingPower", "Healing Power" }, { "spellPenetration", "Spell Pen" },
	{ "critRating", "Crit" }, { "hasteRating", "Haste" }, { "hitRating", "Hit" }, { "expertise", "Expertise" },
	{ "attackPower", "Attack Power" }, { "rangedAttackPower", "Ranged AP" }, { "armorPenetration", "Armor Pen" },
	{ "weaponDps", "Weapon DPS" }, { "rangedDps", "Ranged DPS" },
	{ "defense", "Defense" }, { "dodge", "Dodge" }, { "parry", "Parry" },
	{ "block", "Block" }, { "blockValue", "Block Value" }, { "mp5", "MP5" },
}

-- bisbeard slot -> inventory slot ids for the equipped baseline
local SLOT_INV = {
	["Head"] = { 1 }, ["Neck"] = { 2 }, ["Shoulders"] = { 3 }, ["Chest"] = { 5 },
	["Waist"] = { 6 }, ["Legs"] = { 7 }, ["Feet"] = { 8 }, ["Wrists"] = { 9 },
	["Hands"] = { 10 }, ["Finger"] = { 11, 12 }, ["Trinket"] = { 13, 14 },
	["Back"] = { 15 }, ["Two-Hand"] = { 16, 17 }, ["One-Hand"] = { 16, 17 },
	["Main Hand"] = { 16 }, ["Off Hand"] = { 17 }, ["Shield"] = { 17 },
	["Held In Off-hand"] = { 17 }, ["Ranged"] = { 18 },
}

-- one-hand / off-hand slots that a two-hander occupies both of: equipping one of
-- these means giving up an equipped 2H, so it's compared against that 2H.
local HANDS_SLOT = {
	["One-Hand"] = true, ["Main Hand"] = true, ["Off Hand"] = true,
	["Shield"] = true, ["Held In Off-hand"] = true,
}

--------------------------------------------------------------------------------
-- Spec detection + rank index
--------------------------------------------------------------------------------

local MERGE_DEPTH = 15  -- baked cell depth; merged ranks are exact up to this

local activeSlotRanks = {}  -- slot -> merged, score-sorted { {id,score}, ... }
local RenderBrowse          -- fwd decl: re-paints the "BiS Lists" browser (set far below)
local RenderEnchants        -- fwd decl: re-paints the "Best Enchants" panel (set far below)
local RenderGear            -- fwd decl: re-paints the "My Gear" panel (set far below)
local RenderSR              -- fwd decl: re-paints the "Reserve Planner" panel (set far below)

local function PhaseLabel(p)
	return (D.phaseLabels and D.phaseLabels[p]) or ("Phase " .. tostring(p))
end

local function DiffLabel(d)
	if d == 5 then return "M+10" end   -- Mythic+ tier = M+10 gear (the only keystone breakpoint bisbeard itemizes)
	return (D.diffLabels and D.diffLabels[d]) or ("Tier " .. tostring(d))
end

-- true when an item is filtered out: PvP/Bloodforged (unless included) or
-- profession-crafted (when the user is hiding crafted). info[2]=version,
-- info[6]=category (>0 = PvP/Bloodforged).
-- Source filter: bisbeard's raw sourceCategory (items[id][8]) grouped into the
-- friendly buckets shown in the Sources panel. Unmapped categories (e.g.
-- "enchants") are never source-filtered.
local SOURCE_BUCKETS = {   -- display order in the Sources panel
	{ "raid", "Raid" },
	{ "dungeon", "Dungeon" },
	{ "worldforged", "Worldforged" },
	{ "bloodforged", "Bloodforged" },
	{ "worldboss", "World Boss" },
	{ "pvp", "PvP" },
	{ "reputation", "Reputation" },
	{ "quest", "Quest" },
	{ "crafted", "Crafted" },
	{ "vendor", "Vendor" },
	{ "events", "Events" },
}
SOURCE_BUCKETS.cat = {
	raid = "raid", dungeon = "dungeon", worldforged = "worldforged",
	bloodforged = "bloodforged", worldboss = "worldboss", worldboe = "worldboss",
	pvp = "pvp", reputation = "reputation", quests = "quest",
	crafting = "crafted", affixed = "crafted", vendor = "vendor", events = "events",
	-- "enchants" intentionally unmapped: never hidden by the Sources filter
}
local function IsExcludedItem(itemId)
	local info = itemId and D.items[itemId]
	if not info then
		return false
	end
	if db.sources then
		local bucket = info[8] and SOURCE_BUCKETS.cat[info[8]]
		if bucket and db.sources[bucket] == false then
			return true
		end
	end
	return false
end

-- Custom weights: per-stat overrides on top of bisbeard's baseline for a spec.
local function CustomTable(key)
	return db.customWeights and key and db.customWeights[key] or nil
end

local function IsSpecCustom()
	local c = CustomTable(specKey)
	return c ~= nil and next(c) ~= nil
end

-- bisbeard base weights merged with the user's per-stat overrides
local function ComputeEffectiveWeights()
	local base = specKey and D.weights[specKey]
	if not base then
		return nil
	end
	local custom = CustomTable(specKey)
	if not custom or not next(custom) then
		return base
	end
	local eff = {}
	for k, v in pairs(base) do
		eff[k] = v
	end
	for k, v in pairs(custom) do
		eff[k] = v
	end
	return eff
end

-- Re-score a baked pool item from its stored raw stats (info[7]) using the
-- given weights. Mirrors the generator's score_item so custom rankings match.
local function CustomScore(itemId, slot, w)
	local info = D.items[itemId]
	local st = info and info[7]
	if not st then
		return 0
	end
	local score = 0
	for code, val in pairs(st) do
		if code == "dps" then
			if slot == "Ranged" then
				score = score + val * (w.rangedDps or 0)
			elseif MELEE_SLOT[slot] then
				score = score + val * (w.weaponDps or 0)
			end
		else
			local key = STAT_CODE_TO_KEY[code]
			local wt = key and w[key]
			if wt then
				score = score + val * wt
			end
		end
	end
	return score
end

-- Merge every (phase <= db.phase, tier <= raid/M+ cap for its source) cell per slot, drop
-- excluded items, sort by score and assign ranks. The top of each merged slot
-- list is the exact cumulative BiS for the current caps (see generator note).
local CanUseByType   -- forward decl (defined with the proficiency helpers below)
local function BuildRankIndex()
	wipe(rankIndex)
	wipe(activeSlotRanks)
	specWeights = ComputeEffectiveWeights()
	local cells = specKey and D.cells[specKey]
	if not cells or not specWeights then
		return
	end
	local isCustom = IsSpecCustom()
	local bySlot = {}
	-- per-item difficulty cap, split by content: raid gear obeys db.raidDiff, dungeon/M+
	-- gear obeys db.mplusDiff, everything else is governed only by the Sources filter.
	local function diffOK(info)
		local src = info and info[8]
		local tier = (info and info[5]) or 1
		if src == "raid" then return tier <= db.raidDiff end
		if src == "dungeon" then return tier <= db.mplusDiff end
		return true
	end
	if isCustom and D.slotPool then
		-- CUSTOM weights: rank the WIDE pool of every item your class can use,
		-- scored by your weights - so an edit actually surfaces new gear, not just
		-- re-orders bisbeard's curated picks. (Filtered by phase/tier/sources/prof.)
		for slot, ids in pairs(D.slotPool) do
			local acc = {}
			for i = 1, #ids do
				local id = ids[i]
				local info = D.items[id]
				if info and (info[4] or 1) <= db.phase and diffOK(info)
					and not IsExcludedItem(id) and CanUseByType(info[9], slot) then
					acc[#acc + 1] = { id, CustomScore(id, slot, specWeights) }
				end
			end
			bySlot[slot] = acc
		end
	else
		-- DEFAULT weights: bisbeard's curated per-cell BiS (fast + exact).
		for phase = 1, db.phase do
			local pcells = cells[phase]
			if pcells then
				for tier = 1, (D.maxDiff or 5) do
					local tcells = pcells[tier]
					if tcells then
						for slot, list in pairs(tcells) do
							local acc = bySlot[slot]
							if not acc then
								acc = {}
								bySlot[slot] = acc
							end
							for i = 1, #list do
								local id = list[i][1]
								if not IsExcludedItem(id) and diffOK(D.items[id]) then
									acc[#acc + 1] = { id, list[i][2] }
								end
							end
						end
					end
				end
			end
		end
	end
	-- fold in curated supplement items bisbeard doesn't index, scored for this spec
	if #extrasList > 0 then
		local class = strmatch(specKey, "^(.-)|")
		for _, ex in ipairs(extrasList) do
			if not ex.class or (class and strlower(ex.class) == strlower(class)) then
				if not IsExcludedItem(ex.id) then
					local acc = bySlot[ex.slot]
					if not acc then acc = {}; bySlot[ex.slot] = acc end
					acc[#acc + 1] = { ex.id, CustomScore(ex.id, ex.slot, specWeights) }
				end
			end
		end
	end
	for slot, acc in pairs(bySlot) do
		table.sort(acc, function(a, b) return a[2] > b[2] end)
		for i = 1, math.min(MERGE_DEPTH, #acc) do
			local id = acc[i][1]
			if not rankIndex[id] or rankIndex[id].rank > i then
				rankIndex[id] = { slot = slot, rank = i, score = acc[i][2] }
			end
		end
		-- full sorted list (not just top-MERGE_DEPTH): the browser de-dups the
		-- same base item's difficulty/version variants, so it needs the depth.
		activeSlotRanks[slot] = acc
	end
	if RenderBrowse then RenderBrowse() end      -- keep the BiS Lists browser in sync
	if RenderEnchants then RenderEnchants() end  -- and the Best Enchants panel
	if RenderGear then RenderGear() end          -- and the My Gear panel
	if RenderSR then RenderSR() end              -- and the Reserve Planner
	if BisBuddyLO and BisBuddyLO.Render then BisBuddyLO.Render() end   -- and the Loadout screen
end

-- forgiving spec-name lookup: matches the bisbeard spec name, the full
-- "Class|Spec", the spec alone, or "Class Spec" - all case-insensitively.
local normSpecLookup
local function MatchSpecName(s)
	if type(s) ~= "string" then
		return nil
	end
	if not normSpecLookup then
		normSpecLookup = {}
		local function put(str, key)
			if type(str) == "string" then normSpecLookup[strlower(strtrim(str))] = key end
		end
		for name, key in pairs(D.specAlias or {}) do put(name, key) end
		for key in pairs(D.weights or {}) do
			put(key, key)
			local cl, sp = strmatch(key, "^(.-)|(.+)$")
			if sp then
				put(sp, key)
				put(cl .. " " .. sp, key)
				put(cl .. sp, key)
			end
		end
	end
	local n = strlower(strtrim(s))
	return n ~= "" and normSpecLookup[n] or nil
end

-- Resolve the active spec via Ascension's SpecializationUtil. Robust to the
-- unknown return signature of GetSpecializationInfo: it scans every returned
-- value and takes the first that matches a known spec name.
-- Call fn(...) and scan every return value (robust to embedded nils, which
-- GetSpecializationInfo returns) for the first that matches a known spec name.
local function ScanPcall(fn, ...)
	local function scan(ok, ...)
		if not ok then return nil end
		for i = 1, select("#", ...) do
			local m = MatchSpecName((select(i, ...)))
			if m then return m end
		end
		return nil
	end
	return scan(pcall(fn, ...))
end

local function ResolveActiveSpecKey()
	if type(SpecializationUtil) ~= "table" then
		return nil
	end
	local SU = SpecializationUtil
	-- On Ascension, GetActiveSpecialization returns a saved-loadout SLOT number
	-- and GetSpecializationInfo(slot) returns the (renameable) slot name, not the
	-- CoA archetype. Try the archetype-oriented call first, then fall through.
	if type(SU.GetCurrentSpecializationInfo) == "function" then
		local m = ScanPcall(SU.GetCurrentSpecializationInfo)
		if m then return m end
	end
	local id
	if type(SU.GetActiveSpecialization) == "function" then
		local ok, v = pcall(SU.GetActiveSpecialization)
		if ok then id = v end
	end
	if id ~= nil and type(SU.GetSpecializationInfo) == "function" then
		local m = ScanPcall(SU.GetSpecializationInfo, id)
		if m then return m end
	end
	return MatchSpecName(id) -- in case GetActiveSpecialization returned a name
end

-- per-character key so a manual /bb spec sticks to this character, not the account
local function CharKey()
	local n = UnitName and UnitName("player") or nil
	if not n then return nil end
	return n .. "@" .. ((GetRealmName and GetRealmName()) or "")
end

local function DetectSpecKey()
	local ck = CharKey()
	if ck and db.charSpec and db.charSpec[ck] then
		return db.charSpec[ck]
	end
	if db.specOverride then          -- legacy account-wide override (still honored)
		return db.specOverride
	end
	return ResolveActiveSpecKey()
end

local function RefreshSpec(force)
	local now = GetTime()
	if not force and (now - specCheckedAt) < 3 then
		return
	end
	specCheckedAt = now
	local key = DetectSpecKey()
	if key ~= specKey then
		specKey = key
		BuildRankIndex()
		wipe(equippedScoreCache)
		if specKey then
			Print(format("spec: |cffffd100%s|r - phase |cffffd100%d %s|r (%s)",
				specKey, db.phase, PhaseLabel(db.phase),
				(D.cells[specKey] and "ranks loaded" or "no rank data")))
			warnedNoSpec = false
		end
	end
	if not specKey and not warnedNoSpec then
		warnedNoSpec = true
		Print("couldn't auto-detect your spec on this client. Set it once with |cffffd100/bb spec <yourspec>|r (e.g. /bb spec Heretic) - it saves per character.")
	end
end

-- Diagnostic dump for troubleshooting spec/gear detection on the live client.
local function DebugSpec()
	local nspecs = 0
	for _ in pairs(D.specAlias or {}) do nspecs = nspecs + 1 end
	Print("|cff69ccf0=== BisBuddy debug (copy these lines) ===|r")
	Print(format("data %s, %d items, %d specs; override=%s; active=%s",
		tostring(D.dataVersion), D.totalItems or 0, nspecs, tostring(db.specOverride), tostring(specKey)))

	if type(SpecializationUtil) ~= "table" then
		Print("SpecializationUtil: |cffff2020MISSING|r (type " .. type(SpecializationUtil) .. ") - client exposes specs differently; tell Claude.")
	else
		local fns = {}
		for k, v in pairs(SpecializationUtil) do fns[#fns + 1] = k .. "(" .. type(v) .. ")" end
		table.sort(fns)
		Print("SpecializationUtil: " .. table.concat(fns, ", "))
		-- dump a call's return values with types (robust to embedded nils)
		local function dumpCall(label, fn, ...)
			local function fmt(ok, ...)
				if not ok then return "ERROR " .. tostring((...)) end
				local n = select("#", ...)
				if n == 0 then return "(no returns)" end
				local parts = {}
				for i = 1, n do
					local v = select(i, ...)
					parts[i] = (type(v) == "string" and ('"' .. v .. '"') or tostring(v)) .. "[" .. type(v) .. "]"
				end
				return table.concat(parts, ", ")
			end
			Print(label .. " -> " .. fmt(pcall(fn, ...)))
		end

		local id
		if type(SpecializationUtil.GetActiveSpecialization) == "function" then
			local ok, v = pcall(SpecializationUtil.GetActiveSpecialization)
			if ok then id = v end
			dumpCall("GetActiveSpecialization()", SpecializationUtil.GetActiveSpecialization)
		end
		if type(SpecializationUtil.GetCurrentSpecializationInfo) == "function" then
			dumpCall("GetCurrentSpecializationInfo()", SpecializationUtil.GetCurrentSpecializationInfo)
		end
		if id ~= nil and type(SpecializationUtil.GetSpecializationInfo) == "function" then
			dumpCall("GetSpecializationInfo(" .. tostring(id) .. ")", SpecializationUtil.GetSpecializationInfo, id)
		end
		-- all saved spec slots (in case one is named after the archetype)
		if type(SpecializationUtil.GetNumSpecializations) == "function" and type(SpecializationUtil.GetSpecializationInfo) == "function" then
			local okn, num = pcall(SpecializationUtil.GetNumSpecializations)
			if okn and type(num) == "number" then
				for slot = 1, math.min(num, 4) do
					dumpCall("  slot " .. slot, SpecializationUtil.GetSpecializationInfo, slot)
				end
			end
		end
	end
	-- CoA class/spec may live on the unit itself
	if UnitClass then
		local cn, ct = UnitClass("player")
		Print("UnitClass(player) -> " .. tostring(cn) .. " / token " .. tostring(ct))
	end

	local resolved = ResolveActiveSpecKey()
	Print("resolved: " .. (resolved and ("|cff00ff00" .. resolved .. "|r  cells=" .. (D.cells[resolved] and "yes" or "NO") .. " weights=" .. (D.weights[resolved] and "yes" or "NO")) or "|cffff2020nil (no match)|r"))
	local sample, n = {}, 0
	for name in pairs(D.specAlias or {}) do
		n = n + 1
		if n <= 8 then sample[#sample + 1] = name end
	end
	Print("known spec names e.g.: " .. table.concat(sample, ", "))

	Print("--- equipped gear (GetItemStats) ---")
	local shown = 0
	for slot = 1, 18 do
		local link = GetInventoryItemLink("player", slot)
		if link and shown < 4 then
			shown = shown + 1
			local st = {}
			local ok = pcall(GetItemStats, link, st)
			local parts = {}
			if ok then for k, v in pairs(st) do parts[#parts + 1] = k .. "=" .. tostring(v) end end
			local nm = strmatch(link, "%[(.-)%]") or link
			Print(format("  slot %d %s: %s", slot, nm, ok and (#parts > 0 and table.concat(parts, ", ") or "|cffff2020no stats returned|r") or "|cffff2020GetItemStats ERROR|r"))
		end
	end
	if shown == 0 then Print("  (no equipped items found)") end
	Print("|cff69ccf0=== end debug ===|r")
end

--------------------------------------------------------------------------------
-- Scoring
--------------------------------------------------------------------------------

local scanTip = CreateFrame("GameTooltip", "BisBuddyScanTooltip", nil, "GameTooltipTemplate")

local function ItemIdFromLink(link)
	if type(link) ~= "string" then
		return nil
	end
	local id = strmatch(link, "item:(%d+)")
	return id and tonumber(id)
end

local function WeaponDps(link, itemId)
	if itemId and dpsCache[itemId] ~= nil then
		local c = dpsCache[itemId]
		return c ~= false and c or nil
	end
	scanTip:SetOwner(UIParent, "ANCHOR_NONE")
	scanTip:ClearLines()
	scanTip:SetHyperlink(link)
	local dps
	for i = 2, scanTip:NumLines() do
		local fs = _G["BisBuddyScanTooltipTextLeft" .. i]
		local text = fs and fs:GetText()
		if text then
			local m = strmatch(text, "%(([%d%.]+) damage per second%)")
			if m then
				dps = tonumber(m)
				break
			end
		end
	end
	scanTip:Hide()
	if itemId then
		dpsCache[itemId] = dps or false
	end
	return dps
end

local statScratch = {}

--------------------------------------------------------------------------------
-- Hit / expertise caps (Approach A: set-relative, personalized). Reverse-
-- engineered from bisbeard's planner (App bundle, CoA level 60, 2026-08-05): an
-- item's hit/expertise is worth its weight only up to the gap between the spec's
-- cap and what your equipped gear already provides (remaining = max(0, cap -
-- current)); overflow is ~worthless. Affects LIVE upgrade evaluation (tooltips /
-- equipped compares), not the static aspirational BiS lists. Specs with no cap
-- (healers etc.) are unaffected.
-- CoA level-60 cap targets (rating): physical/ranged hit 8% * 10 = 80; spell hit
-- 17% * 8 = 136; expertise 26 skill * 2.5 = 65; spell penetration 60 (from bisbeard's
-- planner; spell-pen cap wired up 2026-08-07 for the spen-flagged specs).
local CAP = { melee = 80, ranged = 80, spell = 136, exp = 65, spen = 60 }

-- Per-spec hit/expertise cap profiles, reverse-engineered from bisbeard's planner
-- (App bundle, CoA level 60) 2026-08-05. hit = which hit cap applies
-- (melee/ranged/spell) or nil (no cap, e.g. healers); exp = expertise cap applies.
CAP.spec = {
	["Barbarian|Headhunting"] = { hit="ranged" },
	["Barbarian|Brutality"] = { hit="melee", exp=true },
	["Barbarian|Ancestry"] = { hit="melee", exp=true },
	["Witch Doctor|Shadowhunting"] = { hit="ranged", spen=true },
	["Witch Doctor|Voodoo"] = { hit="spell", spen=true },
	["Felsworn|Infernal"] = { hit="spell" },
	["Felsworn|Slayer"] = { hit="melee", exp=true, spen=true },
	["Felsworn|Tyrant"] = { hit="melee", exp=true },
	["Witch Hunter|Boltslinger"] = { hit="ranged" },
	["Witch Hunter|Houndmaster"] = { hit="ranged" },
	["Witch Hunter|Inquisition"] = { hit="melee", exp=true, spen=true },
	["Witch Hunter|Black Knight"] = { hit="melee", exp=true },
	["Stormbringer|Wind"] = { hit="spell", spen=true },
	["Stormbringer|Maelstrom"] = { hit="spell", spen=true },
	["Stormbringer|Lightning"] = { hit="spell", spen=true },
	["Knight of Xoroth|Hellfire"] = { hit="melee", exp=true, spen=true },
	["Knight of Xoroth|Defiance"] = { hit="melee", exp=true, spen=true },
	["Knight of Xoroth|War"] = { hit="melee", exp=true },
	["Guardian|Gladiator"] = { hit="melee", exp=true },
	["Guardian|Inspiration"] = { hit="melee", exp=true },
	["Guardian|Vanguard"] = { hit="melee", exp=true },
	["Templar|Oathkeeper"] = { hit="melee", exp=true, spen=true },
	["Templar|Zealot"] = { hit="melee", exp=true, spen=true },
	["Templar|Crusader"] = { hit="melee", exp=true, spen=true },
	["Bloodmage|Sanguine"] = { hit="spell", spen=true },
	["Bloodmage|Accursed"] = { hit="melee", exp=true, spen=true },
	["Bloodmage|Eternal"] = { hit="melee", exp=true, spen=true },
	["Ranger|Archery"] = { hit="ranged" },
	["Ranger|Farstrider"] = { hit="ranged", spen=true },
	["Ranger|Brigand"] = { hit="melee", exp=true },
	["Chronomancer|Infinite"] = { hit="spell", spen=true },
	["Chronomancer|Artificer"] = { hit="spell", spen=true },
	["Necromancer|Death"] = { hit="spell", spen=true },
	["Necromancer|Animation"] = { hit="spell", spen=true },
	["Necromancer|Rime"] = { hit="spell", spen=true },
	["Pyromancer|Incineration"] = { hit="spell", spen=true },
	["Pyromancer|Draconic"] = { hit="spell", spen=true },
	["Cultist|Heretic"] = { spen=true },
	["Cultist|Corruption"] = { hit="spell", spen=true },
	["Cultist|Godblade"] = { hit="melee", exp=true, spen=true },
	["Cultist|Dreadnought"] = { hit="melee", exp=true, spen=true },
	["Starcaller|Sentinel"] = { hit="ranged", spen=true },
	["Starcaller|Warden"] = { hit="melee", exp=true, spen=true },
	["Starcaller|Moon Guard"] = { spen=true },
	["Sun Cleric|Piety"] = { hit="spell", spen=true },
	["Sun Cleric|Valkyrie"] = { hit="melee", exp=true, spen=true },
	["Sun Cleric|Seraphim"] = { hit="melee", exp=true, spen=true },
	["Tinker|Demolition"] = { hit="ranged", spen=true },
	["Tinker|Mechanics"] = { hit="melee", exp=true },
	["Venomancer|Fortitude"] = { hit="melee", exp=true, spen=true },
	["Venomancer|Stalking"] = { hit="melee", exp=true, spen=true },
	["Venomancer|Rotweaver"] = { hit="spell", spen=true },
	["Reaper|Soul"] = { hit="melee", exp=true },
	["Reaper|Harvest"] = { hit="melee", exp=true },
	["Reaper|Domination"] = { hit="melee", exp=true },
	["Primalist|Grovekeeper"] = { hit="melee", exp=true },
	["Primalist|Wildwalker"] = { hit="melee", exp=true },
	["Primalist|Mountain King"] = { hit="melee", exp=true },
	["Primalist|Geomancy"] = { hit="spell" },
	["Runemaster|Engravement"] = { hit="melee", exp=true, spen=true },
	["Runemaster|Glyphic"] = { hit="spell", spen=true },
	["Runemaster|Riftblade"] = { hit="melee", exp=true, spen=true },
}

-- CAP.ctx = the active Evaluate pass's cap context (set in Evaluate, read in ScoreLink); nil = no capping

-- Cap context for the active spec: current equipped hit/expertise + how much more
-- you want before the surplus becomes worthless. nil when the spec has no cap.
local function CapContext()
	local caps = specKey and CAP.spec[specKey]
	if not caps or (not caps.hit and not caps.exp and not caps.spen) then
		return nil
	end
	local curHit, curExp, curSpen = 0, 0, 0
	for inv = 1, 18 do
		local link = GetInventoryItemLink("player", inv)
		if link then
			wipe(statScratch)
			if pcall(GetItemStats, link, statScratch) then
				curHit = curHit + (statScratch.ITEM_MOD_HIT_RATING_SHORT or 0)
				curExp = curExp + (statScratch.ITEM_MOD_EXPERTISE_RATING_SHORT or 0)
				curSpen = curSpen + (statScratch.ITEM_MOD_SPELL_PENETRATION_SHORT or 0)
			end
		end
	end
	local ctx = { curHit = curHit, curExp = curExp, curSpen = curSpen }
	if caps.hit then
		ctx.hitCap = CAP[caps.hit]
		ctx.hitRemaining = math.max(0, (ctx.hitCap or 0) - curHit)
	end
	if caps.exp then
		ctx.expCap = CAP.exp
		ctx.expRemaining = math.max(0, CAP.exp - curExp)
	end
	if caps.spen then
		ctx.spenCap = CAP.spen
		ctx.spenRemaining = math.max(0, CAP.spen - curSpen)
	end
	return ctx
end

-- Returns score, isExact (exact = straight from the baked bisbeard ranking)
local function ScoreLink(link)
	if not specWeights then
		return nil
	end
	local itemId = ItemIdFromLink(link)
	local ranked = itemId and rankIndex[itemId]
	if ranked then
		return ranked.score, true
	end
	wipe(statScratch)
	local ok = pcall(GetItemStats, link, statScratch)
	if not ok then
		return nil
	end
	local score, any = 0, false
	local cap = CAP.ctx
	for key, value in pairs(statScratch) do
		local bisKey = STAT_KEY_MAP[key]
		if not bisKey then
			local label = _G[key]
			bisKey = type(label) == "string" and LABEL_TO_BIS_KEY[label] or nil
		end
		local w = bisKey and specWeights[bisKey]
		if w and type(value) == "number" then
			if cap then   -- value hit/expertise only up to the remaining gap to cap
				if bisKey == "hitRating" and cap.hitRemaining then
					value = math.min(value, cap.hitRemaining)
				elseif bisKey == "expertise" and cap.expRemaining then
					value = math.min(value, cap.expRemaining)
				elseif bisKey == "spellPenetration" and cap.spenRemaining then
					value = math.min(value, cap.spenRemaining)
				end
			end
			score = score + value * w
			any = true
		end
	end
	local _, _, _, _, _, _, _, _, equipLoc = GetItemInfo(link)
	local slot = equipLoc and EQUIPLOC_TO_SLOT[equipLoc]
	if slot then
		local dpsWeight
		if slot == "Ranged" then
			dpsWeight = specWeights.rangedDps
		elseif MELEE_SLOT[slot] then
			dpsWeight = specWeights.weaponDps
		end
		if dpsWeight then
			local dps = WeaponDps(link, itemId)
			if dps then
				score = score + dps * dpsWeight
				any = true
			end
		end
	end
	if any then
		return score, false
	end
	return nil
end

local function SlotForLink(link, itemId)
	local ranked = itemId and rankIndex[itemId]
	if ranked then
		return ranked.slot
	end
	local _, _, _, _, _, _, _, _, equipLoc = GetItemInfo(link)
	return equipLoc and EQUIPLOC_TO_SLOT[equipLoc] or nil
end

-- item subType (GetItemInfo #7) -> bisbeard proficiency type
local WEAPON_TYPE_MAP = {
	Swords = "Sword", ["One-Handed Swords"] = "Sword", ["Two-Handed Swords"] = "Sword",
	Daggers = "Dagger", Axes = "Axe", ["Two-Handed Axes"] = "Axe",
	Maces = "Mace", ["Two-Handed Maces"] = "Mace", ["Fist Weapons"] = "Fist",
	Staves = "Staff", Polearms = "Polearm", Wands = "Wand", Wand = "Wand",
	Bows = "Bow", Guns = "Gun", Crossbows = "Crossbow", Thrown = "Thrown",
}
local ARMOR_SLOT = { Head = true, Shoulders = true, Chest = true, Wrists = true,
	Hands = true, Waist = true, Legs = true, Feet = true }
local WEAPON_SLOT = { ["One-Hand"] = true, ["Two-Hand"] = true, ["Main Hand"] = true,
	["Off Hand"] = true, ["Ranged"] = true }
local RANGED_WT = { Gun = true, Bow = true, Crossbow = true, Wand = true, Thrown = true }
local ARMOR_T = { Cloth = true, Leather = true, Mail = true, Plate = true }

local function listHas(list, v)
	if not list then return false end
	for i = 1, #list do
		if list[i] == v then return true end
	end
	return false
end

-- Can the active spec actually equip this item? (weapon type / armor type /
-- shield). Mirrors the generator so hovered/dropped gear the spec can't use
-- isn't scored. Defaults to allow when data or item info is unavailable.
-- Proficiency from a baked item type + known slot (no GetItemInfo needed) - used
-- to filter the wide slotPool for custom-weight re-ranking. CanUseItem wraps it.
CanUseByType = function(subType, slot)
	if not specKey or not D.prof or not D.prof.classes then
		return true
	end
	local class = strmatch(specKey, "^(.-)|")
	local cp = class and D.prof.classes[class]
	if not cp then
		return true
	end
	if not slot then
		return true
	end
	if slot == "Shield" then
		return cp.shield and true or false
	end
	if ARMOR_SLOT[slot] and ARMOR_T[subType] then
		return listHas(cp.armor, subType)
	end
	if WEAPON_SLOT[slot] then
		local wt = WEAPON_TYPE_MAP[subType]
		if not wt then
			return false
		end
		if slot == "Ranged" then
			local specName = strmatch(specKey, "|(.+)$")
			local ov = specName and D.prof.rangedOverride and D.prof.rangedOverride[specName]
			if ov then
				return listHas(ov, wt)
			end
			return RANGED_WT[wt] and listHas(cp.weap, wt) or false
		end
		if not listHas(cp.weap, wt) then
			return false
		end
		if slot == "Off Hand" and cp.dw == false then
			return false  -- off-hand WEAPON needs dual-wield; Shield/Held In Off-hand are separate slots
		end
		if (slot == "One-Hand" or slot == "Main Hand" or slot == "Off Hand") and listHas(cp.no1, wt) then
			return false
		end
		if slot == "Two-Hand" and listHas(cp.no2, wt) then
			return false
		end
		return true
	end
	return true
end

local function CanUseItem(link)
	local _, _, _, _, _, _, subType, _, equipLoc = GetItemInfo(link)
	if not equipLoc then
		return true -- item not in the client cache yet; don't over-filter
	end
	return CanUseByType(subType, EQUIPLOC_TO_SLOT[equipLoc])
end

local function EquippedScore(invSlot)
	local cached = equippedScoreCache[invSlot]
	if cached ~= nil then
		return cached ~= false and cached or nil
	end
	local link = GetInventoryItemLink("player", invSlot)
	local score = link and ScoreLink(link) or nil
	equippedScoreCache[invSlot] = score or false
	return score
end

-- score of a two-hander currently equipped in the main-hand slot, else nil
local function EquippedTwoHandScore()
	local link = GetInventoryItemLink("player", 16)
	if not link then
		return nil
	end
	local _, _, _, _, _, _, _, _, equipLoc = GetItemInfo(link)
	if equipLoc == "INVTYPE_2HWEAPON" then
		return EquippedScore(16)
	end
	return nil
end

-- Baseline the item would have to beat: weaker of paired slots (rings,
-- trinkets, 1H weapons); both hands combined for a Two-Hand; the equipped
-- two-hander for any single-hand/off-hand item (you'd give the 2H up).
local function BaselineForSlot(slot)
	local invSlots = SLOT_INV[slot]
	if not invSlots then
		return nil
	end
	if slot == "Two-Hand" then
		-- replaces both hands: current 2H, or current main-hand + off-hand summed
		local total
		for _, inv in ipairs(invSlots) do
			local s = EquippedScore(inv)
			if s then
				total = (total or 0) + s
			end
		end
		return total
	end
	-- a 1H/off-hand/shield swaps out an equipped 2H (both its hands), so compare
	-- against that 2H rather than treating the empty off-hand as a free upgrade
	if HANDS_SLOT[slot] then
		local twoH = EquippedTwoHandScore()
		if twoH then
			return twoH
		end
	end
	local best -- "best" here = weakest currently-equipped candidate to replace
	local anyEmpty = false
	for _, inv in ipairs(invSlots) do
		local link = GetInventoryItemLink("player", inv)
		if not link then
			anyEmpty = true
		else
			local s = EquippedScore(inv)
			if s and (not best or s < best) then
				best = s
			end
		end
	end
	if anyEmpty then
		return 0 -- an empty slot means anything is an upgrade
	end
	return best
end

--------------------------------------------------------------------------------
-- 1H vs 2H fairness: a lone 1H always loses to a 2H on raw weight because the 2H
-- carries ~2x the stat budget. When a 2H is equipped, equipping a 1H frees the
-- off-hand, so we pair the hovered 1H with the best off-hand you own (or a locked
-- one) and compare (1H + off-hand) against the 2H. Symmetric for a hovered
-- off-hand (paired with your best main-hand 1H).
--------------------------------------------------------------------------------
local BANK_BAGS = { -1, 5, 6, 7, 8, 9, 10, 11 }  -- main bank + bank bag slots (nil when closed)
local OFFHAND_EQUIPLOC = { INVTYPE_WEAPONOFFHAND = true, INVTYPE_SHIELD = true, INVTYPE_HOLDABLE = true }
local MAINHAND1H_EQUIPLOC = { INVTYPE_WEAPON = true, INVTYPE_WEAPONMAINHAND = true }

-- Best owned item (equipped + bags + bank) whose equipLoc is in `set` and that
-- the active spec can use, scored by ScoreLink. `excludeId` skips the item being
-- evaluated so it can't pair with itself. Returns {score,id,link} or nil.
local function BestOwnedByLoc(set, excludeId)
	local best
	local function consider(link)
		if not link then return end
		local id = ItemIdFromLink(link)
		if excludeId and id == excludeId then return end
		local _, _, _, _, _, _, _, _, equipLoc = GetItemInfo(link)
		if not equipLoc or not set[equipLoc] then return end
		if not CanUseItem(link) then return end
		local sc = ScoreLink(link)
		if sc and (not best or sc > best.score) then
			best = { score = sc, id = id, link = link }
		end
	end
	consider(GetInventoryItemLink("player", 16))
	consider(GetInventoryItemLink("player", 17))
	for bag = 0, 4 do
		for s = 1, (GetContainerNumSlots(bag) or 0) do consider(GetContainerItemLink(bag, s)) end
	end
	for _, bag in ipairs(BANK_BAGS) do
		for s = 1, (GetContainerNumSlots(bag) or 0) do consider(GetContainerItemLink(bag, s)) end
	end
	return best
end

local function ExtraName(id, link)
	return (D.items[id] and D.items[id][1]) or (link and (GetItemInfo(link))) or ("item " .. tostring(id))
end

-- The off-hand to pair with a 1H: a locked off-hand if set, else the best owned.
local function PairedOffHand(excludeId)
	local lock = db and db.lockOffHand
	if lock and lock.id then
		local link = "item:" .. lock.id                 -- works for both cached items and the test stub
		local sc = ScoreLink(link)
		if not sc then
			local rk = rankIndex[lock.id]
			sc = rk and rk.score or nil
		end
		return { score = sc or 0, id = lock.id, name = lock.name or ExtraName(lock.id, link), locked = true }
	end
	local b = BestOwnedByLoc(OFFHAND_EQUIPLOC, excludeId)
	if b then return { score = b.score, id = b.id, name = ExtraName(b.id, b.link) } end
	return nil
end

-- The main-hand 1H to pair with a hovered off-hand (best owned; lock is off-hand only).
local function PairedMainHand(excludeId)
	local b = BestOwnedByLoc(MAINHAND1H_EQUIPLOC, excludeId)
	if b then return { score = b.score, id = b.id, name = ExtraName(b.id, b.link) } end
	return nil
end

-- Full evaluation used by tooltips, alerts and /bb
local function Evaluate(link)
	RefreshSpec(false)
	if not specKey or not specWeights then
		return nil
	end
	CAP.ctx = CapContext()   -- personalized cap-aware scoring for this pass
	local itemId = ItemIdFromLink(link)
	if not itemId then
		return nil
	end
	local ranked = rankIndex[itemId]
	-- ranked items are already proficiency-filtered in the data; for anything
	-- else, skip gear this spec can't equip (e.g. a wand for a gun-only Tinker)
	if not ranked and not CanUseItem(link) then
		return nil
	end
	local score, exact = ScoreLink(link)
	if not score then
		return nil
	end
	local slot = SlotForLink(link, itemId)
	-- 1H/2H fairness: only when a two-hander is equipped (so the other hand is
	-- free). Pair the hovered single-hand item with the best complement you own,
	-- then compare the pair against the 2H (BaselineForSlot already returns it).
	local paired
	if slot and EquippedTwoHandScore() then
		if slot == "One-Hand" or slot == "Main Hand" then
			paired = PairedOffHand(itemId)
		elseif slot == "Off Hand" or slot == "Held In Off-hand" or slot == "Shield" then
			paired = PairedMainHand(itemId)
		end
		if paired and paired.score and paired.score > 0 then
			score = score + paired.score
		else
			paired = nil
		end
	end
	local base = slot and BaselineForSlot(slot)
	local pct
	if base and base > 0 then
		pct = (score - base) / base * 100
	elseif base == 0 then
		pct = 100
	end
	return {
		itemId = itemId,
		slot = slot,
		rank = ranked and ranked.rank or nil,
		score = score,
		exact = exact,
		base = base,
		pct = pct,
		paired = paired,
	}
end

--------------------------------------------------------------------------------
-- Tooltip integration
--------------------------------------------------------------------------------

local function AddTooltipLines(tt)
	if not db.tooltip then
		return
	end
	local _, link = tt:GetItem()
	if not link or tt.BisBuddyLastLink == link then
		return
	end
	tt.BisBuddyLastLink = link
	if IsExcludedItem(ItemIdFromLink(link)) then
		tt:AddLine("BisBuddy: |cff999999hidden by Sources filter (/bb sources)|r", 0.41, 0.8, 0.94)
		tt:Show()
		return
	end
	local e = Evaluate(link)
	if not e then
		return
	end
	local shortSpec = strmatch(specKey, "|(.+)$") or specKey
	if e.rank then
		local srcTag = extraIds[e.itemId] and "|cff40ff40Extra|r"
			or (IsSpecCustom() and "|cffcc66ffCustom|r" or "BisBeard")
		tt:AddLine(format("%s: |cffffd100#%d BiS %s|r - %s", srcTag, e.rank, e.slot or "?", shortSpec), 1, 0.55, 0.1)
	end
	if e.pct then
		local line
		if e.pct >= 0.05 then
			line = format("|cff20ff20+%.1f%% vs equipped|r  (%.0f vs %.0f)", e.pct, e.score, e.base or 0)
		elseif e.pct <= -0.05 then
			line = format("|cff999999%.1f%% vs equipped|r  (%.0f vs %.0f)", e.pct, e.score, e.base or 0)
		else
			line = format("|cff999999~equal to equipped|r  (%.0f)", e.score)
		end
		if e.paired and e.paired.name then
			line = line .. format("  |cff8888ff(as 1H + %s%s)|r", strsub(e.paired.name, 1, 16),
				e.paired.locked and ", locked" or "")
		end
		tt:AddLine("BisBuddy: " .. line, 0.41, 0.8, 0.94)
	elseif not e.rank then
		return
	end
	tt:Show() -- resize for added lines
end

local function HookTooltip(tt)
	if not tt then
		return
	end
	tt:HookScript("OnTooltipSetItem", AddTooltipLines)
	tt:HookScript("OnHide", function(self)
		self.BisBuddyLastLink = nil
	end)
end

--------------------------------------------------------------------------------
-- Loot alerts
--------------------------------------------------------------------------------

local function ShouldAlert(e)
	if e.rank and e.rank <= db.threshold then
		return true
	end
	if e.pct and e.pct >= db.minUpgradePct then
		return true
	end
	return false
end

local function AnnounceDrop(link, e, context)
	local itemId = e.itemId
	local now = GetTime()
	if alertRecent[itemId] and (now - alertRecent[itemId]) < 120 then
		return
	end
	alertRecent[itemId] = now
	local shortSpec = strmatch(specKey, "|(.+)$") or specKey
	local bits = {}
	if e.rank then
		bits[#bits + 1] = format("|cffffd100#%d BiS %s|r for %s", e.rank, e.slot or "?", shortSpec)
	end
	if e.pct and e.pct >= db.minUpgradePct then
		bits[#bits + 1] = format("|cff20ff20+%.1f%% upgrade|r", e.pct)
	end
	local msg = format("%s %s - %s", context, link, table.concat(bits, ", "))
	Print(msg)
	if e.rank and e.rank <= 3 and RaidNotice_AddMessage and RaidWarningFrame then
		RaidNotice_AddMessage(RaidWarningFrame, format("BisBuddy: %s is #%d BiS!", link, e.rank), ChatTypeInfo["RAID_WARNING"])
	end
	PlaySound("RaidWarning")
end

local function CheckLootRoll(rollID)
	if not db.alerts then
		return
	end
	local link = GetLootRollItemLink(rollID)
	if not link then
		return
	end
	lastRollLink = link -- remember it for "/bb loot"
	if IsExcludedItem(ItemIdFromLink(link)) then
		return
	end
	local e = Evaluate(link)
	if e and ShouldAlert(e) then
		AnnounceDrop(link, e, "roll:")
	end
end

local function CheckLootWindow()
	if not db.alerts then
		return
	end
	for i = 1, GetNumLootItems() do
		if LootSlotIsItem and LootSlotIsItem(i) or not LootSlotIsItem then
			local link = GetLootSlotLink(i)
			if link and not IsExcludedItem(ItemIdFromLink(link)) then
				local e = Evaluate(link)
				if e and ShouldAlert(e) then
					AnnounceDrop(link, e, "loot:")
				end
			end
		end
	end
end

--------------------------------------------------------------------------------
-- Group loot helper (/bb loot): ask your party/raid who an item upgrades. The
-- "should I roll?" solo half is already the loot-roll alert above; this adds the
-- group view. Privacy is the channel: queries go ONLY to PARTY/RAID (so only
-- your group receives them). Opt out of answering with /bb loot off.
--------------------------------------------------------------------------------
local LOOT_PREFIX = "BisBuddyLoot"
local lootQuery                 -- { itemId, name, responses = { [name]={pct,rank,usable} }, shown }
local lootTimer = CreateFrame("Frame", "BisBuddyLootTimer")
lootTimer:Hide()

-- evaluate an item for ME: rounded pct (or nil), BiS rank (or nil), usable(bool)
local function LootEvalSelf(link)
	local e = link and Evaluate(link)
	if e then
		return e.pct and math.floor(e.pct + 0.5) or nil, e.rank, true
	end
	return nil, nil, (link and CanUseItem(link)) and true or false
end

local function LootFinish()
	lootTimer:Hide()
	lootTimer:SetScript("OnUpdate", nil)
	if not lootQuery or lootQuery.shown then
		return
	end
	lootQuery.shown = true
	local list = {}
	for name, r in pairs(lootQuery.responses) do
		list[#list + 1] = { name = name, pct = r.pct, rank = r.rank, usable = r.usable }
	end
	local function rankVal(r) return (not r.usable) and -1000 or (r.pct or -1) end
	table.sort(list, function(a, b) return rankVal(a) > rankVal(b) end)
	local parts = {}
	for _, r in ipairs(list) do
		if not r.usable then
			parts[#parts + 1] = r.name .. ": |cff777777can't use|r"
		elseif not r.pct or r.pct <= 0 then
			parts[#parts + 1] = r.name .. ": |cff777777no|r"
		else
			parts[#parts + 1] = format("|cff20ff20%s +%d%%|r%s", r.name, r.pct, r.rank and (" (#" .. r.rank .. ")") or "")
		end
	end
	Print(format("loot check - |cffffd100%s|r:  %s", lootQuery.name or "item", table.concat(parts, "   \194\183   ")))
end

local function StartLootQuery(link)
	local ch = GroupChannel()
	if not ch then
		Print("loot check only works in a party or raid.")
		return
	end
	local id = link and ItemIdFromLink(link)
	if not id then
		Print("no item - shift-click one into |cffffd100/bb loot|r, or run it while a roll is up.")
		return
	end
	local name = (GetItemInfo(link)) or ("item " .. id)
	lootQuery = { itemId = id, name = name, responses = {}, shown = false }
	local pct, rank, usable = LootEvalSelf(link)
	local me = (UnitName and UnitName("player")) or "you"
	lootQuery.responses[me] = { pct = pct, rank = rank, usable = usable }
	if SendAddonMessage then SendAddonMessage(LOOT_PREFIX, "Q" .. link, ch) end
	local elapsed = 0
	lootTimer:SetScript("OnUpdate", function(self, dt)
		elapsed = elapsed + (dt or 0)
		if elapsed >= 3 then LootFinish() end
	end)
	lootTimer:Show()
	Print("asking your group about |cffffd100" .. name .. "|r ...")
end

local function OnLootMessage(prefix, msg, channel, sender)
	if prefix ~= LOOT_PREFIX or not msg then
		return
	end
	if UnitName and sender == UnitName("player") then
		return -- ignore our own messages
	end
	local q = string.match(msg, "^Q(.+)$")
	if q then
		-- only answer genuine group queries; channel delivery is the privacy fence
		if channel ~= "PARTY" and channel ~= "RAID" then return end
		if db.lootShare == false then return end
		local id = ItemIdFromLink(q)
		if not id then return end
		local pct, rank, usable = LootEvalSelf(q)
		local status = (not usable) and "n" or (pct and tostring(pct) or "x")
		if SendAddonMessage and sender then
			SendAddonMessage(LOOT_PREFIX, "A" .. id .. ";" .. status .. ";" .. (rank or "-"), "WHISPER", sender)
		end
		return
	end
	local id, pctS, rankS = string.match(msg, "^A(%d+);([^;]+);(.+)$")
	if id and lootQuery and not lootQuery.shown and tonumber(id) == lootQuery.itemId then
		lootQuery.responses[sender] = { pct = tonumber(pctS), rank = tonumber(rankS), usable = (pctS ~= "n") }
	end
end


--------------------------------------------------------------------------------
-- Slash commands
--------------------------------------------------------------------------------

local SLOT_TOKENS = {
	head = "Head", neck = "Neck", shoulder = "Shoulders", shoulders = "Shoulders",
	back = "Back", cloak = "Back", chest = "Chest", robe = "Chest",
	wrist = "Wrists", wrists = "Wrists", bracers = "Wrists",
	hands = "Hands", gloves = "Hands", waist = "Waist", belt = "Waist",
	legs = "Legs", feet = "Feet", boots = "Feet",
	finger = "Finger", ring = "Finger", rings = "Finger",
	trinket = "Trinket", trinkets = "Trinket",
	["2h"] = "Two-Hand", twohand = "Two-Hand", staff = "Two-Hand",
	["1h"] = "One-Hand", onehand = "One-Hand",
	mh = "Main Hand", mainhand = "Main Hand",
	oh = "Off Hand", offhand = "Off Hand", shield = "Shield",
	held = "Held In Off-hand", frill = "Held In Off-hand",
	ranged = "Ranged", wand = "Ranged", gun = "Ranged", bow = "Ranged",
}

-- normalized (lowercased, alphanumerics only) phase name -> phase number
local PHASE_ALIASES = {
	preraid = 1, pre = 1, prebis = 1, zg = 1, zulgurub = 1,
	mc = 2, molten = 2, moltencore = 2, ony = 2, onyxia = 2,
	bwl = 3, blackwing = 3, blackwinglair = 3,
	aq = 4, ahnqiraj = 4, temple = 4, taq = 4, ruins = 4, raq = 4,
	naxx = 5, nax = 5, naxxramas = 5,
}

local function ResolvePhase(rest)
	local norm = strlower(rest or ""):gsub("[^a-z0-9]", "")
	if norm == "" then
		return nil
	end
	local n = tonumber(norm)
	if n then
		return n
	end
	return PHASE_ALIASES[norm]
end

local function SetPhase(p, quiet)
	if not D.cells then
		return
	end
	local maxp = D.maxPhase or 5
	p = math.max(1, math.min(maxp, p))
	db.phase = p
	BuildRankIndex()
	wipe(equippedScoreCache)
	if not quiet then
		Print(format("phase -> |cffffd100%d %s|r", p, PhaseLabel(p)))
	end
end

local DIFF_ALIASES = {
	normal = 1, norm = 1, n = 1,
	heroic = 2, hc = 2, h = 2,
	mythic = 3, myth = 3, m = 3, mythic0 = 3, m0 = 3,
	ascended = 4, asc = 4, a = 4,
	["mythic+"] = 5, ["m+"] = 5, mplus = 5, mythicplus = 5, keystone = 5, key = 5,
	m10 = 5, ["m+10"] = 5, mythic10 = 5,
}

local function ResolveDiff(rest)
	local norm = strlower(rest or ""):gsub("[^a-z0-9+]", "")
	if norm == "" then
		return nil
	end
	local n = tonumber(norm)
	if n then
		return n
	end
	return DIFF_ALIASES[norm]
end

-- kind = "raid" (caps raid gear, tiers 1-4) or "mplus" (caps dungeon/M+ gear, 1-5)
local function SetDiff(kind, d, quiet)
	if not D.cells then
		return
	end
	if kind == "mplus" then
		db.mplusDiff = math.max(1, math.min(D.maxDiff or 5, d))
	else
		db.raidDiff = math.max(1, math.min(4, d))
	end
	BuildRankIndex()
	wipe(equippedScoreCache)
	if not quiet then
		Print(format("%s difficulty -> |cffffd100%s|r", kind == "mplus" and "M+/dungeon" or "raid",
			DiffLabel(kind == "mplus" and db.mplusDiff or db.raidDiff)))
	end
end

local function CmdTop(rest)
	RefreshSpec(true)
	if not specKey then
		Print("no spec detected - /bb spec <name>")
		return
	end
	local slot = SLOT_TOKENS[strlower(rest or "")] or rest
	local list = activeSlotRanks[slot]
	if not list then
		Print("unknown slot '" .. tostring(rest) .. "'. Try: head neck shoulders back chest wrists hands waist legs feet ring trinket 2h 1h mh oh shield held ranged")
		return
	end
	Print(format("top %d |cffffd100%s|r for %s - phase |cffffd100%d %s|r, raid |cffffd100%s|r / M+ |cffffd100%s|r:",
		math.min(10, #list), slot, specKey, db.phase, PhaseLabel(db.phase), DiffLabel(db.raidDiff), DiffLabel(db.mplusDiff)))
	local base = BaselineForSlot(slot)
	for i = 1, math.min(10, #list) do
		local id, score = list[i][1], list[i][2]
		local info = D.items[id]
		local name = info and info[1] or ("item " .. id)
		local ver = info and info[2] ~= "" and (" |cff888888[" .. info[2] .. "]|r") or ""
		local src = info and info[3] or "?"
		local marker = (base and score > base) and "|cff20ff20^|r" or " "
		Print(format(" %s#%d %s%s  |cff69ccf0%.0f|r  |cff666666%s|r", marker, i, name, ver, score, src))
	end
	if base then
		Print(format("your current baseline: |cff69ccf0%.0f|r (^ = upgrade)", base))
	end
end

--------------------------------------------------------------------------------
-- Weight-string import/export (GearWeights / bisbeard-compatible:
-- standard Base64 of a flat JSON object { bisbeardKey = number, ... })
--------------------------------------------------------------------------------

local B64_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local b64Lookup, b64Chars = {}, {}
for i = 1, #B64_CHARS do
	local ch = string.sub(B64_CHARS, i, i)
	b64Lookup[ch] = i - 1
	b64Chars[i - 1] = ch
end

local function Base64Encode(data)
	local out, len, i = {}, #data, 1
	while i <= len do
		local b1 = string.byte(data, i)
		local b2 = string.byte(data, i + 1)
		local b3 = string.byte(data, i + 2)
		local n1 = math.floor(b1 / 4)
		local n2 = (b1 % 4) * 16 + (b2 and math.floor(b2 / 16) or 0)
		local n3 = b2 and ((b2 % 16) * 4 + (b3 and math.floor(b3 / 64) or 0)) or nil
		local n4 = b3 and (b3 % 64) or nil
		out[#out + 1] = b64Chars[n1]
		out[#out + 1] = b64Chars[n2]
		out[#out + 1] = n3 and b64Chars[n3] or "="
		out[#out + 1] = n4 and b64Chars[n4] or "="
		i = i + 3
	end
	return table.concat(out)
end

local function Base64Decode(data)
	data = string.gsub(data, "[^A-Za-z0-9%+%/%=]", "")
	local out, i, len = {}, 1, #data
	while i <= len do
		local s1, s2 = string.sub(data, i, i), string.sub(data, i + 1, i + 1)
		local s3, s4 = string.sub(data, i + 2, i + 2), string.sub(data, i + 3, i + 3)
		local c1, c2 = b64Lookup[s1] or 0, b64Lookup[s2] or 0
		local c3, c4 = b64Lookup[s3], b64Lookup[s4]
		out[#out + 1] = string.char(c1 * 4 + math.floor(c2 / 16))
		if s3 ~= "" and s3 ~= "=" then
			out[#out + 1] = string.char((c2 % 16) * 16 + math.floor((c3 or 0) / 4))
		end
		if s4 ~= "" and s4 ~= "=" then
			out[#out + 1] = string.char(((c3 or 0) % 4) * 64 + (c4 or 0))
		end
		i = i + 4
	end
	return table.concat(out)
end

local function FlatJsonEncode(tbl)
	local parts = {}
	for k, v in pairs(tbl) do
		parts[#parts + 1] = format('"%s":%s', k, tostring(v))
	end
	return "{" .. table.concat(parts, ",") .. "}"
end

local function FlatJsonDecode(str)
	local result = {}
	for key, val in string.gmatch(str, '"([%w_]+)"%s*:%s*(%-?[%d%.]+)') do
		result[key] = tonumber(val)
	end
	return result
end

-- set of every stat key bisbeard actually weights, built from the data once
local VALID_WEIGHT_KEYS
local function GetValidWeightKeys()
	if VALID_WEIGHT_KEYS then
		return VALID_WEIGHT_KEYS
	end
	VALID_WEIGHT_KEYS = {}
	for _, w in pairs(D.weights or {}) do
		for k in pairs(w) do
			VALID_WEIGHT_KEYS[k] = true
		end
	end
	return VALID_WEIGHT_KEYS
end

-- Import a weight string as the COMPLETE weight set for the active spec:
-- imported stats take their given value, every other bisbeard-weighted stat is
-- pinned to 0, so the effective weights are exactly what was shared (this is
-- also what round-trips a BisBuddy/GearWeights export faithfully).
-- Returns ok, appliedCount (or false, errorMessage).
local function ImportWeights(str)
	if not specKey then
		return false, "no spec detected"
	end
	if not str or strtrim(str) == "" then
		return false, "empty string"
	end
	local ok, json = pcall(Base64Decode, strtrim(str))
	if not ok or json == "" then
		return false, "couldn't decode that (is it a full weight string?)"
	end
	local data = FlatJsonDecode(json)
	local valid = GetValidWeightKeys()
	local imported, count = {}, 0
	for k, v in pairs(data) do
		if valid[k] and type(v) == "number" then
			imported[k] = v
			count = count + 1
		end
	end
	if count == 0 then
		return false, "no recognizable weights in that string"
	end
	local custom = {}
	for k, v in pairs(imported) do
		custom[k] = v
	end
	for k in pairs(D.weights[specKey] or {}) do
		if custom[k] == nil then
			custom[k] = 0 -- pin unlisted weighted stats to 0 => exact imported set
		end
	end
	db.customWeights[specKey] = custom
	BuildRankIndex()
	wipe(equippedScoreCache)
	return true, count
end

-- Export the active spec's current (effective) non-zero weights as a string.
local function ExportWeights()
	if not specKey then
		return nil
	end
	local eff = ComputeEffectiveWeights() or {}
	local out = {}
	for k, v in pairs(eff) do
		if v and v ~= 0 then
			out[k] = v
		end
	end
	return Base64Encode(FlatJsonEncode(out))
end

--------------------------------------------------------------------------------
-- Custom weight editing (commands + panel)
--------------------------------------------------------------------------------

local STAT_ALIASES = {
	sp = "spellPower", spellpower = "spellPower", spelldamage = "spellDamage", sd = "spellDamage",
	int = "intellect", intellect = "intellect", str = "strength", strength = "strength",
	agi = "agility", agility = "agility", sta = "stamina", stamina = "stamina",
	spi = "spirit", spirit = "spirit", healing = "healingPower", healingpower = "healingPower",
	hp = "healingPower", crit = "critRating", cr = "critRating", critrating = "critRating",
	haste = "hasteRating", ht = "hasteRating", hit = "hitRating", exp = "expertise",
	expertise = "expertise", ap = "attackPower", attackpower = "attackPower",
	rap = "rangedAttackPower", rangedap = "rangedAttackPower", arp = "armorPenetration",
	armorpen = "armorPenetration", wdps = "weaponDps", weapondps = "weaponDps",
	rdps = "rangedDps", rangeddps = "rangedDps", def = "defense", defense = "defense",
	dodge = "dodge", parry = "parry", block = "block", bv = "blockValue",
	blockvalue = "blockValue", mp5 = "mp5",
}

local function ResolveStatKey(name)
	local norm = strlower(name or ""):gsub("[^a-z0-9]", "")
	if norm == "" then
		return nil
	end
	if STAT_ALIASES[norm] then
		return STAT_ALIASES[norm]
	end
	for _, s in ipairs(WEIGHT_STATS) do
		if strlower(s[1]) == norm or strlower((s[2]):gsub("%s", "")) == norm then
			return s[1]
		end
	end
	return nil
end

-- Set/clear one stat override for the active spec, then rebuild rankings.
local function ApplyWeightEdit(statKey, text)
	if not specKey then
		return false
	end
	local custom = db.customWeights[specKey]
	if not custom then
		custom = {}
		db.customWeights[specKey] = custom
	end
	local base = D.weights[specKey] or {}
	if text == nil or strtrim(text) == "" then
		custom[statKey] = nil            -- blank clears the override
	else
		local val = tonumber(text)
		if not val then
			return false
		end
		if val == (base[statKey] or 0) then
			custom[statKey] = nil        -- equals bisbeard default => not an override
		else
			custom[statKey] = val
		end
	end
	if not next(custom) then
		db.customWeights[specKey] = nil  -- no overrides left => back to pure bisbeard
	end
	BuildRankIndex()
	wipe(equippedScoreCache)
	return true
end

local weightsPanel

local function RefreshWeightsPanel()
	if not weightsPanel or not weightsPanel:IsShown() then
		return
	end
	local base = (specKey and D.weights[specKey]) or {}
	local custom = CustomTable(specKey)
	weightsPanel.title:SetText("BisBuddy Weights - " .. (specKey or "no spec detected"))
	if IsSpecCustom() then
		weightsPanel.subtitle:SetText("|cffcc66ffcustom weights|r (edited - Reset for bisbeard defaults)")
	else
		weightsPanel.subtitle:SetText("bisbeard defaults - edit any field to customize")
	end
	local caps = specKey and CAP.spec[specKey]
	if caps and (caps.hit or caps.exp or caps.spen) then
		local parts = {}
		if caps.hit then parts[#parts + 1] = format("%s hit %d", caps.hit, CAP[caps.hit] or 0) end
		if caps.exp then parts[#parts + 1] = format("expertise %d", CAP.exp) end
		if caps.spen then parts[#parts + 1] = format("spell pen %d", CAP.spen) end
		weightsPanel.capLine:SetText("|cffffcc55Raid caps:|r " .. table.concat(parts, "  |cff666666/|r  ") ..
			"  |cff808080(rating - gear hit/exp counts only up to the cap)|r")
	else
		weightsPanel.capLine:SetText("|cff808080No hit/expertise cap for this spec (raid content)|r")
	end
	for _, row in ipairs(weightsPanel.rows) do
		local overridden = custom and custom[row.key] ~= nil
		local eff = (overridden and custom[row.key]) or base[row.key] or 0
		if not row.edit:HasFocus() then
			row.edit:SetText(tostring(eff))
		end
		if overridden then
			row.label:SetTextColor(0.8, 0.5, 1.0)
		else
			row.label:SetTextColor(0.9, 0.9, 0.9)
		end
	end
end

-- Shared panel look: solid-black interior (readability) inside the WoW gold
-- dialog border. Used by every BisBuddy window.
local function StyleDialog(f)
	f:SetBackdrop({
		bgFile = "Interface\\Buttons\\WHITE8X8",
		edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
		tile = false, edgeSize = 24,
		insets = { left = 6, right = 6, top = 6, bottom = 6 },
	})
	f:SetBackdropColor(0, 0, 0, 1)          -- opaque black
	f:SetBackdropBorderColor(1, 1, 1, 1)     -- default gold border tint
end

-- Panel position memory: remember where the user drags each window (saved
-- account-wide), and open secondary panels docked to the RIGHT of the main
-- panel so they don't land on top of it.
local function SavePanelPos(f)
	local name = f:GetName()
	if not name then return end
	db.ui = db.ui or {}
	local point, relTo, relPoint, x, y = f:GetPoint()
	db.ui[name] = { point, (relTo and relTo.GetName and relTo:GetName()) or "UIParent", relPoint, x, y }
end

local function PlacePanel(f, dockBeside)
	local name = f:GetName()
	local p = name and db.ui and db.ui[name]
	f:ClearAllPoints()
	if p then
		f:SetPoint(p[1] or "CENTER", _G[p[2]] or UIParent, p[3] or p[1] or "CENTER", p[4] or 0, p[5] or 0)
	elseif dockBeside and BisBuddyFrame and BisBuddyFrame ~= f and BisBuddyFrame:IsShown() then
		f:SetPoint("TOPLEFT", BisBuddyFrame, "TOPRIGHT", 12, 0)
	else
		f:SetPoint("CENTER")
	end
end

-- Taint-free dropdown. Blizzard's UIDropDownMenu shares global menu state, and
-- driving it from an addon taints that state, which then BLOCKS unrelated secure
-- actions (Ascension PvP-ruleset switch, ConfirmBindOnUse on right-click-to-bind).
-- This widget uses only private frames, so it never taints anything.
local MakeDropdown
do
	local openDD
	local function closeDD()
		if openDD then
			openDD.list:Hide()
			openDD.navState = nil
			openDD = nil
		end
	end

	MakeDropdown = function(parent, name, width)
		local dd = CreateFrame("Button", name, parent)
		dd:SetWidth(width)
		dd:SetHeight(26)
		dd:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8",
			edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", tile = false, edgeSize = 14,
			insets = { left = 3, right = 3, top = 3, bottom = 3 } })
		dd:SetBackdropColor(0.08, 0.08, 0.08, 1)
		dd:SetBackdropBorderColor(0.45, 0.45, 0.45, 1)
		dd.label = dd:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		dd.label:SetPoint("LEFT", 8, 0)
		dd.label:SetPoint("RIGHT", -18, 0)
		dd.label:SetJustifyH("LEFT")
		local arrow = dd:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		arrow:SetPoint("RIGHT", -7, -1)
		arrow:SetText("|cff909090v|r")

		local list = CreateFrame("Frame", nil, dd)
		list:SetFrameStrata("FULLSCREEN_DIALOG")
		list:EnableMouse(true)
		list:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8",
			edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", tile = false, edgeSize = 14,
			insets = { left = 3, right = 3, top = 3, bottom = 3 } })
		list:SetBackdropColor(0, 0, 0, 0.96)
		list:SetBackdropBorderColor(0.5, 0.5, 0.5, 1)
		list:Hide()
		dd.list = list
		dd.rows = {}
		dd.navState = nil

		local function rebuild()
			for _, r in ipairs(dd.rows) do r:Hide() end
			local n = 0
			local function add(text, func, checked, keepOpen)
				n = n + 1
				local r = dd.rows[n]
				if not r then
					r = CreateFrame("Button", nil, list)
					r:SetHeight(18)
					r.t = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
					r.t:SetPoint("LEFT", 8, 0)
					r.t:SetPoint("RIGHT", -8, 0)
					r.t:SetJustifyH("LEFT")
					local hl = r:CreateTexture(nil, "HIGHLIGHT")
					hl:SetAllPoints()
					hl:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
					hl:SetBlendMode("ADD")
					hl:SetAlpha(0.5)
					dd.rows[n] = r
				end
				r:SetPoint("TOPLEFT", list, "TOPLEFT", 4, -4 - (n - 1) * 18)
				r:SetPoint("TOPRIGHT", list, "TOPRIGHT", -4, -4 - (n - 1) * 18)
				r.t:SetText((checked and "|cff40ff40> |r" or "") .. text)
				r:SetScript("OnClick", function()
					if func then func() end
					if keepOpen then rebuild() else closeDD() end
				end)
				r:Show()
			end
			if dd.builder then dd.builder(add) end
			if n == 0 then add("(none)", nil, false) end
			list:SetWidth(width)
			list:SetHeight(8 + n * 18)
		end

		dd:SetScript("OnClick", function(self)
			if openDD == self then closeDD(); return end
			closeDD()
			rebuild()
			list:ClearAllPoints()
			list:SetPoint("TOPLEFT", self, "BOTTOMLEFT", 0, -2)
			list:Show()
			openDD = self
		end)

		function dd:SetText(t) self.label:SetText(t or "") end
		function dd:SetBuilder(fn) self.builder = fn end
		return dd
	end
end

local function CreateWeightsPanel()
	if weightsPanel then
		return weightsPanel
	end
	local f = CreateFrame("Frame", "BisBuddyWeightsFrame", UIParent)
	f:SetWidth(474)
	f:SetHeight(416)
	f:SetPoint("CENTER")
	f:SetFrameStrata("DIALOG")
	StyleDialog(f)
	f:SetMovable(true)
	f:EnableMouse(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing(); SavePanelPos(self) end)
	tinsert(UISpecialFrames, "BisBuddyWeightsFrame") -- Esc closes

	f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	f.title:SetPoint("TOP", 0, -14)
	f.subtitle = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	f.subtitle:SetPoint("TOP", 0, -34)

	local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", -6, -6)

	f.rows = {}
	local perCol = math.ceil(#WEIGHT_STATS / 2)
	for i, s in ipairs(WEIGHT_STATS) do
		local key, label = s[1], s[2]
		local col = (i > perCol) and 1 or 0
		local rowIdx = (i - 1) % perCol
		local x = 22 + col * 232
		local y = -56 - rowIdx * 24
		local lbl = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		lbl:SetPoint("TOPLEFT", x, y)
		lbl:SetWidth(100)
		lbl:SetJustifyH("LEFT")
		lbl:SetText(label)
		local edit = CreateFrame("EditBox", "BisBuddyWeightEdit_" .. key, f, "InputBoxTemplate")
		edit:SetPoint("TOPLEFT", x + 104, y + 2)
		edit:SetWidth(48)
		edit:SetHeight(18)
		edit:SetAutoFocus(false)
		edit.key = key
		edit:SetScript("OnEnterPressed", function(self)
			self:ClearFocus()
		end)
		edit:SetScript("OnEscapePressed", function(self)
			self:ClearFocus()
			RefreshWeightsPanel()
		end)
		edit:SetScript("OnEditFocusLost", function(self)
			ApplyWeightEdit(self.key, self:GetText())
			RefreshWeightsPanel()
			if AuctionFrameBrowse then end -- no-op guard
		end)
		f.rows[#f.rows + 1] = { key = key, label = lbl, edit = edit }
	end

	local reset = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	reset:SetWidth(150)
	reset:SetHeight(22)
	reset:SetPoint("BOTTOMLEFT", 18, 16)
	reset:SetText("Reset to BisBeard")
	reset:SetScript("OnClick", function()
		if specKey then
			db.customWeights[specKey] = nil
			BuildRankIndex()
			wipe(equippedScoreCache)
			RefreshWeightsPanel()
			Print("weights reset to bisbeard for " .. specKey)
		end
	end)

	local export = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	export:SetWidth(90)
	export:SetHeight(22)
	export:SetPoint("BOTTOMRIGHT", -18, 16)
	export:SetText("Export")
	export:SetScript("OnClick", function() StaticPopup_Show("BISBUDDY_EXPORT") end)

	local import = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	import:SetWidth(90)
	import:SetHeight(22)
	import:SetPoint("BOTTOMRIGHT", -112, 16)
	import:SetText("Import")
	import:SetScript("OnClick", function() StaticPopup_Show("BISBUDDY_IMPORT") end)

	local note = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	note:SetPoint("BOTTOM", 0, 44)
	note:SetText("Type a number, press Enter. Blank = bisbeard default. Import/Export share weights as a string.")

	f.capLine = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	f.capLine:SetPoint("BOTTOM", 0, 64)
	f.capLine:SetWidth(450)

	f:Hide() -- created hidden so the first /bb weights opens it
	weightsPanel = f
	return f
end

local function ToggleWeightsPanel()
	RefreshSpec(true)
	local f = CreateWeightsPanel()
	if f:IsShown() then
		f:Hide()
	else
		PlacePanel(f, true)
		f:Show()
		RefreshWeightsPanel()
	end
end

--------------------------------------------------------------------------------
-- Sources panel (/bb sources) - per-source-category visibility toggles. Ticking
-- a box off removes that source's gear from every BiS list + upgrade check.
--------------------------------------------------------------------------------

local sourcesPanel

local function SetSource(key, v)
	db.sources = db.sources or {}
	db.sources[key] = v and true or false
	BuildRankIndex()
	wipe(equippedScoreCache)
end

local function RefreshSourcesPanel()
	if not sourcesPanel or not sourcesPanel:IsShown() then
		return
	end
	db.sources = db.sources or {}
	for _, row in ipairs(sourcesPanel.rows) do
		row.cb:SetChecked(db.sources[row.key] ~= false)
	end
end

local function CreateSourcesPanel()
	if sourcesPanel then
		return sourcesPanel
	end
	local f = CreateFrame("Frame", "BisBuddySourcesFrame", UIParent)
	f:SetWidth(300)
	f:SetHeight(322)
	f:SetPoint("CENTER")
	f:SetFrameStrata("DIALOG")
	StyleDialog(f)
	f:SetMovable(true)
	f:EnableMouse(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing(); SavePanelPos(self) end)
	tinsert(UISpecialFrames, "BisBuddySourcesFrame") -- Esc closes

	f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	f.title:SetPoint("TOP", 0, -14)
	f.title:SetText("BisBuddy Sources")
	f.subtitle = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	f.subtitle:SetPoint("TOP", 0, -34)
	f.subtitle:SetText("untick a source to hide its gear from BiS")

	local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", -6, -6)

	f.rows = {}
	for i, s in ipairs(SOURCE_BUCKETS) do
		local key, label = s[1], s[2]
		local y = -54 - (i - 1) * 20
		local cb = CreateFrame("CheckButton", "BisBuddySrcCheck_" .. key, f, "UICheckButtonTemplate")
		cb:SetWidth(22)
		cb:SetHeight(22)
		cb:SetPoint("TOPLEFT", 26, y)
		local t = _G["BisBuddySrcCheck_" .. key .. "Text"]
		t:SetText(label)
		t:SetFontObject(GameFontHighlightSmall)
		cb.key = key
		cb:SetScript("OnClick", function(self)
			SetSource(self.key, self:GetChecked() and true or false)
		end)
		f.rows[#f.rows + 1] = { key = key, cb = cb }
	end

	local all = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	all:SetWidth(130)
	all:SetHeight(22)
	all:SetPoint("BOTTOM", 0, 16)
	all:SetText("Enable all")
	all:SetScript("OnClick", function()
		db.sources = db.sources or {}
		for _, s in ipairs(SOURCE_BUCKETS) do db.sources[s[1]] = true end
		BuildRankIndex()
		wipe(equippedScoreCache)
		RefreshSourcesPanel()
	end)

	f:Hide() -- created hidden so the first /bb sources opens it
	sourcesPanel = f
	return f
end

local function ToggleSourcesPanel()
	local f = CreateSourcesPanel()
	if f:IsShown() then
		f:Hide()
	else
		PlacePanel(f, true)
		f:Show()
		RefreshSourcesPanel()
	end
end

local function DoImport(str)
	local ok, res = ImportWeights(str)
	if ok then
		Print(format("imported |cffffd100%d|r weights for %s. |cffffd100/bb weights|r to review.", res, tostring(specKey)))
	else
		Print("|cffff2020import failed:|r " .. tostring(res))
	end
	RefreshWeightsPanel()
	return ok
end

local function PopupEditBox(self)
	return (self.editBox) or _G[(self:GetName() or "") .. "EditBox"]
end

-- NB: never write the StaticPopupDialogs/UISpecialFrames GLOBAL (taints secure UI at
-- load); only ADD our own keys to the existing Blizzard tables (safe, standard).
StaticPopupDialogs["BISBUDDY_IMPORT"] = {
	text = "Paste a BisBuddy / GearWeights weight string, then Import:",
	button1 = "Import",
	button2 = CANCEL or "Cancel",
	hasEditBox = true,
	editBoxWidth = 260,
	OnShow = function(self)
		local eb = PopupEditBox(self)
		if eb then eb:SetMaxLetters(2000) eb:SetText("") eb:SetFocus() end
	end,
	OnAccept = function(self)
		local eb = PopupEditBox(self)
		if eb then DoImport(eb:GetText()) end
	end,
	EditBoxOnEnterPressed = function(self)
		DoImport(self:GetText())
		self:GetParent():Hide()
	end,
	EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
	timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}
StaticPopupDialogs["BISBUDDY_EXPORT"] = {
	text = "BisBuddy weight string (Ctrl+C to copy):",
	button1 = CLOSE or "Close",
	hasEditBox = true,
	editBoxWidth = 260,
	OnShow = function(self)
		local eb = PopupEditBox(self)
		if eb then
			eb:SetMaxLetters(2000)
			eb:SetText(ExportWeights() or "")
			eb:HighlightText()
			eb:SetFocus()
		end
	end,
	EditBoxOnEnterPressed = function(self) self:GetParent():Hide() end,
	EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
	timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}
StaticPopupDialogs["BISBUDDY_EXTRA"] = {
	text = "Extras.lua line for this item (Ctrl+C to copy, then paste into Extras.lua or send it to be baked in):",
	button1 = CLOSE or "Close",
	hasEditBox = true,
	editBoxWidth = 350,
	OnShow = function(self)
		local eb = PopupEditBox(self)
		if eb then
			eb:SetMaxLetters(500)
			eb:SetText(bbExtraLine or "")
			eb:HighlightText()
			eb:SetFocus()
		end
	end,
	EditBoxOnEnterPressed = function(self) self:GetParent():Hide() end,
	EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
	timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

--------------------------------------------------------------------------------
-- Main panel (/bb) - the setup GUI. Spec / phase / difficulty pickers + toggles.
--------------------------------------------------------------------------------

local mainPanel
local RefreshMainPanel    -- forward declaration (used by control callbacks)
local ToggleTalentsPanel  -- forward declaration (used by the main-panel button)
local ToggleBrowsePanel   -- forward declaration (the "BiS Lists" button)
local ToggleEnchantsPanel -- forward declaration (the "Enchants" button)
local ToggleGearPanel     -- forward declaration (the "Gear" button)
local ToggleSRPanel       -- forward declaration (the "Reserve" button)

-- (PvP/crafted filtering is now part of the unified Sources filter; see
-- db.sources, the Sources panel, and SetSource below.)

-- { {class=, specs={ {spec=, key=}, ... }}, ... } sorted, built once from the data
local classSpecTree
local function ClassSpecTree()
	if classSpecTree then
		return classSpecTree
	end
	local byClass = {}
	for key in pairs(D.weights or {}) do
		local cl, sp = strmatch(key, "^(.-)|(.+)$")
		if cl then
			byClass[cl] = byClass[cl] or {}
			tinsert(byClass[cl], { spec = sp, key = key })
		end
	end
	classSpecTree = {}
	for cl, specs in pairs(byClass) do
		table.sort(specs, function(a, b) return a.spec < b.spec end)
		tinsert(classSpecTree, { class = cl, specs = specs })
	end
	table.sort(classSpecTree, function(a, b) return a.class < b.class end)
	return classSpecTree
end

local function SelectSpec(key)
	local ck = CharKey()
	db.charSpec = db.charSpec or {}
	if ck then db.charSpec[ck] = key end
	db.specOverride = nil
	specCheckedAt = 0
	specKey = nil
	RefreshSpec(true)
	if RefreshMainPanel then RefreshMainPanel() end
end

local function CreateMainPanel()
	if mainPanel then
		return mainPanel
	end
	local f = CreateFrame("Frame", "BisBuddyFrame", UIParent)
	f:SetWidth(360)
	f:SetHeight(372)
	f:SetPoint("CENTER")
	f:SetFrameStrata("DIALOG")
	StyleDialog(f)
	f:SetMovable(true)
	f:EnableMouse(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing(); SavePanelPos(self) end)
	tinsert(UISpecialFrames, "BisBuddyFrame")

	f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	f.title:SetPoint("TOP", 0, -14)
	f.title:SetText("BisBuddy")
	f.hint = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	f.hint:SetPoint("TOP", 0, -34)
	f.hint:SetWidth(324)
	f.hint:SetText("Set your spec, phase and difficulty. Then hover any item for its BiS rank + upgrade %.")
	-- out-of-date banner: replaces the hint (same spot) when a newer peer version is seen
	f.oodWarn = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	f.oodWarn:SetPoint("TOP", 0, -30)
	f.oodWarn:SetWidth(330)
	f.oodWarn:SetText("|cffff3030!! BISBUDDY IS OUT OF DATE - UPDATE !!|r")
	f.oodWarn:Hide()
	local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", -6, -6)

	local function rowLabel(text, y)
		local fs = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		fs:SetPoint("TOPLEFT", 12, y)
		fs:SetWidth(64)             -- fixed column, right-justified so labels sit just
		fs:SetJustifyH("RIGHT")     -- left of the dropdowns and never overlap them
		fs:SetText(text)
	end

	-- Spec: nested class -> spec dropdown
	rowLabel("Spec", -66)
	f.specDD = MakeDropdown(f, "BisBuddySpecDropDown", 210)
	f.specDD:SetPoint("TOPLEFT", 80, -60)
	f.specDD:SetBuilder(function(add)
		local dd = f.specDD
		if not dd.navState then                          -- level 1: pick a class
			for _, entry in ipairs(ClassSpecTree()) do
				local class = entry.class
				add(class .. "  |cff888888>|r", function() dd.navState = class end, false, true)
			end
		else                                             -- level 2: pick a spec
			add("|cff888888< back|r", function() dd.navState = nil end, false, true)
			for _, entry in ipairs(ClassSpecTree()) do
				if entry.class == dd.navState then
					for _, s in ipairs(entry.specs) do
						local key = s.key
						add(s.spec, function() SelectSpec(key) end, specKey == key)
					end
				end
			end
		end
	end)

	-- Phase dropdown
	rowLabel("Phase", -104)
	f.phaseDD = MakeDropdown(f, "BisBuddyPhaseDropDown", 210)
	f.phaseDD:SetPoint("TOPLEFT", 80, -98)
	f.phaseDD:SetBuilder(function(add)
		for p = 1, (D.maxPhase or 5) do
			local n = p
			add(n .. " - " .. PhaseLabel(n), function() SetPhase(n); RefreshMainPanel() end, db.phase == n)
		end
	end)

	-- Difficulty: two independent caps - raid gear (Normal..Ascended) + dungeon/M+ gear.
	rowLabel("Difficulty", -142)
	f.raidDD = MakeDropdown(f, "BisBuddyRaidDiffDropDown", 122)
	f.raidDD:SetPoint("TOPLEFT", 80, -136)
	f.raidDD:SetBuilder(function(add)
		for d = 1, 4 do
			local n = d
			add(DiffLabel(n), function() SetDiff("raid", n); RefreshMainPanel() end, db.raidDiff == n)
		end
	end)
	f.mplusDD = MakeDropdown(f, "BisBuddyMplusDiffDropDown", 122)
	f.mplusDD:SetPoint("TOPLEFT", 208, -136)
	f.mplusDD:SetBuilder(function(add)
		for _, n in ipairs({ 1, 2, 3, 5 }) do   -- dungeon tiers: Normal/Heroic/Mythic + M+10 (no Ascended)
			add(DiffLabel(n), function() SetDiff("mplus", n); RefreshMainPanel() end, db.mplusDiff == n)
		end
	end)

	local function makeCheck(name, text, x, y, onClick)
		local cb = CreateFrame("CheckButton", name, f, "UICheckButtonTemplate")
		cb:SetWidth(24)
		cb:SetHeight(24)
		cb:SetPoint("TOPLEFT", x, y)
		local t = _G[name .. "Text"]
		t:SetText(text)
		t:SetFontObject(GameFontHighlightSmall)
		cb:SetScript("OnClick", function(self) onClick(self:GetChecked() and true or false) end)
		return cb
	end
	local srcBtn = CreateFrame("Button", "BisBuddySourcesBtn", f, "UIPanelButtonTemplate")
	srcBtn:SetWidth(150)
	srcBtn:SetHeight(22)
	srcBtn:SetPoint("TOPLEFT", 20, -178)
	srcBtn:SetText("Sources filter...")
	srcBtn:SetScript("OnClick", function() ToggleSourcesPanel() end)
	f.alertCB = makeCheck("BisBuddyAlertCheck", "Drop alerts, top-", 20, -204,
		function(checked) db.alerts = checked end)
	f.threshEB = CreateFrame("EditBox", "BisBuddyThreshEdit", f, "InputBoxTemplate")
	f.threshEB:SetWidth(28)
	f.threshEB:SetHeight(18)
	f.threshEB:SetPoint("LEFT", _G["BisBuddyAlertCheckText"], "RIGHT", 6, 0)
	f.threshEB:SetAutoFocus(false)
	f.threshEB:SetScript("OnEnterPressed", function(self)
		local v = tonumber(self:GetText())
		if v then db.threshold = math.max(1, math.min(MERGE_DEPTH, v)) end
		self:ClearFocus()
		RefreshMainPanel()
	end)
	f.threshEB:SetScript("OnEscapePressed", function(self) self:ClearFocus(); RefreshMainPanel() end)
	f.tooltipCB = makeCheck("BisBuddyTooltipCheck", "Tooltip hints", 20, -228,
		function(checked) db.tooltip = checked end)

	local function makeButton(text, x, y, w, onClick)
		local b = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
		b:SetWidth(w)
		b:SetHeight(22)
		b:SetPoint("TOPLEFT", x, y)
		b:SetText(text)
		b:SetScript("OnClick", onClick)
		return b
	end
	-- row 1: the viewer panels
	makeButton("Gear", 20, -262, 74, function() ToggleGearPanel() end)
	makeButton("BiS Lists", 102, -262, 74, function() ToggleBrowsePanel() end)
	makeButton("Enchants", 184, -262, 74, function() ToggleEnchantsPanel() end)
	makeButton("Talents", 266, -262, 74, function() ToggleTalentsPanel() end)
	-- row 2: weight tools
	makeButton("Reserve", 20, -290, 74, function() ToggleSRPanel() end)
	makeButton("Weights", 102, -290, 74, function() ToggleWeightsPanel() end)
	makeButton("Import", 184, -290, 74, function() StaticPopup_Show("BISBUDDY_IMPORT") end)
	makeButton("Export", 266, -290, 74, function() if ExportWeights() then StaticPopup_Show("BISBUDDY_EXPORT") end end)

	f.status = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	f.status:SetPoint("BOTTOM", 0, 16)
	f.status:SetWidth(324)

	f:Hide()
	mainPanel = f
	return f
end

RefreshMainPanel = function()
	if not mainPanel or not mainPanel:IsShown() then
		return
	end
	local f = mainPanel
	if warnedOutOfDate then f.oodWarn:Show(); f.hint:Hide() else f.oodWarn:Hide(); f.hint:Show() end
	f.specDD:SetText(specKey or "not set - pick your spec")
	f.phaseDD:SetText(db.phase .. " - " .. PhaseLabel(db.phase))
	f.raidDD:SetText("Raid: " .. DiffLabel(db.raidDiff))
	f.mplusDD:SetText("M+: " .. DiffLabel(db.mplusDiff))
	f.alertCB:SetChecked(db.alerts)
	f.tooltipCB:SetChecked(db.tooltip)
	if not f.threshEB:HasFocus() then f.threshEB:SetText(tostring(db.threshold)) end
	if specKey then
		f.status:SetText(D.cells[specKey] and ("|cff20ff20Ready|r - ranks loaded for " .. specKey)
			or ("|cffff2020no rank data|r for " .. specKey))
	else
		f.status:SetText("|cffff2020No spec set|r - pick it from the Spec dropdown above.")
	end
end

local function ShowMainPanel()
	RefreshSpec(true)
	local f = CreateMainPanel()
	PlacePanel(f, false)
	f:Show()
	RefreshMainPanel()
end

local function ToggleMainPanel()
	local f = CreateMainPanel()
	if f:IsShown() then
		f:Hide()
	else
		ShowMainPanel()
	end
end

--------------------------------------------------------------------------------
-- Talent tree panel (/bb talents): the spec's trees as a grid, each node
-- coloured by how often the top players take it (green/orange/red).
--------------------------------------------------------------------------------

local TAL -- BisBuddyTalents (set at load)
local talentsPanel
local NODE = 26  -- grid cell size (px)

local function LightColor(pct)
	if pct >= 80 then
		return 0.15, 0.85, 0.15, 0.9      -- green: most take it
	elseif pct >= 25 then
		return 1.0, 0.62, 0.10, 0.9       -- orange: build-dependent
	end
	return 0.72, 0.20, 0.20, 0.45         -- red: rarely taken (dimmed)
end

-- take-rate table {n,pct} for the currently-selected source, with fallbacks
local function TalentRates(sk)
	local t = sk and TAL and TAL.takeRates and TAL.takeRates[sk]
	if not t then return nil end
	if t.pct then return t end                        -- legacy single-source schema
	local src = db.talentSource or "raid"
	local other = (src == "raid") and "dungeon" or "raid"
	return t[src] or t[other]
end

-- do we have BOTH raid and dungeon data for this spec? (whether to show the toggle)
local function TalentHasBothSources(sk)
	local t = sk and TAL and TAL.takeRates and TAL.takeRates[sk]
	return t and not t.pct and t.raid and t.dungeon
end

-- horizontal offset so choice-node siblings (several talents in one grid cell) fan out
local function talDX(tree, nd)
	local cnt, idx = 0, 0
	for _, o in ipairs(tree.nodes) do
		if o.row == nd.row and o.col == nd.col then
			if o == nd then idx = cnt end
			cnt = cnt + 1
		end
	end
	if cnt <= 1 then return 0 end
	return (idx - (cnt - 1) / 2) * (NODE - 6)
end

local function AcquireNode(i)
	local b = talentsPanel.nodes[i]
	if not b then
		b = CreateFrame("Button", "BisBuddyTalNode" .. i, talentsPanel)
		b:SetWidth(NODE - 2)
		b:SetHeight(NODE - 2)
		b.bg = b:CreateTexture(nil, "BACKGROUND")
		b.bg:SetAllPoints(b)
		b.icon = b:CreateTexture(nil, "ARTWORK")
		b.icon:SetWidth(NODE - 6)
		b.icon:SetHeight(NODE - 6)
		b.icon:SetPoint("CENTER")
		-- take-rate % label (corner, like a stack count) shown on contested nodes
		b.pctlabel = b:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
		b.pctlabel:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", 2, -1)
		b.pctlabel:SetTextColor(1, 1, 1)
		b.pctlabel:SetShadowColor(0, 0, 0, 1)
		b.pctlabel:SetShadowOffset(1, -1)
		b:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetText(self.tname, self.tr, self.tg, self.tb)
			GameTooltip:AddLine(self.tpct, 1, 1, 1)
			if self.tdesc and self.tdesc ~= "" then
				GameTooltip:AddLine(self.tdesc, 0.8, 0.8, 0.8, true)
			end
			GameTooltip:Show()
		end)
		b:SetScript("OnLeave", function() GameTooltip:Hide() end)
		talentsPanel.nodes[i] = b
	end
	return b
end

local RenderTalents
local function CreateTalentsPanel()
	if talentsPanel then
		return talentsPanel
	end
	local f = CreateFrame("Frame", "BisBuddyTalentsFrame", UIParent)
	f:SetWidth(680)
	f:SetHeight(420)
	f:SetPoint("CENTER")
	f:SetFrameStrata("DIALOG")
	StyleDialog(f)
	f:SetMovable(true)
	f:EnableMouse(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing(); SavePanelPos(self) end)
	tinsert(UISpecialFrames, "BisBuddyTalentsFrame")
	f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	f.title:SetPoint("TOP", 0, -14)
	f.legend = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	f.legend:SetPoint("TOP", 0, -36)
	f.headers = {}
	f.nodes = {}
	local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", -6, -6)
	-- raid/dungeon source toggle (only shown when both datasets exist for the spec)
	local src = CreateFrame("Button", "BisBuddyTalSrcBtn", f, "UIPanelButtonTemplate")
	src:SetWidth(104)
	src:SetHeight(20)
	src:SetPoint("TOPRIGHT", close, "TOPLEFT", -2, -2)
	src:SetScript("OnClick", function()
		db.talentSource = (db.talentSource == "dungeon") and "raid" or "dungeon"
		RenderTalents()
	end)
	src:Hide()
	f.srcBtn = src
	f:Hide()
	talentsPanel = f
	return f
end

RenderTalents = function()
	local f = talentsPanel
	if not f or not f:IsShown() then
		return
	end
	for _, b in ipairs(f.nodes) do b:Hide() end
	for _, h in ipairs(f.headers) do h:Hide() end
	local shortSpec = specKey and (strmatch(specKey, "|(.+)$") or specKey) or "no spec"
	f.title:SetText("Recommended Talents - " .. shortSpec)
	local class = specKey and strmatch(specKey, "^(.-)|")
	local ct = class and TAL and TAL.trees[class]
	local tr = TalentRates(specKey)
	if not ct or not tr then
		if f.srcBtn then f.srcBtn:Hide() end
		f.legend:SetText("|cffff2020no talent data for this spec yet|r (run talents_generate.py)")
		f:SetWidth(360)
		return
	end
	-- raid/dungeon toggle (only when both datasets exist for this spec)
	local both = TalentHasBothSources(specKey)
	if f.srcBtn then
		if both then
			f.srcBtn:SetText((db.talentSource or "raid") == "dungeon" and "Source: Dungeon" or "Source: Raid")
			f.srcBtn:Show()
		else
			f.srcBtn:Hide()
		end
	end
	local srcLabel = both and (((db.talentSource or "raid") == "dungeon") and "dungeon" or "ZG raid") or "top"
	f.legend:SetText(format("|cff26d926green|r most  |cffffa020orange|r optional  |cffcc3030red|r rare   -   %s, top %d", srcLabel, tr.n))

	local topY, ni, hi, colX, maxRowAll = -60, 0, 0, 16, 0
	for _, slug in ipairs(ct.order) do
		local tree = ct.trees[slug]
		local relevant, maxCol, maxRow = false, 0, 0
		for _, nd in ipairs(tree.nodes) do
			if (tr.pct[nd.id] or 0) >= 60 then relevant = true end
			if nd.col > maxCol then maxCol = nd.col end
			if nd.row > maxRow then maxRow = nd.row end
		end
		if relevant then
			hi = hi + 1
			local h = f.headers[hi]
			if not h then
				h = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
				f.headers[hi] = h
			end
			h:ClearAllPoints()
			h:SetPoint("TOPLEFT", f, "TOPLEFT", colX, topY + 18)
			h:SetText(tree.label)
			h:Show()
			for _, nd in ipairs(tree.nodes) do
				ni = ni + 1
				local b = AcquireNode(ni)
				local p = tr.pct[nd.id] or 0
				b:ClearAllPoints()
				b:SetPoint("TOPLEFT", f, "TOPLEFT", colX + nd.col * NODE + talDX(tree, nd), topY - nd.row * NODE)
				b.icon:SetTexture("Interface\\Icons\\" .. (nd.icon ~= "" and nd.icon or "INV_Misc_QuestionMark"))
				local r, g, bl, a = LightColor(p)
				b.bg:SetTexture(r, g, bl, a)
				b.icon:SetAlpha(p >= 25 and 1.0 or 0.5)
				if p >= 5 and p <= 95 then b.pctlabel:SetText(p); b.pctlabel:Show() else b.pctlabel:Hide() end
					b.tname, b.tr, b.tg, b.tb = nd.name, r, g, bl
				b.tpct = format("Taken by %d%% of the top %d", p, tr.n)
				b.tdesc = nd.desc
				b:Show()
			end
			if maxRow > maxRowAll then maxRowAll = maxRow end
			colX = colX + (maxCol + 2) * NODE
		end
	end
	f:SetWidth(math.max(380, colX + 8))
	f:SetHeight(math.max(200, 76 + (maxRowAll + 1) * NODE))
end

ToggleTalentsPanel = function()
	RefreshSpec(true)
	local f = CreateTalentsPanel()
	if f:IsShown() then
		f:Hide()
	else
		PlacePanel(f, true)
		f:Show()
		RenderTalents()
	end
end

--------------------------------------------------------------------------------
-- BiS Lists browser (/bb list, or the "BiS Lists" button): pick an item slot
-- from a dropdown and see its full ranked list for the current spec/phase/diff.
-- Reads activeSlotRanks, which BuildRankIndex keeps live via RenderBrowse.
--------------------------------------------------------------------------------

-- display order + friendlier labels for the slot picker
local BROWSE_SLOT_ORDER = {
	"Head", "Neck", "Shoulders", "Back", "Chest", "Wrists", "Hands", "Waist",
	"Legs", "Feet", "Finger", "Trinket", "Main Hand", "One-Hand", "Two-Hand",
	"Off Hand", "Shield", "Held In Off-hand", "Ranged",
}
local BROWSE_SLOT_LABEL = {
	Finger = "Rings", Trinket = "Trinkets", ["Held In Off-hand"] = "Held (off-hand)",
}
local BROWSE_MAX_GROUPS = 15    -- distinct items listed per slot
local BROWSE_MAX_VARIANTS = 12  -- difficulty/version rows kept per item (for expand)
local ELLIPSIS = "\226\128\166"

local browsePanel, browseSlot
local browseExpanded = {}       -- ["slot\0itemName"] = true when its versions are shown

-- truncate to n visible chars with a trailing ellipsis (keeps rows inside the border)
local function Clip(s, n)
	if s and #s > n then return s:sub(1, n - 1) .. ELLIPSIS end
	return s or "?"
end

-- item quality colour escape (falls back to white for uncached items)
local function ItemHex(id)
	local q = select(3, GetItemInfo(id))
	if q then local _, _, _, h = GetItemQualityColor(q); if h then return h end end
	return "|cffffffff"
end

local function BrowseRow(f, i)
	local r = f.rows[i]
	if r then return r end
	r = CreateFrame("Button", nil, f)
	r:SetHeight(15)
	r:SetPoint("TOPLEFT", 18, -86 - (i - 1) * 16)
	r:SetPoint("RIGHT", f, "RIGHT", -16, 0)
	local hl = r:CreateTexture(nil, "HIGHLIGHT")
	hl:SetAllPoints()
	hl:SetTexture(1, 1, 1, 0.10)
	r.text = r:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	r.text:SetPoint("LEFT", 2, 0)
	r.text:SetJustifyH("LEFT")
	r:SetScript("OnEnter", function(self)
		if not self.itemId then return end
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetHyperlink("item:" .. self.itemId)
		GameTooltip:Show()
	end)
	r:SetScript("OnLeave", function() GameTooltip:Hide() end)
	r:SetScript("OnClick", function(self)
		if IsControlKeyDown() then
			if self.itemId then local link = select(2, GetItemInfo(self.itemId)); if link and DressUpItemLink then DressUpItemLink(link) end end
		elseif IsShiftKeyDown() then
			if self.itemId then
				local link = select(2, GetItemInfo(self.itemId))
				if link and ChatEdit_InsertLink then ChatEdit_InsertLink(link) end
			end
		elseif self.expandKey then
			browseExpanded[self.expandKey] = not browseExpanded[self.expandKey]
			RenderBrowse()
		end
	end)
	f.rows[i] = r
	return r
end

RenderBrowse = function()
	local f = browsePanel
	if not f or not f:IsShown() then
		return
	end
	-- caps/weights may have just changed => equipped scores are stale
	wipe(equippedScoreCache)
	-- pick a slot that actually has data at the current caps
	local avail = {}
	for _, s in ipairs(BROWSE_SLOT_ORDER) do
		local lst = activeSlotRanks[s]
		if lst and #lst > 0 then avail[s] = true end
	end
	if not (browseSlot and avail[browseSlot]) then
		browseSlot = nil
		for _, s in ipairs(BROWSE_SLOT_ORDER) do
			if avail[s] then browseSlot = s break end
		end
	end
	f.slotDD:SetText(browseSlot and (BROWSE_SLOT_LABEL[browseSlot] or browseSlot) or "no data")

	if specKey then
		local tag = IsSpecCustom() and "   |cffcc66ff(custom weights - /bb weights to reset)|r" or ""
		if warnedOutOfDate then tag = tag .. "   |cffff3030<< OUT OF DATE - UPDATE! >>|r" end
		f.header:SetText(format("|cffffd100%s|r  -  phase %d %s, raid %s / M+ %s%s",
			(strmatch(specKey, "|(.+)$") or specKey), db.phase, PhaseLabel(db.phase),
			DiffLabel(db.raidDiff), DiffLabel(db.mplusDiff), tag))
	else
		f.header:SetText("|cffff2020No spec set|r - open BisBuddy (/bb) and pick your spec first.")
	end

	for _, r in ipairs(f.rows) do r:Hide() end
	local list = browseSlot and activeSlotRanks[browseSlot]
	local base = browseSlot and BaselineForSlot(browseSlot)

	-- Collapse variants of the same base item into one group. Items with the same
	-- name are the same piece at different difficulty / keystone / bloodforged
	-- versions; the list is score-sorted so variants[1] is the best version.
	local groups, order = {}, {}
	if list then
		for i = 1, #list do
			local id, score = list[i][1], list[i][2]
			local info = D.items[id]
			local nm = info and info[1] or ("item " .. id)
			local g = groups[nm]
			if not g and #order < BROWSE_MAX_GROUPS then
				g = { name = nm, variants = {} }
				groups[nm] = g
				order[#order + 1] = g
			end
			if g and #g.variants < BROWSE_MAX_VARIANTS then
				g.variants[#g.variants + 1] = { id = id, score = score, info = info }
			end
		end
	end

	local shown = 0
	for gi = 1, #order do
		local g = order[gi]
		local best, nvar = g.variants[1], #g.variants
		local key = (browseSlot or "") .. "\0" .. g.name
		local expanded = browseExpanded[key]
		-- representative row: the best version of this item
		shown = shown + 1
		local row = BrowseRow(f, shown)
		row.itemId = best.id
		row.groupName = g.name
		row.expandKey = (nvar > 1) and key or nil
		local ver = (best.info and best.info[2] and best.info[2] ~= "")
			and (" |cff888888[" .. best.info[2] .. "]|r") or ""
		local up = (base and best.score > base) and "|cff20ff20^|r " or "   "
		local badge = ""
		if nvar > 1 then
			badge = expanded and "  |cff54a5ff[- versions]|r"
				or format("  |cff54a5ff[+%d more]|r", nvar - 1)
		end
		row.text:SetText(format("%s|cff999999%2d|r %s%s|r%s   |cff69ccf0%.0f|r  |cff707070%s|r%s",
			up, gi, ItemHex(best.id), Clip(g.name, 30), ver, best.score,
			Clip(best.info and best.info[3] or "?", 22), badge))
		row:Show()
		-- expanded: the same item's other difficulty versions, indented
		if expanded and nvar > 1 then
			for vi = 2, nvar do
				local v = g.variants[vi]
				shown = shown + 1
				local vr = BrowseRow(f, shown)
				vr.itemId = v.id
				vr.groupName = nil
				vr.expandKey = nil
				local vup = (base and v.score > base) and "|cff20ff20^|r" or " "
				vr.text:SetText(format("        %s |cffbfbfbf%s|r   |cff69ccf0%.0f|r  |cff707070%s|r",
					vup, v.info and v.info[2] or "?", v.score, Clip(v.info and v.info[3] or "?", 22)))
				vr:Show()
			end
		end
	end

	if shown == 0 then
		f.footer:SetText(specKey and "|cff808080no items for this slot at the current phase/difficulty.|r" or "")
	elseif base then
		f.footer:SetText(format("baseline |cff69ccf0%.0f|r   |cff20ff20^|r = upgrade   |cff54a5ff[+n]|r = other difficulties   shift-click = link",
			base))
	else
		f.footer:SetText("|cff54a5ff[+n]|r = the item's other difficulties   \194\183   shift-click a row to link it")
	end
	f:SetHeight(100 + math.max(1, shown) * 16 + 28)
end

local function CreateBrowsePanel()
	if browsePanel then
		return browsePanel
	end
	local f = CreateFrame("Frame", "BisBuddyBrowseFrame", UIParent)
	f:SetWidth(520)
	f:SetHeight(320)
	f:SetPoint("CENTER", 150, 0)
	f:SetFrameStrata("DIALOG")
	StyleDialog(f)
	f:SetMovable(true)
	f:EnableMouse(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing(); SavePanelPos(self) end)
	tinsert(UISpecialFrames, "BisBuddyBrowseFrame")

	f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	f.title:SetPoint("TOPLEFT", 16, -14)
	f.title:SetText("BiS Lists")
	local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", -6, -6)

	f.slotDD = MakeDropdown(f, "BisBuddyBrowseSlotDD", 150)
	f.slotDD:SetPoint("TOPLEFT", 16, -38)
	f.slotDD:SetBuilder(function(add)
		for _, s in ipairs(BROWSE_SLOT_ORDER) do
			local slot, lst = s, activeSlotRanks[s]
			if lst and #lst > 0 then
				add(BROWSE_SLOT_LABEL[slot] or slot, function() browseSlot = slot; RenderBrowse() end, browseSlot == slot)
			end
		end
	end)

	f.header = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	f.header:SetPoint("TOPLEFT", 18, -66)
	f.header:SetJustifyH("LEFT")

	f.footer = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	f.footer:SetPoint("BOTTOMLEFT", 18, 14)
	f.footer:SetPoint("BOTTOMRIGHT", -16, 14)
	f.footer:SetJustifyH("LEFT")

	f.rows = {}
	f:Hide()
	browsePanel = f
	return f
end

ToggleBrowsePanel = function()
	RefreshSpec(true)
	local f = CreateBrowsePanel()
	if f:IsShown() then
		f:Hide()
	else
		PlacePanel(f, true)
		f:Show()
		RenderBrowse()
	end
end

--------------------------------------------------------------------------------
-- Best Enchants panel (/bb enchants): the best enchant per gear slot for the
-- active spec, scored by its (effective) weights. Reads BisBuddyData.enchants
-- ({name, slot, {statcode=val}}), which the generator bakes from bisbeard.
--------------------------------------------------------------------------------
local ENCHANT_SLOT_ORDER = {
	"Head", "Shoulders", "Back", "Chest", "Wrists", "Hands", "Waist", "Legs",
	"Feet", "One-Hand", "Two-Hand", "Ranged", "Shield",
}
local ENCHANT_SLOT_LABEL = { ["One-Hand"] = "1H Weapon", ["Two-Hand"] = "2H Weapon" }
local ENCHANT_TOPN = 4  -- best + up to 3 alternates on expand
local STAT_SHORT = {
	int = "Int", str = "Str", agi = "Agi", sta = "Sta", spi = "Spi", sp = "SP",
	hp = "Heal", cr = "Crit", ht = "Haste", hit = "Hit", res = "Resil", exp = "Exp",
	ap = "AP", rap = "RAP", fap = "FAP", arp = "ArP", spen = "SpPen", mp5 = "MP5",
	hp5 = "HP5", def = "Def", dg = "Dodge", par = "Parry", blk = "Block",
	bv = "BlockVal", sbv = "SBV", arm = "Armor",
}

local function StatSummary(stats)
	local parts = {}
	for code, val in pairs(stats) do parts[#parts + 1] = { STAT_SHORT[code] or code, val } end
	table.sort(parts, function(a, b) return a[2] > b[2] end)
	local out = {}
	for i = 1, #parts do out[i] = format("+%g %s", parts[i][2], parts[i][1]) end
	return table.concat(out, ", ")
end

local enchantsBySlot
local function EnchantsBySlot()
	if enchantsBySlot then return enchantsBySlot end
	enchantsBySlot = {}
	for _, e in ipairs(D.enchants or {}) do
		local slot = e[2]
		if slot then
			enchantsBySlot[slot] = enchantsBySlot[slot] or {}
			tinsert(enchantsBySlot[slot], e) -- e = { name, slot, {statcode=val} }
		end
	end
	return enchantsBySlot
end

local function EnchantScore(stats, w)
	local s = 0
	for code, val in pairs(stats) do
		local key = STAT_CODE_TO_KEY[code]
		local wt = key and w[key]
		if wt then s = s + val * wt end
	end
	return s
end

-- top-n enchants for a slot, scored by the active spec's effective weights
local function BestEnchants(slot, n)
	local list = EnchantsBySlot()[slot]
	local w = specWeights or ComputeEffectiveWeights()
	if not list or not w then return {} end
	local scored = {}
	for i = 1, #list do
		local e = list[i]
		scored[i] = { name = e[1], stats = e[3], score = EnchantScore(e[3], w) }
	end
	table.sort(scored, function(a, b) return a.score > b.score end)
	local out = {}
	for i = 1, math.min(n or ENCHANT_TOPN, #scored) do out[i] = scored[i] end
	return out
end

local enchantsPanel
local enchantsExpanded = {}

local function EnchantRow(f, i)
	local r = f.rows[i]
	if r then return r end
	r = CreateFrame("Button", nil, f)
	r:SetHeight(15)
	r:SetPoint("TOPLEFT", 18, -70 - (i - 1) * 16)
	r:SetPoint("RIGHT", f, "RIGHT", -16, 0)
	local hl = r:CreateTexture(nil, "HIGHLIGHT")
	hl:SetAllPoints()
	hl:SetTexture(1, 1, 1, 0.10)
	r.text = r:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	r.text:SetPoint("LEFT", 2, 0)
	r.text:SetJustifyH("LEFT")
	r:SetScript("OnClick", function(self)
		if self.expandKey then
			enchantsExpanded[self.expandKey] = not enchantsExpanded[self.expandKey]
			RenderEnchants()
		end
	end)
	f.rows[i] = r
	return r
end

RenderEnchants = function()
	local f = enchantsPanel
	if not f or not f:IsShown() then
		return
	end
	if specKey then
		f.header:SetText(format("|cffffd100%s|r  -  best enchant per slot for your weights%s",
			(strmatch(specKey, "|(.+)$") or specKey), IsSpecCustom() and " |cffcc66ff(custom)|r" or ""))
	else
		f.header:SetText("|cffff2020No spec set|r - open BisBuddy (/bb) and pick your spec first.")
	end
	for _, r in ipairs(f.rows) do r:Hide() end
	local shown = 0
	for _, slot in ipairs(ENCHANT_SLOT_ORDER) do
		local best = BestEnchants(slot, ENCHANT_TOPN)
		-- skip slots whose best enchant is worthless to this spec (e.g. an
		-- agility weapon enchant for a caster) so the list stays relevant
		if best[1] and best[1].score > 0 then
			local key = slot
			local expanded = enchantsExpanded[key]
			local nalt = #best - 1
			shown = shown + 1
			local row = EnchantRow(f, shown)
			row.enchSlot = slot
			row.expandKey = (nalt > 0) and key or nil
			local b = best[1]
			local badge = ""
			if nalt > 0 then
				badge = expanded and "  |cff54a5ff[- alts]|r" or format("  |cff54a5ff[+%d alts]|r", nalt)
			end
			row.text:SetText(format("|cffffd100%-9s|r %s   |cff8fbf8f%s|r  |cff69ccf0%.0f|r%s",
				ENCHANT_SLOT_LABEL[slot] or slot, Clip(b.name, 26), Clip(StatSummary(b.stats), 30), b.score, badge))
			row:Show()
			if expanded and nalt > 0 then
				for i = 2, #best do
					local a = best[i]
					shown = shown + 1
					local ar = EnchantRow(f, shown)
					ar.enchSlot = nil
					ar.expandKey = nil
					ar.text:SetText(format("           %s   |cff8fbf8f%s|r  |cff69ccf0%.0f|r",
						Clip(a.name, 26), Clip(StatSummary(a.stats), 30), a.score))
					ar:Show()
				end
			end
		end
	end
	if shown == 0 then
		f.footer:SetText(specKey and "|cff808080no enchant data for these slots|r" or "")
	else
		f.footer:SetText("|cff54a5ff[+alts]|r = other good enchants for that slot   \194\183   scored by your weights")
	end
	f:SetHeight(100 + math.max(1, shown) * 16 + 28)
end

local function CreateEnchantsPanel()
	if enchantsPanel then
		return enchantsPanel
	end
	local f = CreateFrame("Frame", "BisBuddyEnchantsFrame", UIParent)
	f:SetWidth(460)
	f:SetHeight(340)
	f:SetPoint("CENTER", 150, -30)
	f:SetFrameStrata("DIALOG")
	StyleDialog(f)
	f:SetMovable(true)
	f:EnableMouse(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing(); SavePanelPos(self) end)
	tinsert(UISpecialFrames, "BisBuddyEnchantsFrame")
	f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	f.title:SetPoint("TOPLEFT", 16, -14)
	f.title:SetText("Best Enchants")
	local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", -6, -6)
	f.header = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	f.header:SetPoint("TOPLEFT", 18, -44)
	f.header:SetJustifyH("LEFT")
	f.footer = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	f.footer:SetPoint("BOTTOMLEFT", 18, 14)
	f.footer:SetPoint("BOTTOMRIGHT", -16, 14)
	f.footer:SetJustifyH("LEFT")
	f.rows = {}
	f:Hide()
	enchantsPanel = f
	return f
end

ToggleEnchantsPanel = function()
	RefreshSpec(true)
	local f = CreateEnchantsPanel()
	if f:IsShown() then
		f:Hide()
	else
		PlacePanel(f, true)
		f:Show()
		RenderEnchants()
	end
end

--------------------------------------------------------------------------------
-- My Gear panel (/bb gear): per-slot audit - your equipped item vs the best you
-- own in your bags vs BiS, plus a "farm next" upgrade list. Advise-only (v1).
--------------------------------------------------------------------------------
-- { inventorySlotId, display label, bisbeard slot for the BiS-standing lookup }
local GEAR_SLOTS = {
	{ 1, "Head", "Head" }, { 2, "Neck", "Neck" }, { 3, "Shoulder", "Shoulders" },
	{ 15, "Back", "Back" }, { 5, "Chest", "Chest" }, { 9, "Wrist", "Wrists" },
	{ 10, "Hands", "Hands" }, { 6, "Waist", "Waist" }, { 7, "Legs", "Legs" },
	{ 8, "Feet", "Feet" }, { 11, "Ring 1", "Finger" }, { 12, "Ring 2", "Finger" },
	{ 13, "Trinket 1", "Trinket" }, { 14, "Trinket 2", "Trinket" },
	{ 16, "Main Hand", "Main Hand" }, { 17, "Off Hand", "Off Hand" }, { 18, "Ranged", "Ranged" },
}
-- equipLoc -> candidate inventory slots (to match a bag item to gear slots)
local EQUIPLOC_TO_INV = {
	INVTYPE_HEAD = { 1 }, INVTYPE_NECK = { 2 }, INVTYPE_SHOULDER = { 3 }, INVTYPE_CLOAK = { 15 },
	INVTYPE_CHEST = { 5 }, INVTYPE_ROBE = { 5 }, INVTYPE_WRIST = { 9 }, INVTYPE_HAND = { 10 },
	INVTYPE_WAIST = { 6 }, INVTYPE_LEGS = { 7 }, INVTYPE_FEET = { 8 }, INVTYPE_FINGER = { 11, 12 },
	INVTYPE_TRINKET = { 13, 14 }, INVTYPE_WEAPON = { 16 }, INVTYPE_WEAPONMAINHAND = { 16 },
	INVTYPE_2HWEAPON = { 16 }, INVTYPE_WEAPONOFFHAND = { 17 }, INVTYPE_SHIELD = { 17 },
	INVTYPE_HOLDABLE = { 17 }, INVTYPE_RANGED = { 18 }, INVTYPE_RANGEDRIGHT = { 18 }, INVTYPE_THROWN = { 18 },
}
-- bisbeard slots scanned for the "farm next" list (covers 1H/2H both ways)
local FARM_SLOTS = {
	"Head", "Neck", "Shoulders", "Back", "Chest", "Wrists", "Hands", "Waist", "Legs",
	"Feet", "Finger", "Trinket", "Main Hand", "One-Hand", "Two-Hand", "Off Hand",
	"Shield", "Held In Off-hand", "Ranged",
}
-- inventory slots that take an enchant (flagged when unenchanted)
local ENCHANTABLE_INV = {
	[1] = true, [3] = true, [15] = true, [5] = true, [9] = true, [10] = true,
	[6] = true, [7] = true, [8] = true, [16] = true, [17] = true, [18] = true,
}

-- best score available now for a bisbeard slot (weapons union the hands)
local function SlotTopScore(bslot)
	local function top(s) local l = activeSlotRanks[s]; return (l and l[1]) and l[1][2] or 0 end
	if bslot == "Main Hand" then
		return math.max(top("Main Hand"), top("One-Hand"), top("Two-Hand"))
	elseif bslot == "Off Hand" then
		return math.max(top("Off Hand"), top("One-Hand"), top("Shield"), top("Held In Off-hand"))
	end
	return top(bslot)
end

-- best usable owned bag item per inventory slot, + a set of owned item ids
local function ScanBags()
	local best, owned = {}, {}
	for bag = 0, 4 do
		for s = 1, (GetContainerNumSlots(bag) or 0) do
			local link = GetContainerItemLink(bag, s)
			if link then
				local id = ItemIdFromLink(link)
				if id then owned[id] = true end
				local _, _, _, _, _, _, _, _, equipLoc = GetItemInfo(link)
				local invs = equipLoc and EQUIPLOC_TO_INV[equipLoc]
				if invs and CanUseItem(link) then
					local sc = ScoreLink(link)
					if sc then
						for _, iv in ipairs(invs) do
							if not best[iv] or sc > best[iv].score then best[iv] = { score = sc, id = id } end
						end
					end
				end
			end
		end
	end
	for iv = 1, 18 do
		local l = GetInventoryItemLink("player", iv)
		local id = l and ItemIdFromLink(l)
		if id then owned[id] = true end
	end
	return best, owned
end

local gearPanel

local function GearRow(f, i)
	local r = f.rows[i]
	if r then return r end
	r = CreateFrame("Button", nil, f)
	r:SetHeight(15)
	r:SetPoint("TOPLEFT", 16, -70 - (i - 1) * 16)
	r:SetPoint("RIGHT", f, "RIGHT", -14, 0)
	local hl = r:CreateTexture(nil, "HIGHLIGHT")
	hl:SetAllPoints()
	hl:SetTexture(1, 1, 1, 0.10)
	r.c1 = r:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	r.c1:SetPoint("LEFT", 2, 0)
	r.c1:SetWidth(66)
	r.c1:SetJustifyH("LEFT")
	r.c2 = r:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	r.c2:SetPoint("LEFT", 72, 0)
	r.c2:SetJustifyH("LEFT")
	r:SetScript("OnEnter", function(self)
		if not self.itemId then return end
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetHyperlink("item:" .. self.itemId)
		GameTooltip:Show()
	end)
	r:SetScript("OnLeave", function() GameTooltip:Hide() end)
	r:SetScript("OnClick", function(self)
		if not self.itemId then return end
		if IsControlKeyDown() then
			local link = select(2, GetItemInfo(self.itemId))
			if link and DressUpItemLink then DressUpItemLink(link) end
		elseif IsShiftKeyDown() then
			local link = select(2, GetItemInfo(self.itemId))
			if link and ChatEdit_InsertLink then ChatEdit_InsertLink(link) end
		end
	end)
	f.rows[i] = r
	return r
end

RenderGear = function()
	local f = gearPanel
	if not f or not f:IsShown() then
		return
	end
	wipe(equippedScoreCache)
	for _, r in ipairs(f.rows) do r:Hide() end
	if not specKey then
		f.header:SetText("|cffff2020No spec set|r - open BisBuddy (/bb) and pick your spec first.")
		f.footer:SetText("")
		f:SetHeight(150)
		return
	end
	local best, owned = ScanBags()
	local shown, sumPct, nSlots = 0, 0, 0
	for _, gs in ipairs(GEAR_SLOTS) do
		local iv, label, bslot = gs[1], gs[2], gs[3]
		local eqLink = GetInventoryItemLink("player", iv)
		local eqScore = eqLink and ScoreLink(eqLink) or nil
		local rowItem = eqLink and ItemIdFromLink(eqLink) or nil
		-- best in bags
		local bag, swap = best[iv], nil
		if bag and (not eqScore or bag.score > eqScore + 0.05) then
			local pct = (eqScore and eqScore > 0) and ((bag.score - eqScore) / eqScore * 100) or 100
			local nm = (D.items[bag.id] and D.items[bag.id][1]) or ("item " .. bag.id)
			swap = format("|cff20ff20\226\134\145 %s +%.0f%%|r", Clip(nm, 16), pct)
			rowItem = bag.id
		elseif eqLink then
			swap = "|cff777777worn|r"
		else
			swap = "|cff777777\226\128\148|r"
		end
		-- BiS standing + % of BiS
		local topScore = SlotTopScore(bslot)
		local standing
		if eqLink and eqScore and topScore > 0 then
			local pct = math.min(100, eqScore / topScore * 100)
			sumPct = sumPct + pct; nSlots = nSlots + 1
			local rid = ItemIdFromLink(eqLink)
			local rk = rid and rankIndex[rid]
			standing = format("%s|cff808080%.0f%%|r", rk and ("|cffffd100#" .. rk.rank .. "|r ") or "", pct)
		elseif not eqLink then
			nSlots = nSlots + 1
			standing = "|cffff6060empty|r"
		else
			standing = "|cff808080-|r"
		end
		-- unenchanted flag (enchant id is the 2nd number in the item link)
		local ench = ""
		if eqLink and ENCHANTABLE_INV[iv] then
			local eid = strmatch(eqLink, "item:%d+:(%d+)")
			if not eid or eid == "0" then ench = " |cffff8000\226\154\160|r" end
		end
		shown = shown + 1
		local row = GearRow(f, shown)
		row.itemId = rowItem
		row.c1:SetText("|cffd6d6d6" .. label .. "|r")
		row.c2:SetText(swap .. "   " .. standing .. ench)
		row:Show()
	end
	local overall = nSlots > 0 and (sumPct / nSlots) or 0
	f.header:SetText(format("|cffffd100%s|r  -  you're at |cff69ccf0%.0f%%|r of BiS",
		(strmatch(specKey, "|(.+)$") or specKey), overall))
	-- farm next: biggest upgrade you don't own yet, per slot
	local farm, seen = {}, {}
	for _, bslot in ipairs(FARM_SLOTS) do
		if not seen[bslot] then
			seen[bslot] = true
			local list = activeSlotRanks[bslot]
			if list then
				local base = BaselineForSlot(bslot) or 0
				for i = 1, #list do
					local id, sc = list[i][1], list[i][2]
					if not owned[id] then
						if base > 0 then
							if sc > base then
								farm[#farm + 1] = { slot = bslot, id = id, pct = (sc - base) / base * 100 }
							end
						else
							-- nothing worthwhile equipped here: the top item is a fresh grab
							farm[#farm + 1] = { slot = bslot, id = id, isNew = true, pct = 1e9 }
						end
						break
					end
				end
			end
		end
	end
	table.sort(farm, function(a, b) return a.pct > b.pct end)
	if farm[1] then
		shown = shown + 1
		local hdr = GearRow(f, shown)
		hdr.itemId = nil
		hdr.c1:SetText("")
		hdr.c2:SetText("|cffffd100Farm next|r  |cff707070(biggest upgrades you don't own)|r")
		hdr:Show()
		for i = 1, math.min(6, #farm) do
			local e = farm[i]
			local info = D.items[e.id]
			shown = shown + 1
			local fr = GearRow(f, shown)
			fr.itemId = e.id
			fr.c1:SetText("|cffd6d6d6" .. e.slot .. "|r")
			fr.c2:SetText(format("%s  |cff707070%s|r  %s",
				Clip(info and info[1] or ("item " .. e.id), 20), Clip(info and info[3] or "?", 20),
				e.isNew and "|cff20ff20new|r" or format("|cff20ff20+%.0f%%|r", e.pct)))
			fr:Show()
		end
	end
	f.footer:SetText("|cff20ff20\226\134\145|r best in your bags   \226\154\160 = unenchanted (see /bb enchants)   \194\183   shift-click to link")
	f:SetHeight(100 + math.max(1, shown) * 16 + 26)
end

local function CreateGearPanel()
	if gearPanel then
		return gearPanel
	end
	local f = CreateFrame("Frame", "BisBuddyGearFrame", UIParent)
	f:SetWidth(474)
	f:SetHeight(400)
	f:SetPoint("CENTER")
	f:SetFrameStrata("DIALOG")
	StyleDialog(f)
	f:SetMovable(true)
	f:EnableMouse(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing(); SavePanelPos(self) end)
	tinsert(UISpecialFrames, "BisBuddyGearFrame")
	f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	f.title:SetPoint("TOPLEFT", 16, -14)
	f.title:SetText("My Gear")
	local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", -6, -6)
	f.header = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	f.header:SetPoint("TOPLEFT", 18, -44)
	f.header:SetJustifyH("LEFT")
	f.footer = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	f.footer:SetPoint("BOTTOMLEFT", 16, 14)
	f.footer:SetPoint("BOTTOMRIGHT", -14, 14)
	f.footer:SetJustifyH("LEFT")
	f.rows = {}
	f:Hide()
	gearPanel = f
	return f
end

ToggleGearPanel = function()
	RefreshSpec(true)
	local f = CreateGearPanel()
	if f:IsShown() then
		f:Hide()
	else
		PlacePanel(f, true)
		f:Show()
		RenderGear()
	end
end

--------------------------------------------------------------------------------
-- Loadout (/bb loadout): paper-doll home screen. Two slot columns + a center
-- panel; each cell = the BiS target vs your equipped item, colour-coded by
-- have/need status. Reuses the gear engine (GEAR_SLOTS / ScanBags /
-- activeSlotRanks / rankIndex / ScoreLink). Additive + isolated (does not touch
-- the tooltip / BiS-Lists / gear paths). Everything hangs off one local table
-- so we add just 1 file-level local (near the 200-local chunk ceiling).
--------------------------------------------------------------------------------
BisBuddyLO = { panel = nil }   -- global (not local) to stay under the 200-local chunk ceiling
BisBuddyLO.COL = {
	equipped = { 0.21, 0.79, 0.29 }, bags = { 0.88, 0.64, 0.13 },
	close = { 0.91, 0.45, 0.17 }, upgrade = { 0.78, 0.27, 0.24 },
	setlock = { 0.55, 0.42, 0.15 }, none = { 0.50, 0.50, 0.53 },
}
BisBuddyLO.LEFT  = { 1, 2, 3, 4, 5, 6, 15, 16 }        -- GEAR_SLOTS idx: Head..Wrist, MainHand, OffHand
BisBuddyLO.RIGHT = { 7, 8, 9, 10, 11, 12, 13, 14, 17 } -- Hands..Trinket2, Ranged

-- pure have/need classifier (status key from the facts)
function BisBuddyLO.Classify(eqId, targetId, ownExact, ownAny, eqRank, setLocked)
	if setLocked then return "setlock" end
	if not targetId then return "none" end   -- no BiS data for this slot: don't claim "equipped BiS"
	if eqId == targetId then return "equipped" end
	if ownExact then return "bags" end
	if ownAny or (eqRank and eqRank <= 5) then return "close" end
	return "upgrade"
end

-- BiS target {id, score} for a gear slot, unioning weapon / off-hand variants
-- (caster off-hands are "Held In Off-hand"/"Shield", not the "Off Hand" weapon key).
-- excludeName = a name already shown for this slot in an earlier cell (Ring 2 / Trinket 2 skip
-- a same-name / lower-difficulty copy of slot 1, since those items are unique-equipped).
-- Weapons decide 1H+off-hand vs 2H as a unit: if the best 2H beats best-1H + best-off-hand,
-- the 2H fills Main Hand and Off Hand is flagged "covered by your 2-hander" (3rd return).
function BisBuddyLO.TargetFor(bslot, excludeName)
	local ar = activeSlotRanks
	local function nth(s, k) local l = ar[s]; local e = l and l[k]; if e then return e[1], e[2] else return nil, 0 end end
	if bslot == "Main Hand" or bslot == "Off Hand" then
		local mhId, mhSc = nth("Main Hand", 1)
		local a, b = nth("One-Hand", 1); if b > mhSc then mhId, mhSc = a, b end
		local ohId, ohSc = nth("Off Hand", 1)
		a, b = nth("Held In Off-hand", 1); if b > ohSc then ohId, ohSc = a, b end
		a, b = nth("Shield", 1); if b > ohSc then ohId, ohSc = a, b end
		local thId, thSc = nth("Two-Hand", 1)
		if thSc > (mhSc + ohSc) then
			if bslot == "Main Hand" then return thId, thSc else return nil, 0, true end
		else
			if bslot == "Main Hand" then return mhId, mhSc else return ohId, ohSc end
		end
	end
	local l = ar[bslot]
	if l then
		for _, e in ipairs(l) do
			local it = D.items[e[1]]
			if not excludeName or not it or it[1] ~= excludeName then return e[1], e[2] end
		end
	end
	return nil, 0
end

-- All ranked items to list for a display slot, unioning weapon / off-hand variants
-- (the Off Hand cell must list shields + held-in-off-hand, which live under other slot keys).
function BisBuddyLO.MergedRanks(bslot)
	local cands
	if bslot == "Main Hand" then cands = { "Main Hand", "One-Hand", "Two-Hand" }
	elseif bslot == "Off Hand" then cands = { "Off Hand", "One-Hand", "Held In Off-hand", "Shield" }
	else return activeSlotRanks[bslot] end
	local merged = {}
	for _, s in ipairs(cands) do
		local l = activeSlotRanks[s]
		if l then for k = 1, #l do merged[#merged + 1] = l[k] end end
	end
	table.sort(merged, function(a, b) return a[2] > b[2] end)
	return merged
end

-- The difficulty / keystone tier off an item's tooltip (line 2 reads e.g. "Mythic 4").
-- bisbeard only itemizes M+10, so equipped M+4/M+6 etc. aren't in D.items - read it live.
-- Cached per item id (tier never changes for a given id).
BisBuddyLO.tierCache = {}
function BisBuddyLO.TierOf(link)
	local id = link and ItemIdFromLink(link)
	if not id then return nil end
	local c = BisBuddyLO.tierCache[id]
	if c ~= nil then return c or nil end
	scanTip:SetOwner(UIParent, "ANCHOR_NONE"); scanTip:ClearLines(); scanTip:SetHyperlink(link)
	local tier
	for i = 2, math.min(6, scanTip:NumLines()) do
		local fs = _G["BisBuddyScanTooltipTextLeft" .. i]
		local t = fs and fs:GetText()
		if t then
			local m = strmatch(t, "^Mythic%s+(%d+)")
			if m then tier = "M+" .. m; break end
			if t == "Heroic" or t == "Normal" or t == "Mythic"
				or strmatch(t, "^Ascended") or strmatch(t, "^Bloodforged") or strmatch(t, "^Worldforged") then
				tier = t; break
			end
		end
	end
	scanTip:Hide()
	BisBuddyLO.tierCache[id] = tier or false
	return tier
end

-- Unambiguous version label. Raid drops get their raid ("Mythic MC"); worldforged gear gets
-- "WF <tier>" so a worldforge "Onyxia" no longer reads like an Onyxia raid drop. Others unchanged.
BisBuddyLO.RAID_ABBREV = {
	["Molten Core"] = "MC", ["Blackwing Lair"] = "BWL", ["Naxxramas"] = "Naxx",
	["Onyxia"] = "Ony", ["Onyxia's Lair"] = "Ony",
	["Temple of Ahn'Qiraj"] = "AQ40", ["AQ40"] = "AQ40", ["AQ20"] = "AQ20",
	["Zul'Gurub"] = "ZG", ["ZG Set"] = "ZG", ["ZG Sets"] = "ZG", ["Zul'Gurub Sets"] = "ZG",
	["Tier 1"] = "MC", ["Tier 2"] = "BWL", ["Tier 2.5"] = "AQ40", ["Tier 3"] = "Naxx",
}
BisBuddyLO.FORGE_ABBREV = {
	["Pre-Raid"] = "PR", ["Ragnaros"] = "MC", ["Onyxia"] = "Ony", ["Nefarion"] = "BWL",
	["Nefarian"] = "BWL", ["Hakkar"] = "ZG", ["C'thun"] = "AQ40", ["Kel'Thuzad"] = "Naxx",
}
function BisBuddyLO.RichVer(info)
	if not info then return "" end
	local ver, cat, src = info[2] or "", info[8] or "", info[3] or ""
	if ver == "" then return "" end
	if cat == "worldforged" then
		return "WF " .. (BisBuddyLO.FORGE_ABBREV[ver] or ver)
	elseif cat == "raid" then
		local raid = src:match("^(.-)%s*%-") or src
		local ab = BisBuddyLO.RAID_ABBREV[raid] or BisBuddyLO.RAID_ABBREV[ver]
		return ab and (ver .. " " .. ab) or (ver .. " Raid")
	end
	return ver
end

function BisBuddyLO.Cell(col, idx)
	col.cells = col.cells or {}
	if col.cells[idx] then return col.cells[idx] end
	local c = CreateFrame("Button", nil, col)
	c:SetWidth(296); c:SetHeight(40)
	c:SetPoint("TOPLEFT", 0, -(idx - 1) * 44)
	c.bar = c:CreateTexture(nil, "ARTWORK"); c.bar:SetPoint("TOPLEFT", 0, 0); c.bar:SetPoint("BOTTOMLEFT", 0, 0); c.bar:SetWidth(3)
	c.icon = c:CreateTexture(nil, "ARTWORK"); c.icon:SetPoint("LEFT", 8, 0); c.icon:SetWidth(30); c.icon:SetHeight(30); c.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
	c.nmFS = c:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"); c.nmFS:SetPoint("TOPLEFT", 44, -3); c.nmFS:SetPoint("RIGHT", -2, 0); c.nmFS:SetJustifyH("LEFT")
	c.stat = c:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall"); c.stat:SetPoint("TOPLEFT", 44, -19); c.stat:SetPoint("RIGHT", -2, 0); c.stat:SetJustifyH("LEFT")
	local hl = c:CreateTexture(nil, "HIGHLIGHT"); hl:SetAllPoints(); hl:SetTexture(1, 1, 1, 0.06)
	c:SetScript("OnEnter", function(self) if self.itemId then GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:SetHyperlink("item:" .. self.itemId); GameTooltip:Show() end end)
	c:SetScript("OnLeave", function() GameTooltip:Hide() end)
	c:SetScript("OnClick", function(self)
		if IsControlKeyDown() and self.itemId then
			local link = select(2, GetItemInfo(self.itemId))
			if link and DressUpItemLink then DressUpItemLink(link) end
			return
		end
		if not self.bslot then return end
		if BisBuddyLO.sel == self.bslot then BisBuddyLO.HideList() else BisBuddyLO.ShowList(self.bslot, self.iv) end
	end)
	col.cells[idx] = c
	return c
end

function BisBuddyLO.RenderCol(col, idxList, bagIds, bagByName)
	if col.cells then for _, c in ipairs(col.cells) do c:Hide() end end
	local usedName, sumEq, sumBis = {}, 0, 0
	for pos, gi in ipairs(idxList) do
		local gs = GEAR_SLOTS[gi]
		local iv, label, bslot = gs[1], gs[2], gs[3]
		local tid, tscore, used2H = BisBuddyLO.TargetFor(bslot, usedName[bslot])   -- Ring 2 / Trinket 2 skip slot-1's item
		local manual = db and db.loTargets and db.loTargets[iv]
		if manual and D.items[manual] then                                        -- user pinned a goal for this slot
			tid, used2H = manual, nil
			tscore = (rankIndex[manual] and rankIndex[manual].score) or tscore
		end
		local eqLink = GetInventoryItemLink("player", iv)
		local eqId = eqLink and ItemIdFromLink(eqLink)
		local eqScore = eqLink and ScoreLink(eqLink) or nil
		local eqRank = eqId and rankIndex[eqId] and rankIndex[eqId].rank
		local tname = tid and D.items[tid] and D.items[tid][1]
		if tname then usedName[bslot] = tname end
		local ownExact = (tid and bagIds[tid] and eqId ~= tid) or false   -- BiS itself sitting in bags
		local alt = tname and bagByName[tname]                             -- a same-name (diff-difficulty) copy in bags
		local ownAny = (alt and alt.id ~= tid and alt.id ~= eqId) or false
		local status = used2H and "none" or BisBuddyLO.Classify(eqId, tid, ownExact, ownAny, eqRank, false)
		local cell = BisBuddyLO.Cell(col, pos)
		cell.itemId = tid or eqId
		cell.bslot, cell.iv = bslot, iv
		local rc = BisBuddyLO.COL[status]
		cell.bar:SetTexture(rc[1], rc[2], rc[3])
		if tid then
			cell.icon:SetTexture(select(10, GetItemInfo(tid)) or "Interface\\Icons\\INV_Misc_QuestionMark")
			local goal = (manual and tid == manual) and "|cffffd100\226\152\133|r " or ""   -- your pinned goal
			cell.nmFS:SetText(goal .. "|cffa335ee" .. Clip(tname or ("item " .. tid), 38) .. "|r")
		else
			cell.icon:SetTexture((eqLink and select(10, GetItemInfo(eqLink))) or "Interface\\PaperDoll\\UI-Backpack-EmptySlot")
			cell.nmFS:SetText("|cffb0b0b0" .. label .. "|r")
		end
		local delta = math.floor((tscore - (eqScore or 0)) + 0.5)
		local en = (eqId and D.items[eqId] and D.items[eqId][1]) or (eqLink and GetItemInfo(eqLink)) or "your item"
		local tier = eqLink and BisBuddyLO.TierOf(eqLink)
		local tstr = tier and (" |cff888888(" .. tier .. ")|r") or ""
		local line
		if used2H then
			line = "|cff808080covered by your 2-handed BiS|r"
		elseif status == "none" then
			line = eqLink and ("|cff808080Current " .. Clip(en, 20) .. (tier and (" (" .. tier .. ")") or "") .. " (no BiS data)|r") or ("|cff808080" .. label .. " \226\128\148 no BiS data|r")
		elseif status == "equipped" then
			line = "|cff35c94a\226\156\147 equipped (BiS)|r"
		elseif status == "bags" then
			line = "|cffe0a422BiS is in your bags \226\128\148 equip it|r"
		elseif eqLink then
			local hex = (status == "close") and "e8722c" or "c8443c"
			line = format("|cff%sCurrent %s|r%s |cff%sUpgrade +%d|r", hex, Clip(en, 20), tstr, hex, delta)
		elseif ownAny then
			line = format("|cffe8722chave the %s in bags. Upgrade +%d|r", (alt.ver ~= "" and alt.ver) or "another", delta)
		else
			line = format("|cffc8443c%s empty. Upgrade +%d|r", label, delta)
		end
		cell.stat:SetText(line)
		cell:Show()
		sumEq = sumEq + (eqScore or 0); sumBis = sumBis + tscore
	end
	return sumEq, sumBis
end

-- Center item list (click a slot -> its ranked items). Mirrors the Browse panel's
-- name-grouping (best variant per item), compacted to fit the loadout's middle column.
function BisBuddyLO.ListRow(i)
	local f = BisBuddyLO.panel
	f.listRows = f.listRows or {}
	if f.listRows[i] then return f.listRows[i] end
	local r = CreateFrame("Button", nil, f.list)
	r:SetHeight(16); r:SetPoint("TOPLEFT", 2, -24 - (i - 1) * 17); r:SetPoint("RIGHT", f.list, "RIGHT", -2, 0)
	local hl = r:CreateTexture(nil, "HIGHLIGHT"); hl:SetAllPoints(); hl:SetTexture(1, 1, 1, 0.10)
	r.text = r:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"); r.text:SetPoint("LEFT", 2, 0); r.text:SetJustifyH("LEFT")
	r:SetScript("OnEnter", function(self) if self.itemId then GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:SetHyperlink("item:" .. self.itemId); GameTooltip:Show() end end)
	r:SetScript("OnLeave", function() GameTooltip:Hide() end)
	r:SetScript("OnClick", function(self)
		if not self.itemId then return end
		if IsControlKeyDown() then
			local link = select(2, GetItemInfo(self.itemId))
			if link and DressUpItemLink then DressUpItemLink(link) end
			return
		end
		if IsShiftKeyDown() then
			local link = select(2, GetItemInfo(self.itemId))
			if link and ChatEdit_InsertLink then ChatEdit_InsertLink(link) end
			return
		end
		local iv = BisBuddyLO.selIv
		if not (iv and db) then return end
		db.loTargets = db.loTargets or {}
		if db.loTargets[iv] == self.itemId then db.loTargets[iv] = nil else db.loTargets[iv] = self.itemId end  -- toggle goal
		BisBuddyLO.Render()                                                            -- repaints cells + re-shows the list
		if RenderSR then RenderSR() end                                               -- keep an open Reserve Planner in sync
	end)
	f.listRows[i] = r
	return r
end

function BisBuddyLO.HideList()
	BisBuddyLO.sel, BisBuddyLO.selIv = nil, nil
	local f = BisBuddyLO.panel
	if f then if f.list then f.list:Hide() end; if f.center then f.center:Show() end end
end

function BisBuddyLO.ShowList(bslot, iv)
	local f = BisBuddyLO.panel
	if not (f and f.list) then return end
	BisBuddyLO.sel, BisBuddyLO.selIv = bslot, iv
	if f.center then f.center:Hide() end
	f.list:Show()
	local eqLink = iv and GetInventoryItemLink("player", iv)
	local eqName = eqLink and GetItemInfo(eqLink)
	local eqScore = eqLink and ScoreLink(eqLink)
	local eqTier = eqLink and BisBuddyLO.TierOf(eqLink)
	local now = ""
	if eqName then
		now = format("  |cff808080now:|r %s%s  |cff69ccf0%d|r", Clip(eqName, 16),
			eqTier and (" |cff888888" .. eqTier .. "|r") or "", math.floor((eqScore or 0) + 0.5))
	end
	f.listTitle:SetText(format("|cffffd100%s|r%s", (BROWSE_SLOT_LABEL[bslot] or bslot), now))
	local list = BisBuddyLO.MergedRanks(bslot)
	local base = BaselineForSlot(bslot)
	local seenName, order = {}, {}                          -- best variant per item name (score-sorted list)
	if list then
		for i = 1, #list do
			local id = list[i][1]
			local info = D.items[id]
			local nm = (info and info[1]) or ("item " .. id)
			if not seenName[nm] and #order < 14 then
				seenName[nm] = true
				order[#order + 1] = { id = id, name = nm, score = list[i][2], info = info }
			end
		end
	end
	local tgt = db and db.loTargets and db.loTargets[iv]
	if f.listRows then for _, r in ipairs(f.listRows) do r:Hide() end end
	for i = 1, #order do
		local g = order[i]
		local r = BisBuddyLO.ListRow(i)
		r.itemId = g.id
		local up = (base and g.score > base) and "|cff20ff20^|r " or "   "
		local mark = (tgt == g.id) and "|cffffd100\226\152\133|r " or format("|cff999999%2d|r ", i)
		local rv = BisBuddyLO.RichVer(g.info)
		local ver = (rv ~= "") and (" |cff888888" .. rv .. "|r") or ""
		r.text:SetText(format("%s%s%s%s|r%s  |cff69ccf0%.0f|r", up, mark, ItemHex(g.id), Clip(g.name, 20), ver, g.score))
		r:Show()
	end
	if f.listHint then f.listHint:SetText("|cff707070click = set goal (\226\152\133)  \194\183  ctrl = preview  \194\183  shift = link|r") end
	if #order == 0 then f.listTitle:SetText((f.listTitle:GetText() or "") .. "  |cff808080(no items)|r") end
end

function BisBuddyLO.Render()
	local f = BisBuddyLO.panel
	if not f or not f:IsShown() then return end
	if not specKey then
		f.header:SetText("|cffff2020No spec set|r - open BisBuddy (/bb) and pick your spec.")
		return
	end
	wipe(equippedScoreCache)
	local bagIds, bagByName = {}, {}
	for bag = 0, 4 do
		for s = 1, (GetContainerNumSlots(bag) or 0) do
			local link = GetContainerItemLink(bag, s)
			local id = link and ItemIdFromLink(link)
			if id then
				bagIds[id] = true
				local it = D.items[id]
				if it and not bagByName[it[1]] then bagByName[it[1]] = { id = id, ver = it[2] } end
			end
		end
	end
	local e1, b1 = BisBuddyLO.RenderCol(f.leftCol, BisBuddyLO.LEFT, bagIds, bagByName)
	local e2, b2 = BisBuddyLO.RenderCol(f.rightCol, BisBuddyLO.RIGHT, bagIds, bagByName)
	f.header:SetText(format("|cffffd100%s|r  \226\128\148  Current |cff35c94a%d|r  /  BiS |cffffd100%d|r",
		(strmatch(specKey, "|(.+)$") or specKey), math.floor(e1 + e2 + 0.5), math.floor(b1 + b2 + 0.5)))
	if BisBuddyLO.sel then BisBuddyLO.ShowList(BisBuddyLO.sel, BisBuddyLO.selIv) end   -- keep the open slot list fresh
end

function BisBuddyLO.Create()
	if BisBuddyLO.panel then return BisBuddyLO.panel end
	local f = CreateFrame("Frame", "BisBuddyLoadoutFrame", UIParent)
	f:SetWidth(920); f:SetHeight(470); f:SetPoint("CENTER"); f:SetFrameStrata("DIALOG")
	StyleDialog(f)
	f:SetMovable(true); f:EnableMouse(true); f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing(); SavePanelPos(self) end)
	tinsert(UISpecialFrames, "BisBuddyLoadoutFrame")
	f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	f.title:SetPoint("TOPLEFT", 16, -14); f.title:SetText("Loadout")
	local close = CreateFrame("Button", nil, f, "UIPanelCloseButton"); close:SetPoint("TOPRIGHT", -6, -6)
	f.header = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	f.header:SetPoint("TOPLEFT", 18, -40); f.header:SetJustifyH("LEFT")
	f.leftCol = CreateFrame("Frame", nil, f); f.leftCol:SetPoint("TOPLEFT", 14, -64); f.leftCol:SetWidth(300); f.leftCol:SetHeight(390)
	f.rightCol = CreateFrame("Frame", nil, f); f.rightCol:SetPoint("TOPRIGHT", -14, -64); f.rightCol:SetWidth(300); f.rightCol:SetHeight(390)
	f.center = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	f.center:SetPoint("TOP", 0, -150); f.center:SetWidth(260); f.center:SetJustifyH("CENTER")
	f.center:SetText("|cff808080Set Bonuses\n(coming)\n\nclick any slot\nfor its item list|r")
	f.list = CreateFrame("Frame", nil, f); f.list:SetPoint("TOP", 0, -58); f.list:SetWidth(288); f.list:SetHeight(400); f.list:Hide()
	f.listTitle = f.list:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	f.listTitle:SetPoint("TOPLEFT", 4, -2); f.listTitle:SetPoint("RIGHT", -4, 0); f.listTitle:SetJustifyH("LEFT")
	f.listHint = f.list:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	f.listHint:SetPoint("BOTTOMLEFT", 4, 8); f.listHint:SetJustifyH("LEFT")
	f:Hide()
	BisBuddyLO.panel = f
	return f
end

function BisBuddyLO.Toggle()
	RefreshSpec(true)
	local f = BisBuddyLO.Create()
	if f:IsShown() then f:Hide() else PlacePanel(f, true); f:Show(); BisBuddyLO.Render() end
end

--------------------------------------------------------------------------------
-- Reserve Planner (/bb sr): pick a raid + difficulty and see that raid's drops
-- ranked by YOUR biggest upgrade, so PUG players know what to soft-reserve.
-- Reads the per-spec cells for the chosen tier, filtered by the source's raid.
--------------------------------------------------------------------------------
local SR_RAIDS = {
	"Zul'Gurub", "Molten Core", "Onyxia", "Blackwing Lair", "AQ20", "AQ40", "Naxxramas",
}
-- short slot labels so the list column stays tidy
local SR_SLOT_SHORT = {
	["Held In Off-hand"] = "Off-hand", ["Two-Hand"] = "2H", ["One-Hand"] = "1H",
	["Main Hand"] = "Main-H", ["Off Hand"] = "Off-H", Shoulders = "Shoulder", Wrists = "Wrist",
}

local srPanel

local function SRRow(f, i)
	local r = f.rows[i]
	if r then return r end
	r = CreateFrame("Button", nil, f)
	r:SetHeight(15)
	r:SetPoint("TOPLEFT", 16, -92 - (i - 1) * 16)
	r:SetPoint("RIGHT", f, "RIGHT", -14, 0)
	local hl = r:CreateTexture(nil, "HIGHLIGHT")
	hl:SetAllPoints()
	hl:SetTexture(1, 1, 1, 0.10)
	r.text = r:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	r.text:SetPoint("LEFT", 2, 0)
	r.text:SetJustifyH("LEFT")
	r:SetScript("OnEnter", function(self)
		if not self.itemId then return end
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetHyperlink("item:" .. self.itemId)
		GameTooltip:Show()
	end)
	r:SetScript("OnLeave", function() GameTooltip:Hide() end)
	r:SetScript("OnClick", function(self)
		if not self.itemId then return end
		if IsControlKeyDown() then
			local link = select(2, GetItemInfo(self.itemId))
			if link and DressUpItemLink then DressUpItemLink(link) end
		elseif IsShiftKeyDown() then
			local link = select(2, GetItemInfo(self.itemId))
			if link and ChatEdit_InsertLink then ChatEdit_InsertLink(link) end
		end
	end)
	f.rows[i] = r
	return r
end

RenderSR = function()
	local f = srPanel
	if not f or not f:IsShown() then
		return
	end
	wipe(equippedScoreCache)
	for _, r in ipairs(f.rows) do r:Hide() end
	local sr = db.sr or {}
	local raid, tier, count = sr.raid, sr.tier or db.raidDiff or 3, sr.count or 2
	f.raidDD:SetText(raid or "pick a raid")
	f.diffDD:SetText(DiffLabel(tier))
	if not f.countEB:HasFocus() then f.countEB:SetText(tostring(count)) end
	f.sortBtn:SetText(sr.sortBy == "score" and "by best item" or "by upgrade")
	if not specKey or not D.cells[specKey] then
		f.header:SetText("|cffff2020No spec set|r - open BisBuddy (/bb) and pick your spec first.")
		f.footer:SetText("")
		f:SetHeight(160)
		return
	end
	f.header:SetText(format("|cffffd100%s|r  -  reserve your top |cffffd100%d|r from |cffffd100%s|r (%s)",
		(strmatch(specKey, "|(.+)$") or specKey), count, raid or "?", DiffLabel(tier)))
	-- gather this raid's items at the chosen tier, scored for the spec
	local cells = D.cells[specKey]
	local isCustom = IsSpecCustom()
	local w = specWeights or ComputeEffectiveWeights()
	local items, seen = {}, {}
	if raid and w then
		for _, pc in pairs(cells) do
			local tc = pc[tier]
			if tc then
				for slot, list in pairs(tc) do
					for i = 1, #list do
						local id = list[i][1]
						local info = D.items[id]
						if info and not seen[id] and not IsExcludedItem(id) then
							local src = info[3] or ""
							if src:sub(1, #raid) == raid then
								seen[id] = true
								local sc = isCustom and CustomScore(id, slot, w) or list[i][2]
								local base = BaselineForSlot(slot) or 0
								local pct = base > 0 and ((sc - base) / base * 100) or nil
								items[#items + 1] = { id = id, slot = slot, score = sc, pct = pct, src = src }
							end
						end
					end
				end
			end
		end
	end
	local pinned = {}
	for _, pid in pairs(db.loTargets or {}) do pinned[pid] = true end   -- Loadout goals -> always reserved
	local anyPin = false
	table.sort(items, function(a, b)
		local pa, pb = pinned[a.id] or false, pinned[b.id] or false
		if pa ~= pb then return pa end                                  -- pinned goals sort to the top
		if sr.sortBy == "score" then return a.score > b.score end
		return (a.pct or 1e9) > (b.pct or 1e9) -- empty-slot upgrades (nil) sort to the top
	end)
	local shown, autoStar = 0, 0
	for i = 1, math.min(30, #items) do
		local e = items[i]
		local info = D.items[e.id]
		shown = shown + 1
		local row = SRRow(f, shown)
		row.itemId = e.id
		local isPin = pinned[e.id]
		local reserved = isPin
		if not isPin and autoStar < count then reserved = true; autoStar = autoStar + 1 end
		if isPin then anyPin = true end
		local star = reserved and "|cffffd100\226\152\133|r " or "    "
		local pinMark = isPin and "|cffffd100\226\151\134|r" or ""     -- diamond = pinned in Loadout
		local boss = e.src:match("%-%s*(.+)$") or e.src
		local val = (sr.sortBy == "score") and format("|cff69ccf0%.0f|r", e.score)
			or (e.pct and format("|cff20ff20+%.0f%%|r", e.pct) or "|cff20ff20new|r")
		row.text:SetText(format("%s%s|cffd6d6d6%-8s|r %s  |cff707070%s|r  %s",
			star, pinMark, SR_SLOT_SHORT[e.slot] or e.slot, Clip(info and info[1] or "?", 20), Clip(boss, 16), val))
		row:Show()
	end
	if shown == 0 then
		f.footer:SetText(raid and "|cff808080no gear for your spec from this raid at that difficulty.|r"
			or "|cff808080pick a raid from the dropdown above.|r")
	elseif anyPin then
		f.footer:SetText(format("|cffffd100\226\152\133|r reserve (top %d + |cffffd100\226\151\134|r Loadout pins)   \194\183   shift-click to link", count))
	else
		f.footer:SetText(format("|cffffd100\226\152\133|r = reserve these (your top %d)   \194\183   shift-click a row to link", count))
	end
	f:SetHeight(120 + math.max(1, shown) * 16 + 22)
end

local function CreateSRPanel()
	if srPanel then
		return srPanel
	end
	local f = CreateFrame("Frame", "BisBuddySRFrame", UIParent)
	f:SetWidth(500)
	f:SetHeight(400)
	f:SetPoint("CENTER")
	f:SetFrameStrata("DIALOG")
	StyleDialog(f)
	f:SetMovable(true)
	f:EnableMouse(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing(); SavePanelPos(self) end)
	tinsert(UISpecialFrames, "BisBuddySRFrame")
	f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	f.title:SetPoint("TOPLEFT", 16, -14)
	f.title:SetText("Reserve Planner")
	local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", -6, -6)

	f.raidDD = MakeDropdown(f, "BisBuddySRRaidDD", 116)
	f.raidDD:SetPoint("TOPLEFT", 0, -40)
	f.raidDD:SetBuilder(function(add)
		for _, r in ipairs(SR_RAIDS) do
			local raid = r
			add(raid, function() db.sr = db.sr or {}; db.sr.raid = raid; RenderSR() end, db.sr and db.sr.raid == raid)
		end
	end)

	f.diffDD = MakeDropdown(f, "BisBuddySRDiffDD", 80)
	f.diffDD:SetPoint("TOPLEFT", 172, -40)
	f.diffDD:SetBuilder(function(add)
		for d = 1, 4 do   -- raid difficulties (the Reserve Planner is raid-focused)
			local n = d
			add(DiffLabel(n), function() db.sr = db.sr or {}; db.sr.tier = n; RenderSR() end, db.sr and (db.sr.tier or db.raidDiff) == n)
		end
	end)

	local srLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	srLabel:SetPoint("LEFT", f.diffDD, "RIGHT", 6, 2)
	srLabel:SetText("SRs")
	f.countEB = CreateFrame("EditBox", "BisBuddySRCount", f, "InputBoxTemplate")
	f.countEB:SetWidth(26)
	f.countEB:SetHeight(18)
	f.countEB:SetPoint("LEFT", srLabel, "RIGHT", 8, 0)
	f.countEB:SetAutoFocus(false)
	f.countEB:SetNumeric(true)
	f.countEB:SetScript("OnEnterPressed", function(self)
		db.sr = db.sr or {}
		db.sr.count = math.max(1, math.min(10, tonumber(self:GetText()) or 2))
		self:ClearFocus()
		RenderSR()
	end)
	f.countEB:SetScript("OnEscapePressed", function(self) self:ClearFocus(); RenderSR() end)

	f.sortBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	f.sortBtn:SetWidth(104)
	f.sortBtn:SetHeight(20)
	f.sortBtn:SetPoint("TOPRIGHT", close, "BOTTOMLEFT", -2, -2)
	f.sortBtn:SetScript("OnClick", function()
		db.sr = db.sr or {}
		db.sr.sortBy = (db.sr.sortBy == "score") and "upgrade" or "score"
		RenderSR()
	end)

	f.header = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	f.header:SetPoint("TOPLEFT", 18, -70)
	f.header:SetJustifyH("LEFT")
	f.footer = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	f.footer:SetPoint("BOTTOMLEFT", 16, 14)
	f.footer:SetPoint("BOTTOMRIGHT", -14, 14)
	f.footer:SetJustifyH("LEFT")
	f.rows = {}
	f:Hide()
	srPanel = f
	return f
end

ToggleSRPanel = function()
	RefreshSpec(true)
	local f = CreateSRPanel()
	if f:IsShown() then
		f:Hide()
	else
		PlacePanel(f, true)
		f:Show()
		RenderSR()
	end
end

-- Read the item under the cursor's tooltip into a curated-extra table. Returns
-- table {id,name,slot,stats} or nil,errorMessage.
local function CaptureHoveredExtra()
	local name, link = GameTooltip:GetItem()
	if not link then
		return nil, "hover an item first, then type |cffffd100/bb extra|r (it reads the item under your cursor)."
	end
	local id = ItemIdFromLink(link)
	if not id then
		return nil, "couldn't read that item's id."
	end
	local _, _, _, _, _, _, _, _, equipLoc = GetItemInfo(link)
	local slot = equipLoc and EQUIPLOC_TO_SLOT[equipLoc]
	if not slot then
		return nil, "that item has no gear slot BisBuddy tracks."
	end
	wipe(statScratch)
	pcall(GetItemStats, link, statScratch)
	local stats = {}
	for key, val in pairs(statScratch) do
		local bisKey = STAT_KEY_MAP[key]
		if not bisKey then
			local label = _G[key]
			bisKey = type(label) == "string" and LABEL_TO_BIS_KEY[label] or nil
		end
		local code = bisKey and KEY_TO_STAT_CODE[bisKey]
		if code and type(val) == "number" and val ~= 0 then
			stats[code] = val
		end
	end
	if MELEE_SLOT[slot] or slot == "Ranged" then
		local dps = WeaponDps(link, id)
		if dps then stats.dps = dps end
	end
	return { id = id, name = name, slot = slot, stats = stats }
end

-- Format a captured extra as a ready-to-paste Extras.lua line.
local function ExtraToLine(e)
	local parts = {}
	for code, val in pairs(e.stats) do
		local vs = (val == math.floor(val)) and tostring(val) or format("%.1f", val)
		parts[#parts + 1] = format("%s = %s", code, vs)
	end
	table.sort(parts)
	return format("[%d] = { name = %q, slot = %q, stats = { %s } },",
		e.id, e.name or "?", e.slot, table.concat(parts, ", "))
end

SLASH_BISBUDDY1 = "/bb"
SLASH_BISBUDDY2 = "/bisbuddy"
SlashCmdList["BISBUDDY"] = function(msg)
	if not db then
		return
	end
	local cmd, rest = strmatch(msg or "", "^%s*(%S*)%s*(.-)%s*$")
	cmd = strlower(cmd or "")
	if cmd == "top" then
		CmdTop(rest)
	elseif cmd == "phase" then
		local p = ResolvePhase(rest)
		if not p then
			Print("current phase: |cffffd100" .. db.phase .. " " .. PhaseLabel(db.phase) .. "|r")
			local parts = {}
			for i = 1, (D.maxPhase or 5) do
				parts[#parts + 1] = format("%d=%s", i, PhaseLabel(i))
			end
			Print("set with /bb phase <n|name>: " .. table.concat(parts, ", "))
		else
			SetPhase(p)
		end
	elseif cmd == "diff" or cmd == "difficulty" then
		local sub, val = strmatch(strlower(rest or ""), "^(%S*)%s*(.*)$")
		local rd = ResolveDiff(val)
		if sub == "raid" and rd then
			SetDiff("raid", rd)
		elseif (sub == "m+" or sub == "mplus" or sub == "dungeon" or sub == "dung") and rd then
			SetDiff("mplus", rd)
		else
			Print(format("difficulty - raid: |cffffd100%s|r, M+/dungeon: |cffffd100%s|r",
				DiffLabel(db.raidDiff), DiffLabel(db.mplusDiff)))
			Print("set with |cffffd100/bb diff raid <normal|heroic|mythic|ascended>|r  or  |cffffd100/bb diff m+ <normal|heroic|mythic|m10>|r")
		end
	elseif cmd == "talents" or cmd == "talent" then
		local a = strlower(rest or "")
		if a == "raid" or a == "dungeon" then
			db.talentSource = a
			Print("talent source: |cffffd100" .. a .. "|r")
			if talentsPanel and talentsPanel:IsShown() then RenderTalents() end
		else
			ToggleTalentsPanel()
		end
	elseif cmd == "list" or cmd == "lists" or cmd == "browse" then
		ToggleBrowsePanel()
	elseif cmd == "enchants" or cmd == "enchant" then
		ToggleEnchantsPanel()
	elseif cmd == "gear" or cmd == "bags" then
		ToggleGearPanel()
	elseif cmd == "loadout" or cmd == "lo" then
		BisBuddyLO.Toggle()
	elseif cmd == "sr" or cmd == "reserve" or cmd == "reserves" then
		ToggleSRPanel()
	elseif cmd == "loot" then
		local r = strlower(strtrim(rest or ""))
		if r == "off" then
			db.lootShare = false
			Print("group loot sharing |cffff2020OFF|r - you won't answer others' loot checks")
		elseif r == "on" then
			db.lootShare = true
			Print("group loot sharing |cff20ff20ON|r")
		else
			StartLootQuery((rest and rest:find("|Hitem:", 1, true)) and rest or lastRollLink)
		end
	elseif cmd == "weights" then
		local r = strlower(strtrim(rest or ""))
		if r == "reset" then
			if specKey then
				db.customWeights[specKey] = nil
				BuildRankIndex()
				wipe(equippedScoreCache)
				RefreshWeightsPanel()
				Print("custom weights reset to bisbeard for " .. tostring(specKey))
			end
		else
			ToggleWeightsPanel()
		end
	elseif cmd == "weight" then
		local stat, valTxt = strmatch(rest or "", "^(%S+)%s+(%S+)$")
		local key = stat and ResolveStatKey(stat)
		if not key then
			Print("usage: /bb weight <stat> <value>  e.g. /bb weight spirit 0.3   (or /bb weights for the panel)")
		elseif not specKey then
			Print("no spec detected - /bb spec <name>")
		elseif ApplyWeightEdit(key, valTxt) then
			RefreshWeightsPanel()
			Print(format("%s weight for %s = |cffffd100%s|r", key, specKey, valTxt))
		else
			Print("invalid value '" .. tostring(valTxt) .. "' - use a number")
		end
	elseif cmd == "import" then
		if strtrim(rest or "") ~= "" then
			DoImport(rest)      -- string passed inline (e.g. from a macro)
		else
			StaticPopup_Show("BISBUDDY_IMPORT")  -- open a paste box (no chat length limit)
		end
	elseif cmd == "export" then
		local s = ExportWeights()
		if not s then
			Print("no spec detected - /bb spec <name>")
		else
			Print("weight string for " .. tostring(specKey) .. ": |cff88ff88" .. s .. "|r")
			StaticPopup_Show("BISBUDDY_EXPORT")
		end
	elseif cmd == "sources" or cmd == "source" then
		ToggleSourcesPanel()
	elseif cmd == "pvp" then
		db.sources = db.sources or {}
		local r = strlower(rest)
		if r == "on" or r == "include" then
			db.sources.pvp = true
		elseif r == "off" or r == "exclude" then
			db.sources.pvp = false
		else
			db.sources.pvp = not db.sources.pvp
		end
		BuildRankIndex()
		wipe(equippedScoreCache)
		Print("PvP items: " .. (db.sources.pvp
			and "|cff20ff20SHOWN|r in rankings" or "|cffff2020HIDDEN|r from rankings"))
	elseif cmd == "crafted" then
		db.sources = db.sources or {}
		local r = strlower(rest)
		if r == "hide" or r == "exclude" or r == "on" then
			db.sources.crafted = false
		elseif r == "show" or r == "include" or r == "off" then
			db.sources.crafted = true
		else
			db.sources.crafted = not db.sources.crafted
		end
		BuildRankIndex()
		wipe(equippedScoreCache)
		Print("Crafted (profession) items: " .. (db.sources.crafted
			and "|cff20ff20SHOWN|r in rankings" or "|cffff2020HIDDEN|r from rankings"))
	elseif cmd == "caps" or cmd == "cap" then
		RefreshSpec(true)
		local caps = specKey and CAP.spec[specKey]
		if not caps or (not caps.hit and not caps.exp and not caps.spen) then
			Print((specKey or "spec") .. ": no hit/expertise cap for this spec (nothing to cap)")
		else
			local ctx = CapContext()
			if ctx and caps.hit then
				local need = ctx.hitRemaining or 0
				Print(format("%s hit: |cffffd100%d|r / %d rating%s", caps.hit, ctx.curHit, ctx.hitCap or 0,
					need > 0 and format("  -  |cffff8800%d to cap|r", need) or "  -  |cff20ff20capped|r"))
			end
			if ctx and caps.exp then
				local need = ctx.expRemaining or 0
				Print(format("expertise: |cffffd100%d|r / %d rating%s", ctx.curExp, ctx.expCap or 0,
					need > 0 and format("  -  |cffff8800%d to cap|r", need) or "  -  |cff20ff20capped|r"))
			end
			if ctx and caps.spen then
				local need = ctx.spenRemaining or 0
				Print(format("spell pen: |cffffd100%d|r / %d rating%s", ctx.curSpen, ctx.spenCap or 0,
					need > 0 and format("  -  |cffff8800%d to cap|r", need) or "  -  |cff20ff20capped|r"))
			end
			Print("|cff888888hit/expertise/spell-pen on gear is valued only up to these gaps in upgrade checks|r")
		end
	elseif cmd == "threshold" and tonumber(rest) then
		db.threshold = math.max(1, math.min(MERGE_DEPTH, tonumber(rest)))
		Print("alerting on top-" .. db.threshold .. " BiS drops")
	elseif cmd == "minup" and tonumber(rest) then
		db.minUpgradePct = tonumber(rest)
		Print("alerting on upgrades >= " .. db.minUpgradePct .. "%")
	elseif cmd == "alerts" then
		db.alerts = not db.alerts
		Print("drop alerts " .. (db.alerts and "|cff20ff20ON|r" or "|cffff2020OFF|r"))
	elseif cmd == "tooltip" then
		db.tooltip = not db.tooltip
		Print("tooltip lines " .. (db.tooltip and "|cff20ff20ON|r" or "|cffff2020OFF|r"))
	elseif cmd == "spec" then
		local ck = CharKey()
		if rest == "" or strlower(rest) == "auto" then
			if ck and db.charSpec then db.charSpec[ck] = nil end
			db.specOverride = nil
			Print("spec set to |cffffd100auto-detect|r for this character")
		else
			local key = MatchSpecName(rest)
			if key then
				db.charSpec = db.charSpec or {}
				if ck then db.charSpec[ck] = key end
				db.specOverride = nil
				Print("spec set to |cffffd100" .. key .. "|r for this character (saved)")
			else
				Print("unknown spec '" .. rest .. "' - use the spec name, e.g. /bb spec Heretic")
				return
			end
		end
		specCheckedAt = 0
		specKey = nil
		RefreshSpec(true)
	elseif cmd == "rescan" then
		wipe(equippedScoreCache)
		specCheckedAt = 0
		specKey = nil
		RefreshSpec(true)
		Print("rescanned gear + spec")
	elseif cmd == "debug" then
		DebugSpec()
	elseif cmd == "lockoh" or cmd == "offhand" then
		local r = strlower(strtrim(rest or ""))
		if r == "off" or r == "clear" or r == "none" then
			db.lockOffHand = nil
			Print("off-hand lock |cffff2020cleared|r - 1H vs 2H comparisons use your best owned off-hand.")
		else
			local id = tonumber(strmatch(rest or "", "item:(%d+)"))
			local name
			if id then
				name = strmatch(rest, "|h%[(.-)%]|h") or (GetItemInfo(id))
			else
				local eq = GetInventoryItemLink("player", 17)   -- fall back to the equipped off-hand
				id = eq and ItemIdFromLink(eq) or nil
				name = eq and (GetItemInfo(eq)) or nil
			end
			if id then
				db.lockOffHand = { id = id, name = name }
				Print(format("off-hand locked to |cffffd100%s|r - all 1H vs 2H comparisons now assume this off-hand. |cff808080/bb lockoh off|r to clear.", name or ("item " .. id)))
			elseif db.lockOffHand then
				Print(format("off-hand locked to |cffffd100%s|r. Shift-click one after |cffffd100/bb lockoh|r to change, or |cffffd100/bb lockoh off|r to clear.", db.lockOffHand.name or ("item " .. db.lockOffHand.id)))
			else
				Print("no off-hand locked (auto = your best owned). Shift-click an off-hand into chat after |cffffd100/bb lockoh|r to pin one, or run it with an off-hand equipped.")
			end
		end
	elseif cmd == "extra" or cmd == "extras" then
		local sub = strlower(strtrim(rest or ""))
		if sub == "clear" then
			db.userExtras = {}
			MergeExtras(); BuildRankIndex()
			Print("cleared your saved extras.")
		elseif sub == "list" then
			local n = 0
			for id, e in pairs(db.userExtras or {}) do
				n = n + 1
				Print(format("  |cffffd100%s|r (%s) - item %d", e.name or "?", e.slot or "?", id))
			end
			if n == 0 then Print("no saved extras. Hover an item bisbeard is missing and use |cffffd100/bb extra save|r.") end
		else
			local e, err = CaptureHoveredExtra()
			if not e then Print(err); return end
			bbExtraLine = ExtraToLine(e)
			if sub == "save" then
				db.userExtras = db.userExtras or {}
				db.userExtras[e.id] = { name = e.name, slot = e.slot, stats = e.stats, source = "captured" }
				MergeExtras(); BuildRankIndex()
				Print(format("saved |cffffd100%s|r (%s) - it now ranks for your spec. Share this line to bake it in for everyone:", e.name or ("item " .. e.id), e.slot))
			else
				Print(format("captured |cffffd100%s|r (%s). Paste-ready line (also in the copy box):", e.name or ("item " .. e.id), e.slot))
			end
			Print(bbExtraLine)
			if StaticPopup_Show then StaticPopup_Show("BISBUDDY_EXTRA") end
		end
	elseif cmd == "" then
		ToggleMainPanel()                 -- /bb with no argument opens the setup GUI
	else
		RefreshSpec(true)
		Print(format("data %s (published %s, %d items) - spec: %s",
			D.dataVersion, strsub(D.publishedAt or "?", 1, 10), D.totalItems or 0,
			specKey and ("|cffffd100" .. specKey .. "|r") or "|cffff2020not detected|r"))
		local srcOn = 0
		for _, s in ipairs(SOURCE_BUCKETS) do if not db.sources or db.sources[s[1]] ~= false then srcOn = srcOn + 1 end end
		Print(format("phase |cffffd100%d %s|r  -  raid |cffffd100%s|r / M+ |cffffd100%s|r  -  sources |cffffd100%d/%d|r on  -  weights %s",
			db.phase, PhaseLabel(db.phase), DiffLabel(db.raidDiff), DiffLabel(db.mplusDiff),
			srcOn, #SOURCE_BUCKETS,
			IsSpecCustom() and "|cffcc66ffcustom|r" or "bisbeard"))
		Print(format("alerts %s (top-%d or >=%g%% upgrade), tooltip %s",
			db.alerts and "ON" or "OFF", db.threshold, db.minUpgradePct, db.tooltip and "ON" or "OFF"))
		Print("|cffffd100/bb|r opens the panel. commands: gear | sr | loot | list | enchants | talents [raid|dungeon] | phase | diff | sources | pvp on|off | crafted show|hide | weights | weight <stat> <val> | import | export | top <slot> | threshold <n> | minup <pct> | alerts | tooltip | caps | lockoh [off] | extra [save|list|clear] | spec | rescan | debug")
	end
end

--------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------

f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
f:RegisterEvent("UNIT_INVENTORY_CHANGED")
f:RegisterEvent("BAG_UPDATE")               -- refresh My Gear when bags change
f:RegisterEvent("CHARACTER_POINTS_CHANGED")
f:RegisterEvent("PLAYER_TALENT_UPDATE")
f:RegisterEvent("ACTIVE_TALENT_GROUP_CHANGED")
f:RegisterEvent("START_LOOT_ROLL")
f:RegisterEvent("LOOT_OPENED")
f:RegisterEvent("PLAYER_ENTERING_WORLD")   -- first version broadcast (comms ready)
f:RegisterEvent("PARTY_MEMBERS_CHANGED")   -- re-announce when the group changes
f:RegisterEvent("RAID_ROSTER_UPDATE")
f:RegisterEvent("CHAT_MSG_ADDON")          -- receive peers' versions

f:SetScript("OnEvent", function(self, event, arg1, arg2, arg3, arg4)
	if event == "CHAT_MSG_ADDON" then
		OnVersionMessage(arg1, arg2, arg3, arg4)
		OnLootMessage(arg1, arg2, arg3, arg4)
		return
	elseif event == "PLAYER_ENTERING_WORLD" or event == "PARTY_MEMBERS_CHANGED" or event == "RAID_ROSTER_UPDATE" then
		BroadcastVersion()
		return
	end
	if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
		BisBuddyDB = BisBuddyDB or {}
		db = BisBuddyDB
		if db.alerts == nil then db.alerts = true end
		if db.tooltip == nil then db.tooltip = true end
		db.threshold = db.threshold or 10
		db.minUpgradePct = db.minUpgradePct or 1
		db.phase = db.phase or 1 -- default: Pre-Raid + Zul'Gurub (raise as you progress)
		db.loTargets = db.loTargets or {}  -- loadout: pinned goal item per inv slot (iv -> itemId)
		-- difficulty is split into two independent caps (raid gear vs dungeon/M+ gear);
		-- migrate the old single db.maxDiff, then retire it.
		db.raidDiff = db.raidDiff or (db.maxDiff and math.min(db.maxDiff, 4)) or 4  -- raid gear cap (Ascended default)
		db.mplusDiff = db.mplusDiff or 5                                            -- dungeon/M+ gear cap (M+10 default)
		db.maxDiff = nil
		if db.includePvP == nil then db.includePvP = false end -- default: exclude PvP + Bloodforged
		if db.excludeCrafted == nil then db.excludeCrafted = false end -- default: show crafted
		if db.sources == nil then           -- per-source visibility (Sources panel)
			db.sources = { raid = true, dungeon = true, worldforged = true,
				bloodforged = false, worldboss = true, reputation = true,
				quest = true, crafted = true, vendor = true, events = true,
				pvp = false }               -- PvP + Bloodforged gear (PvP-power = a PvE trap) hidden by default
			if db.excludeCrafted then db.sources.crafted = false end   -- migrate old coarse toggles
			if db.includePvP then db.sources.pvp = true end
		end
		if not db.bfHiddenByDefault then    -- one-time: force Bloodforged off (PvE trap, like PvP) for existing installs too
			if db.sources then db.sources.bloodforged = false end
			db.bfHiddenByDefault = true
		end
		if db.lootShare == nil then db.lootShare = true end -- default: answer group loot checks
		db.sr = db.sr or { raid = "Naxxramas", count = 2, sortBy = "upgrade" } -- Reserve Planner state
		db.customWeights = db.customWeights or {} -- [specKey] = { statKey = weight, ... }
		db.charSpec = db.charSpec or {} -- [name@realm] = specKey (per-character manual spec)
		db.welcomed = db.welcomed or {} -- [name@realm] = true once the setup panel has auto-shown
		D = BisBuddyData
		TAL = BisBuddyTalents -- optional talent-tree data (may be absent)
		if not D or not D.cells then
			Print("|cffff2020Data.lua missing or invalid - regenerate with bisbuddy_generate.py|r")
			D = { weights = {}, cells = {}, items = {}, specAlias = {},
				phaseLabels = {}, diffLabels = {}, maxPhase = 1, maxDiff = 5, dataVersion = "?" }
		end
		if db.phase > (D.maxPhase or 5) then db.phase = D.maxPhase or 5 end
		if db.raidDiff > 4 then db.raidDiff = 4 end
		if db.mplusDiff > (D.maxDiff or 5) then db.mplusDiff = D.maxDiff or 5 end
		if db.threshold > MERGE_DEPTH then db.threshold = MERGE_DEPTH end
		db.userExtras = db.userExtras or {} -- [id] = {name,slot,stats,source}: personal /bb extra captures
		MergeExtras()                       -- fold curated + personal supplement into D.items
		-- db.lockOffHand = {id,name} or nil: manual off-hand for 1H-vs-2H compares
	elseif event == "PLAYER_LOGIN" then
		RefreshSpec(true)
		HookTooltip(GameTooltip)
		HookTooltip(ItemRefTooltip)
		Print(format("loaded (bisbeard %s)%s. Type |cffffd100/bb|r for the setup panel.",
			D.dataVersion or "?", DEV_BUILD and " |cffff8800[dev - version broadcasts off]|r" or ""))
		-- First time on this character (and spec didn't auto-detect): open the
		-- setup panel once so they can pick their spec. Never nags again.
		local ck = CharKey()
		if ck and not db.welcomed[ck] then
			db.welcomed[ck] = true
			if not specKey then
				ShowMainPanel()
			end
		end
	elseif event == "PLAYER_EQUIPMENT_CHANGED" or (event == "UNIT_INVENTORY_CHANGED" and arg1 == "player") then
		wipe(equippedScoreCache)
		if RenderGear then RenderGear() end
	elseif event == "BAG_UPDATE" then
		if RenderGear then RenderGear() end
	elseif event == "CHARACTER_POINTS_CHANGED" or event == "PLAYER_TALENT_UPDATE" or event == "ACTIVE_TALENT_GROUP_CHANGED" then
		specCheckedAt = 0
	elseif event == "START_LOOT_ROLL" then
		CheckLootRoll(arg1)
	elseif event == "LOOT_OPENED" then
		CheckLootWindow()
	end
end)
