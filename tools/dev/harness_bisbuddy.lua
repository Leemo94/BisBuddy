-- BisBuddy test harness: minimal WoW 3.3.5 stub env; loads the REAL Data.lua
-- and BisBuddy.lua, then drives spec detection, scoring, tooltip lines and
-- loot alerts. Run: luajit dev/harness_bisbuddy.lua  (from AscensionAddons/)
local ROOT = arg and arg[0] and arg[0]:match("^(.*)/dev/") or "."
local allOK = true
local function check(cond, label)
	if cond then print("PASS  " .. label) else print("FAIL  " .. label) allOK = false end
end

-- ---------- env ----------
_G.format, _G.strlower, _G.strfind, _G.strmatch, _G.strsub = string.format, string.lower, string.find, string.match, string.sub
_G.tinsert, _G.tremove = table.insert, table.remove
function _G.strtrim(s) return (s:gsub("^%s*(.-)%s*$", "%1")) end
function _G.wipe(t) for k in pairs(t) do t[k] = nil end return t end
function _G.geterrorhandler() return function(e) print("  [err] " .. tostring(e)) end end
_G.chatLog = {}
_G.DEFAULT_CHAT_FRAME = { AddMessage = function(self, m) chatLog[#chatLog + 1] = m end }
local function lastChat(n) return table.concat(chatLog, "\n", math.max(1, #chatLog - (n or 3)), #chatLog) end
local clock = 1000
function _G.GetTime() clock = clock + 5 return clock end
function _G.PlaySound() end
_G.ChatTypeInfo = { RAID_WARNING = {} }
_G.raidNotices = {}
function _G.RaidNotice_AddMessage(frame, msg) raidNotices[#raidNotices + 1] = msg end

-- item registry: id -> { stats = {ITEM_MOD_...=n}, equipLoc =, tipLines = {} }
local registry = {}
local function linkFor(id) return "|Hitem:" .. id .. ":0|h[Item " .. id .. "]|h" end

function _G.GetItemInfo(link)
	local id = tonumber(string.match(link or "", "item:(%d+)"))
	local r = id and registry[id]
	local loc = r and r.equipLoc or "INVTYPE_HEAD"
	local sub = r and r.subType or "Cloth"
	return "Item " .. tostring(id), link, 3, 60, 60, "Armor", sub, 1, loc, "icon", 1
end
function _G.GetItemStats(link, tbl)
	local id = tonumber(string.match(link or "", "item:(%d+)"))
	local r = id and registry[id]
	tbl = tbl or {}
	if r and r.stats then for k, v in pairs(r.stats) do tbl[k] = v end end
	return tbl
end

local equipped = {} -- invSlot -> id
function _G.GetInventoryItemLink(unit, slot) return equipped[slot] and linkFor(equipped[slot]) or nil end
local bags = { [0] = {}, [1] = {}, [2] = {}, [3] = {}, [4] = {} } -- bags[bag][slot] = id
function _G.GetContainerNumSlots(bag) return bags[bag] and 16 or 0 end
function _G.GetContainerItemLink(bag, slot)
	local id = bags[bag] and bags[bag][slot]
	return id and linkFor(id) or nil
end

_G.SpecializationUtil = {
	GetActiveSpecialization = function() return 5 end,
	GetSpecializationInfo = function(id) return "Invention" end,
}
function _G.UnitName() return "Testchar" end
function _G.GetRealmName() return "TestRealm" end
function _G.UnitClass() return "Tinker", "TINKER" end
-- version-check / addon-comms stubs
function _G.GetAddOnMetadata(name, key) if key == "Version" then return "1.6.0" end end
_G.sentAddonMsgs = {}
function _G.SendAddonMessage(prefix, msg, channel, target)
	sentAddonMsgs[#sentAddonMsgs + 1] = { prefix = prefix, msg = msg, channel = channel, target = target }
end
function _G.IsInGuild() return true end
function _G.GetNumRaidMembers() return 0 end
function _G.GetNumPartyMembers() return 0 end

-- loot stubs
local lootRollLinks, lootSlots = {}, {}
function _G.GetLootRollItemLink(rollId) return lootRollLinks[rollId] end
function _G.GetNumLootItems() return #lootSlots end
function _G.GetLootSlotLink(i) return lootSlots[i] end
function _G.LootSlotIsItem(i) return true end

local created = {}
local function NewFrame(name)
	local fr = { name = name, scripts = {}, hooks = {}, lines = {}, shown = true, text = "" }
	function fr:RegisterEvent() end
	function fr:SetScript(ev, fn) self.scripts[ev] = fn end
	function fr:GetScript(ev) return self.scripts[ev] end
	function fr:HookScript(ev, fn) self.hooks[ev] = self.hooks[ev] or {} table.insert(self.hooks[ev], fn) end
	function fr:SetOwner() end
	function fr:ClearLines() self.numLines = 0 end
	function fr:NumLines() return self.numLines or 0 end
	function fr:SetHyperlink(link)
		local id = tonumber(string.match(link or "", "item:(%d+)"))
		local r = id and registry[id]
		local tip = r and r.tipLines or {}
		self.numLines = #tip + 1
		for j, text in ipairs(tip) do
			local fsName = self.name .. "TextLeft" .. (j + 1)
			_G[fsName] = _G[fsName] or { }
			_G[fsName].GetText = function() return text end
		end
	end
	function fr:Hide() self.shown = false end
	function fr:Show() self.shown = true end
	function fr:IsShown() return self.shown end
	function fr:IsVisible() return self.shown end
	function fr:GetItem() return "name", self.currentLink end
	function fr:AddLine(text) table.insert(self.lines, text) end
	-- layout / widget no-ops
	function fr:SetWidth() end
	function fr:SetHeight() end
	function fr:SetPoint() end
	function fr:SetFrameStrata() end
	function fr:SetBackdrop() end
	function fr:SetBackdropColor() end
	function fr:SetBackdropBorderColor() end
	function fr:SetHighlightTexture() end
	function fr:SetMovable() end
	function fr:EnableMouse() end
	function fr:RegisterForDrag() end
	function fr:StartMoving() end
	function fr:StopMovingOrSizing() end
	function fr:SetJustifyH() end
	function fr:SetTextColor() end
	function fr:SetShadowColor() end
	function fr:SetShadowOffset() end
	function fr:SetFontObject() end
	function fr:SetAutoFocus() end
	function fr:SetNumeric() end
	function fr:HasFocus() return false end
	function fr:ClearFocus()
		local h = self.scripts.OnEditFocusLost
		if h then h(self) end
	end
	function fr:SetText(t) self.text = t end
	function fr:GetText() return self.text end
	function fr:SetChecked(v) self.checked = v and true or false end
	function fr:GetChecked() return self.checked end
	function fr:CreateFontString() return NewFrame((self.name or "f") .. "FS") end
	function fr:CreateTexture()
		local t = { r = nil }
		function t:SetAllPoints() end
		function t:SetPoint() end
		function t:SetWidth() end
		function t:SetHeight() end
		function t:SetTexture(a, b, c, d) self.r, self.g, self.b, self.a = a, b, c, d end
		function t:SetVertexColor() end
		function t:SetAlpha() end
		return t
	end
	function fr:ClearAllPoints() end
	function fr:GetName() return self.name end
	function fr:GetPoint() return "CENTER", _G.UIParent, "CENTER", 0, 0 end
	created[#created + 1] = fr
	return fr
end
function _G.CreateFrame(kind, name, parent, template)
	local fr = NewFrame(name)
	if name then
		_G[name] = fr
		if type(template) == "string" and template:find("CheckButton") then
			_G[name .. "Text"] = NewFrame(name .. "Text")
		end
	end
	return fr
end
_G.UISpecialFrames = {}
_G.StaticPopupDialogs = {}
function _G.StaticPopup_Show() end
_G.CLOSE, _G.CANCEL, _G.ACCEPT = "Close", "Cancel", "Accept"
-- dropdown stubs: capture built buttons into menuInfos for tests
_G.menuInfos = {}
function _G.UIDropDownMenu_CreateInfo() return {} end
function _G.UIDropDownMenu_AddButton(info) menuInfos[#menuInfos + 1] = info end
function _G.UIDropDownMenu_Initialize(frame, fn) frame.initFn = fn end
function _G.UIDropDownMenu_SetWidth() end
function _G.UIDropDownMenu_SetText(frame, t) frame.text = t end
function _G.UIDropDownMenu_SetSelectedValue() end
function _G.CloseDropDownMenus() end
function _G.IsShiftKeyDown() return false end
function _G.ChatEdit_InsertLink() end
function _G.GetItemQualityColor(q)
	local c = ({ [0]={.62,.62,.62}, [1]={1,1,1}, [2]={.12,1,0}, [3]={0,.44,.87},
		[4]={.64,.21,.93}, [5]={1,.5,0} })[q] or { 1, 1, 1 }
	return c[1], c[2], c[3], string.format("|cff%02x%02x%02x", c[1]*255, c[2]*255, c[3]*255)
end
_G.UIParent = NewFrame("UIParent")
_G.GameTooltip = NewFrame("GameTooltip")
_G.ItemRefTooltip = NewFrame("ItemRefTooltip")
_G.RaidWarningFrame = NewFrame("RaidWarningFrame")
_G.SlashCmdList = {}

-- ---------- load real Data.lua + addon ----------
assert(loadfile(os.getenv("BISBUDDY_DATA") or (ROOT .. "/../BisBuddy/Data.lua")))()
pcall(function() assert(loadfile(ROOT .. "/../BisBuddy/TalentData.lua"))() end) -- optional
check(type(BisBuddyData) == "table" and type(BisBuddyData.cells) == "table", "Data.lua loads (cells)")
check(BisBuddyData.maxDiff == 5, "maxDiff = 5 (got " .. tostring(BisBuddyData.maxDiff) .. ")")
check(BisBuddyData.maxPhase == 5, "maxPhase = 5 (got " .. tostring(BisBuddyData.maxPhase) .. ")")
check(BisBuddyData.phaseLabels[1]:find("Zul") ~= nil, "phase 1 label mentions Zul'Gurub")
check(BisBuddyData.phaseLabels[2] == "Molten Core", "phase 2 = Molten Core")
check(BisBuddyData.phaseLabels[5] == "Naxxramas", "phase 5 = Naxxramas")
check(BisBuddyData.diffLabels[3] == "Mythic" and BisBuddyData.diffLabels[4] == "Ascended"
	and BisBuddyData.diffLabels[5] == "Mythic+", "diff labels: 3 Mythic, 4 Ascended, 5 Mythic+")
-- base Mythic ("Mythic 0") is tier 3; keystones (Mythic 10-40) are tier 5
do
	local baseM, keyM = nil, nil
	for id, info in pairs(BisBuddyData.items) do
		if info[2] == "Mythic" then baseM = info[5]
		elseif info[2]:find("Mythic %d") then keyM = info[5] end
		if baseM and keyM then break end
	end
	check(baseM == 3, "base 'Mythic' items are tier 3 (Mythic 0)")
	check(keyM == 5, "'Mythic N' keystone items are tier 5 (Mythic+)")
end
local nspecs = 0
for _ in pairs(BisBuddyData.cells) do nspecs = nspecs + 1 end
check(nspecs == 70, "Data has 70 specs (got " .. nspecs .. ")")

-- reference merge mirroring the addon: cells with phase<=P, tier<=T, PvE-only
local function catOf(id) local i = BisBuddyData.items[id]; return i and i[6] or 0 end
local function mergeTop(spec, P, T, slot, includePvP)
	local acc = {}
	local cells = BisBuddyData.cells[spec]
	for ph = 1, P do
		if cells[ph] then for ti = 1, T do
			local c = cells[ph][ti]
			if c and c[slot] then for _, e in ipairs(c[slot]) do
				if includePvP or catOf(e[1]) == 0 then acc[#acc + 1] = e end
			end end
		end end
	end
	table.sort(acc, function(a, b) return a[2] > b[2] end)
	return acc
end

-- every item sits in its own difficulty-tier cell (no cross-tier leak)
do
	local leak = 0
	for _, byPhase in pairs(BisBuddyData.cells) do for _, byTier in pairs(byPhase) do
		for tier, slots in pairs(byTier) do for _, list in pairs(slots) do
			for _, e in ipairs(list) do
				local it = BisBuddyData.items[e[1]]
				if it and it[5] ~= tier then leak = leak + 1 end
			end
		end end
	end end
	check(leak == 0, "every item sits in its own difficulty-tier cell (no leak)")
end

-- cumulative difficulty: Ascended>=Mythic>=Heroic>=Normal for the #1 2H score
do
	local function s(T) local a = mergeTop("Tinker|Invention", 5, T, "Two-Hand", false); return a[1] and a[1][2] or 0 end
	check(s(4) >= s(3) and s(3) >= s(2) and s(2) >= s(1), "cumulative difficulty: Ascended>=Mythic>=Heroic>=Normal")
	local nId = mergeTop("Tinker|Invention", 5, 1, "Two-Hand", false)[1][1]
	local aId = mergeTop("Tinker|Invention", 5, 4, "Two-Hand", false)[1][1]
	check(nId ~= aId, "Normal-cap #1 differs from Ascended-cap #1")
end

-- PvE merge excludes PvP/Bloodforged; including yields >= items
do
	local merged = mergeTop("Tinker|Invention", 5, 4, "Two-Hand", false)
	local bad = 0
	for _, e in ipairs(merged) do if catOf(e[1]) ~= 0 then bad = bad + 1 end end
	check(bad == 0, "PvE merge (includePvP=false) excludes PvP/Bloodforged")
	check(#mergeTop("Tinker|Invention", 5, 4, "Two-Hand", true) >= #merged, "including PvP yields >= items")
end

-- pick the phase-5, Ascended-cap, PvE #1 two-hand for the ranked-item tests
local inv2h = mergeTop("Tinker|Invention", 5, 4, "Two-Hand", false)
local invRanged = mergeTop("Tinker|Invention", 5, 4, "Ranged", false)
check(#inv2h >= 10, "Invention merged P5 Two-Hand list present (" .. #inv2h .. ")")
local topStaffId, topStaffScore = inv2h[1][1], inv2h[1][2]
local topStaffName = BisBuddyData.items[topStaffId] and BisBuddyData.items[topStaffId][1]
check(type(topStaffName) == "string", "item pool has top staff name (" .. tostring(topStaffName) .. ")")
check(BisBuddyData.items[topStaffId][4] ~= nil and BisBuddyData.items[topStaffId][5] ~= nil,
	"item pool entries carry phase + tier fields")

local chunk = assert(loadfile(ROOT .. "/../BisBuddy/BisBuddy.lua"))
local before = #created
chunk("BisBuddy")
local ev
for i = before, #created do
	if created[i].scripts.OnEvent then ev = created[i] break end
end
check(ev ~= nil, "event frame found")
-- taint guard: BisBuddy must NEVER re-assign the StaticPopupDialogs / UISpecialFrames
-- GLOBALS (that taints secure UI at load - the PvP-ruleset + ConfirmBindOnUse bug).
-- Adding our own keys (StaticPopupDialogs["BISBUDDY_*"], tinsert(UISpecialFrames,...)) is fine.
do
	local src = assert(io.open(ROOT .. "/../BisBuddy/BisBuddy.lua")):read("*a")
	check(not src:find("StaticPopupDialogs = StaticPopupDialogs", 1, true),
		"no re-assignment of StaticPopupDialogs global (load-time taint guard)")
	check(not src:find("UISpecialFrames = UISpecialFrames", 1, true),
		"no re-assignment of UISpecialFrames global (load-time taint guard)")
end
ev.scripts.OnEvent(ev, "ADDON_LOADED", "BisBuddy")
check(BisBuddyDB.phase == 1, "default phase is 1 (Pre-Raid + ZG)")
check(BisBuddyDB.maxDiff == 3, "default maxDiff is 3 (Mythic 0, excludes Mythic+)")
ev.scripts.OnEvent(ev, "PLAYER_LOGIN")
check(lastChat(3):find("loaded", 1, true) ~= nil, "login banner printed")
check(lastChat(3):find("phase", 1, true) ~= nil, "login banner names the phase")
check(lastChat(3):find("Tinker|Invention", 1, true) ~= nil, "spec auto-detected as Tinker|Invention")

-- phase selector: switch to Naxxramas for the ranked-item tests below
SlashCmdList["BISBUDDY"]("phase naxx")
check(BisBuddyDB.phase == 5, "/bb phase naxx -> 5")
SlashCmdList["BISBUDDY"]("phase mc")
check(BisBuddyDB.phase == 2, "/bb phase mc -> 2")
SlashCmdList["BISBUDDY"]("phase 5")
check(BisBuddyDB.phase == 5, "/bb phase 5 -> 5")
-- ranked-item tests use the Ascended-cap merge (topStaffId is an Ascended item),
-- so raise the addon's difficulty cap from the Mythic-0 default to Ascended
SlashCmdList["BISBUDDY"]("diff ascended")
check(BisBuddyDB.maxDiff == 4, "/bb diff ascended -> 4 for ranked tests")

-- registry setup: equipped weak staff (unranked custom item)
registry[900001] = { equipLoc = "INVTYPE_2HWEAPON", stats = { ITEM_MOD_INTELLECT_SHORT = 10, ITEM_MOD_SPELL_POWER_SHORT = 30 } }
equipped[16] = 900001
registry[topStaffId] = { equipLoc = "INVTYPE_2HWEAPON" } -- ranked: score comes from Data, not stats

-- tooltip: top staff should show #1 BiS + upgrade
GameTooltip.currentLink = linkFor(topStaffId)
for _, fn in ipairs(GameTooltip.hooks.OnTooltipSetItem or {}) do fn(GameTooltip) end
local tipText = table.concat(GameTooltip.lines, "\n")
check(tipText:find("#1 BiS Two%-Hand") ~= nil, "tooltip shows #1 BiS Two-Hand")
check(tipText:find("vs equipped") ~= nil, "tooltip shows upgrade vs equipped")

-- GetItemStats scoring path: unranked ring, empty finger slots -> +100%
registry[900002] = { equipLoc = "INVTYPE_FINGER", stats = { ITEM_MOD_INTELLECT_SHORT = 10, ITEM_MOD_SPELL_POWER_SHORT = 20 } }
GameTooltip.lines = {}
GameTooltip.BisBuddyLastLink = nil
GameTooltip.currentLink = linkFor(900002)
for _, fn in ipairs(GameTooltip.hooks.OnTooltipSetItem or {}) do fn(GameTooltip) end
tipText = table.concat(GameTooltip.lines, "\n")
-- score = 10*0.442 + 20*1 = 24.42 -> "(24 vs 0)"
check(tipText:find("%(24 vs 0%)") ~= nil, "GetItemStats math correct (24.42 -> 24 vs 0): " .. tipText:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))

-- weapon dps path: unranked gun, Invention rangedDps=14, dps 35 -> +490
registry[900003] = { equipLoc = "INVTYPE_RANGEDRIGHT", subType = "Guns", stats = { ITEM_MOD_AGILITY_SHORT = 5 },
	tipLines = { "100 - 150 Damage Speed 3.50", "(35.0 damage per second)" } }
GameTooltip.lines = {}
GameTooltip.BisBuddyLastLink = nil
GameTooltip.currentLink = linkFor(900003)
for _, fn in ipairs(GameTooltip.hooks.OnTooltipSetItem or {}) do fn(GameTooltip) end
tipText = table.concat(GameTooltip.lines, "\n")
-- 35*14 = 490 (+agility 5*0? agility not in Invention weights) => score 490, empty ranged slot -> vs 0
check(tipText:find("%(490 vs 0%)") ~= nil, "weapon DPS scoring (35 dps x14 = 490): " .. tipText:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))

-- ---------- weapon/armor proficiency (Invention = Tinker: guns, no wands/plate) ----------
check(BisBuddyData.prof and BisBuddyData.prof.classes and BisBuddyData.prof.classes["Tinker"] ~= nil,
	"Data.lua bakes proficiency (prof.classes.Tinker)")
do
	local tw = BisBuddyData.prof.classes["Tinker"]
	local function has(list, v) for _, x in ipairs(list) do if x == v then return true end end return false end
	check(has(tw.weap, "Gun") and not has(tw.weap, "Wand"), "Tinker weapons include Gun, not Wand")
	check(has(tw.armor, "Mail") and not has(tw.armor, "Plate"), "Tinker armor includes Mail, not Plate")
	check(BisBuddyData.prof.rangedOverride["Sentinel"] ~= nil, "ranged override baked (Sentinel = Bow/Crossbow)")
end
-- an UNRANKED wand (has spellpower, would score) is not usable by Invention -> no tooltip
registry[900004] = { equipLoc = "INVTYPE_RANGEDRIGHT", subType = "Wands",
	stats = { ITEM_MOD_INTELLECT_SHORT = 15, ITEM_MOD_SPELL_POWER_SHORT = 40 } }
GameTooltip.lines = {}
GameTooltip.BisBuddyLastLink = nil
GameTooltip.currentLink = linkFor(900004)
for _, fn in ipairs(GameTooltip.hooks.OnTooltipSetItem or {}) do fn(GameTooltip) end
check(#GameTooltip.lines == 0, "wand shows no BiS/upgrade for a gun-only Tinker (proficiency)")
-- and a wand drop does not fire an upgrade alert
equipped[18] = nil -- empty ranged slot so it *would* be a raw upgrade if not filtered
ev.scripts.OnEvent(ev, "PLAYER_EQUIPMENT_CHANGED")
lootRollLinks[95] = linkFor(900004)
local pchat = #chatLog
ev.scripts.OnEvent(ev, "START_LOOT_ROLL", 95)
check(#chatLog == pchat, "wand drop fires no alert for a gun-only Tinker")
-- an unranked plate chest is likewise filtered out for Invention (cloth/leather/mail)
registry[900005] = { equipLoc = "INVTYPE_CHEST", subType = "Plate",
	stats = { ITEM_MOD_INTELLECT_SHORT = 20 } }
GameTooltip.lines = {}
GameTooltip.BisBuddyLastLink = nil
GameTooltip.currentLink = linkFor(900005)
for _, fn in ipairs(GameTooltip.hooks.OnTooltipSetItem or {}) do fn(GameTooltip) end
check(#GameTooltip.lines == 0, "plate chest shows nothing for a cloth/leather/mail Tinker")

-- loot roll alert: top-1 ranged item
local topRangedId = invRanged[1][1]
registry[topRangedId] = { equipLoc = "INVTYPE_RANGEDRIGHT" }
lootRollLinks[77] = linkFor(topRangedId)
local chatN = #chatLog
ev.scripts.OnEvent(ev, "START_LOOT_ROLL", 77)
check(#chatLog > chatN and lastChat(1):find("#1 BiS Ranged") ~= nil, "roll alert fires for #1 BiS Ranged")
check(#raidNotices > 0, "raid-warning banner for top-3 BiS")

-- threshold: a mid-ranked item (rank 12, within the addon's top-15) should NOT
-- alert at threshold 5, but should once the threshold is raised
local lowRank = 12
local lowId = invRanged[lowRank][1]
registry[lowId] = { equipLoc = "INVTYPE_RANGEDRIGHT" }
equipped[18] = topRangedId -- equipped the #1 -> lowId is a downgrade
ev.scripts.OnEvent(ev, "PLAYER_EQUIPMENT_CHANGED")
SlashCmdList["BISBUDDY"]("threshold 5")
lootRollLinks[78] = linkFor(lowId)
chatN = #chatLog
ev.scripts.OnEvent(ev, "START_LOOT_ROLL", 78)
check(#chatLog == chatN, "rank-" .. lowRank .. " downgrade does not alert at threshold 5")
SlashCmdList["BISBUDDY"]("threshold 25") -- clamps to MERGE_DEPTH (15)
lootRollLinks[79] = linkFor(lowId)
chatN = #chatLog
ev.scripts.OnEvent(ev, "START_LOOT_ROLL", 79)
check(#chatLog > chatN and lastChat(1):find(" BiS Ranged") ~= nil,
	"rank-" .. lowRank .. " alerts after raising threshold")

-- loot window alert dedupe (same item within 120s -> single alert)
lootSlots[1] = linkFor(lowId)
chatN = #chatLog
ev.scripts.OnEvent(ev, "LOOT_OPENED")
check(#chatLog == chatN, "alert dedupe: same item within 120s stays quiet")

-- /bb top staff
chatN = #chatLog
SlashCmdList["BISBUDDY"]("top staff")
local topOut = table.concat(chatLog, "\n", chatN + 1)
check(topOut:find("#1 " .. topStaffName:gsub("([%-%.%+%[%]%(%)%$%^%%%?%*])", "%%%1")) ~= nil, "/bb top staff lists #1 " .. topStaffName)
check(topOut:find("baseline") ~= nil, "/bb top shows equipped baseline")

-- phase selector affects tooltip ranking: at phase 1 the Naxx (P5) #1 staff
-- is no longer "#1 BiS Two-Hand"
SlashCmdList["BISBUDDY"]("phase 1")
GameTooltip.lines = {}
GameTooltip.BisBuddyLastLink = nil
GameTooltip.currentLink = linkFor(topStaffId)
for _, fn in ipairs(GameTooltip.hooks.OnTooltipSetItem or {}) do fn(GameTooltip) end
tipText = table.concat(GameTooltip.lines, "\n")
check(tipText:find("#1 BiS Two%-Hand") == nil, "phase 1: Naxx staff is not #1 BiS anymore")
SlashCmdList["BISBUDDY"]("phase 5") -- restore

-- difficulty cap (phase 5). topStaffId is the Ascended-tier #1; capping the max
-- difficulty below Ascended must drop it from #1.
check(BisBuddyData.items[topStaffId][5] == 4, "top staff is Ascended tier (premise)")
SlashCmdList["BISBUDDY"]("diff normal")
check(BisBuddyDB.maxDiff == 1, "/bb diff normal -> 1")
GameTooltip.lines = {}
GameTooltip.BisBuddyLastLink = nil
GameTooltip.currentLink = linkFor(topStaffId)
for _, fn in ipairs(GameTooltip.hooks.OnTooltipSetItem or {}) do fn(GameTooltip) end
tipText = table.concat(GameTooltip.lines, "\n")
check(tipText:find("#1 BiS Two%-Hand") == nil, "diff Normal: Ascended staff no longer #1 BiS")
SlashCmdList["BISBUDDY"]("diff mythic")
check(BisBuddyDB.maxDiff == 3, "/bb diff mythic -> 3 (Mythic 0)")
SlashCmdList["BISBUDDY"]("diff mythic+")
check(BisBuddyDB.maxDiff == 5, "/bb diff mythic+ -> 5 (keystones)")
SlashCmdList["BISBUDDY"]("diff asc")
check(BisBuddyDB.maxDiff == 4, "/bb diff asc -> 4 (restored)")
-- back at Ascended, the top staff is #1 again
GameTooltip.lines = {}
GameTooltip.BisBuddyLastLink = nil
GameTooltip.currentLink = linkFor(topStaffId)
for _, fn in ipairs(GameTooltip.hooks.OnTooltipSetItem or {}) do fn(GameTooltip) end
check(table.concat(GameTooltip.lines, "\n"):find("#1 BiS Two%-Hand") ~= nil, "diff Ascended: top staff is #1 again")

-- PvP/Bloodforged exclusion toggle (phase 5, diff Ascended). Find a PvP/BF item
-- that lands in the top-15 of some slot's merged include-PvP list.
local pvpId, pvpRank
do
	local slotsSeen = {}
	for _, byTier in pairs(BisBuddyData.cells["Tinker|Invention"]) do
		for _, slots in pairs(byTier) do for slot in pairs(slots) do slotsSeen[slot] = true end end
	end
	for slot in pairs(slotsSeen) do
		local merged = mergeTop("Tinker|Invention", 5, 4, slot, true)
		for i = 1, math.min(15, #merged) do
			if catOf(merged[i][1]) == 1 then pvpId, pvpRank = merged[i][1], i break end
		end
		if pvpId then break end
	end
end
check(pvpId ~= nil, "found a top-15 PvP/BF item in Invention for toggle test")
check(BisBuddyDB.sources.pvp == false, "default: PvP source hidden")
-- excluded: tooltip shows an "excluded" note and no BiS rank
GameTooltip.lines = {}
GameTooltip.BisBuddyLastLink = nil
GameTooltip.currentLink = linkFor(pvpId)
for _, fn in ipairs(GameTooltip.hooks.OnTooltipSetItem or {}) do fn(GameTooltip) end
tipText = table.concat(GameTooltip.lines, "\n")
check(tipText:find("Sources filter") ~= nil and tipText:find("BiS") == nil, "hidden item: tooltip says hidden by Sources filter, no rank")
-- excluded: no loot alert
lootRollLinks[90] = linkFor(pvpId)
chatN = #chatLog
ev.scripts.OnEvent(ev, "START_LOOT_ROLL", 90)
check(#chatLog == chatN, "excluded PvP/BF item does not trigger a loot alert")
-- include them
SlashCmdList["BISBUDDY"]("pvp on")
check(BisBuddyDB.sources.pvp == true, "/bb pvp on -> shown")
GameTooltip.lines = {}
GameTooltip.BisBuddyLastLink = nil
GameTooltip.currentLink = linkFor(pvpId)
for _, fn in ipairs(GameTooltip.hooks.OnTooltipSetItem or {}) do fn(GameTooltip) end
tipText = table.concat(GameTooltip.lines, "\n")
check(tipText:find("#" .. pvpRank .. " BiS") ~= nil, "after /bb pvp on: item shows #" .. pvpRank .. " BiS")
lootRollLinks[91] = linkFor(pvpId)
chatN = #chatLog
ev.scripts.OnEvent(ev, "START_LOOT_ROLL", 91)
check(#chatLog > chatN, "after /bb pvp on: PvP/BF item now alerts")
SlashCmdList["BISBUDDY"]("pvp off") -- restore default

-- ---------- crafted (profession) exclusion toggle ----------
local craftId
for id, info in pairs(BisBuddyData.items) do
	if info[8] == "crafting" or info[8] == "affixed" then craftId = id break end
end
check(craftId ~= nil, "data has crafted (profession) items to filter")
if craftId then
	check(BisBuddyDB.sources.crafted == true, "default: crafted items shown")
	GameTooltip.lines = {}; GameTooltip.BisBuddyLastLink = nil
	GameTooltip.currentLink = linkFor(craftId)
	for _, fn in ipairs(GameTooltip.hooks.OnTooltipSetItem or {}) do fn(GameTooltip) end
	check(table.concat(GameTooltip.lines, "\n"):find("Sources filter") == nil, "crafted shown: item not hidden")
	-- hide crafted
	SlashCmdList["BISBUDDY"]("crafted hide")
	check(BisBuddyDB.sources.crafted == false, "/bb crafted hide -> hidden")
	GameTooltip.lines = {}; GameTooltip.BisBuddyLastLink = nil
	GameTooltip.currentLink = linkFor(craftId)
	for _, fn in ipairs(GameTooltip.hooks.OnTooltipSetItem or {}) do fn(GameTooltip) end
	local ct = table.concat(GameTooltip.lines, "\n")
	check(ct:find("Sources filter") ~= nil, "crafted hidden: tooltip says hidden by Sources filter")
	-- a hidden crafted drop raises no alert
	lootRollLinks[92] = linkFor(craftId)
	local chatC = #chatLog
	ev.scripts.OnEvent(ev, "START_LOOT_ROLL", 92)
	check(#chatLog == chatC, "hidden crafted item does not trigger a loot alert")
	SlashCmdList["BISBUDDY"]("crafted show") -- restore default
	check(BisBuddyDB.sources.crafted == true, "/bb crafted show -> shown again")
end

-- ---------- 1H + off-hand  <->  2H weapon comparisons ----------
do
	SlashCmdList["BISBUDDY"]("spec Invention")
	local w = BisBuddyData.weights["Tinker|Invention"]
	local function wipeEq() ev.scripts.OnEvent(ev, "PLAYER_EQUIPMENT_CHANGED") end
	local function tipOf(id)
		GameTooltip.lines = {}; GameTooltip.BisBuddyLastLink = nil; GameTooltip.currentLink = linkFor(id)
		for _, fn in ipairs(GameTooltip.hooks.OnTooltipSetItem or {}) do fn(GameTooltip) end
		return table.concat(GameTooltip.lines, "\n")
	end
	-- (A) 1H + off-hand equipped, drop a 2H staff -> compared to the COMBINED pair
	registry[990016] = { equipLoc = "INVTYPE_WEAPONMAINHAND", subType = "Daggers", stats = { ITEM_MOD_SPELL_POWER_SHORT = 40 } }
	registry[990017] = { equipLoc = "INVTYPE_HOLDABLE", subType = "Miscellaneous", stats = { ITEM_MOD_INTELLECT_SHORT = 20 } }
	equipped[16] = 990016; equipped[17] = 990017; wipeEq()
	registry[990099] = { equipLoc = "INVTYPE_2HWEAPON", subType = "Staves", stats = { ITEM_MOD_SPELL_POWER_SHORT = 50, ITEM_MOD_INTELLECT_SHORT = 10 } }
	local combined = string.format("%.0f", 40 * w.spellPower + 20 * w.intellect)
	check(tipOf(990099):find("vs " .. combined, 1, true) ~= nil,
		"2H drop compares against combined 1H + off-hand (vs " .. combined .. ")")
	-- (B) 2H equipped, drop a One-Hand -> compared to the 2H (downgrade), not a false +100%
	equipped[16] = 990099; equipped[17] = nil; wipeEq()
	registry[990001] = { equipLoc = "INVTYPE_WEAPON", subType = "Daggers", stats = { ITEM_MOD_SPELL_POWER_SHORT = 45 } }
	local twoh = string.format("%.0f", 50 * w.spellPower + 10 * w.intellect)
	local tB = tipOf(990001)
	check(tB:find("vs " .. twoh, 1, true) ~= nil, "1H drop while 2H equipped compares against the 2H (vs " .. twoh .. ")")
	check(tB:find("100.0", 1, true) == nil and tB:find("vs 0", 1, true) == nil,
		"1H drop while 2H equipped is NOT a false 100% upgrade")
	-- (C) 2H equipped, drop a HELD off-hand (Tinker-usable) -> also compared to the 2H
	registry[990002] = { equipLoc = "INVTYPE_HOLDABLE", subType = "Miscellaneous", stats = { ITEM_MOD_SPELL_POWER_SHORT = 20 } }
	check(tipOf(990002):find("vs " .. twoh, 1, true) ~= nil, "off-hand (held) drop while 2H equipped compares against the 2H")
	-- (C2) an off-hand WEAPON is unequippable for non-dual-wield Tinker -> no eval at all
	registry[990003] = { equipLoc = "INVTYPE_WEAPONOFFHAND", subType = "Daggers", stats = { ITEM_MOD_SPELL_POWER_SHORT = 20 } }
	check(tipOf(990003):find("vs ", 1, true) == nil, "off-hand WEAPON gives no eval for non-dual-wield Tinker (dual-wield gate)")
	equipped[16] = nil; equipped[17] = nil; wipeEq()
end

-- ---------- custom weights (local override) ----------
-- state here: Invention, phase 5, diff Ascended (4), pvp off
local CODE2KEY = {
	int="intellect", str="strength", agi="agility", sta="stamina", spi="spirit",
	sp="spellPower", hp="healingPower", cr="critRating", ht="hasteRating", hit="hitRating",
	res="resilienceRating", exp="expertise", ap="attackPower", rap="rangedAttackPower",
	fap="feralAttackPower", arp="armorPenetration", spen="spellPenetration", mp5="mp5",
	hp5="hp5", def="defense", dg="dodge", par="parry", blk="block", bv="blockValue",
	sbv="shieldBlockValue", arm="armor",
}
local MELEE = { ["One-Hand"]=true, ["Two-Hand"]=true, ["Main Hand"]=true, ["Off Hand"]=true }
local function hCustomScore(id, slot, w)
	local st = BisBuddyData.items[id][7]; local s = 0
	for code, val in pairs(st) do
		if code == "dps" then
			if slot == "Ranged" then s = s + val*(w.rangedDps or 0)
			elseif MELEE[slot] then s = s + val*(w.weaponDps or 0) end
		else local k = CODE2KEY[code]; local wt = k and w[k]; if wt then s = s + val*wt end end
	end
	return s
end
-- proficiency mirror of the addon's CanUseByType (baked prof + item type field 9)
local function hCanUse(spec, typ, slot)
	local cp = BisBuddyData.prof.classes[spec:match("^(.-)|")]
	if not cp then return true end
	local ARM = { Cloth=1, Leather=1, Mail=1, Plate=1 }
	local ASLOT = { Head=1, Shoulders=1, Chest=1, Wrists=1, Hands=1, Waist=1, Legs=1, Feet=1 }
	local WSLOT = { ["One-Hand"]=1, ["Two-Hand"]=1, ["Main Hand"]=1, ["Off Hand"]=1, Ranged=1 }
	local WMAP = { Swords="Sword", ["One-Handed Swords"]="Sword", ["Two-Handed Swords"]="Sword",
		Daggers="Dagger", Axes="Axe", ["Two-Handed Axes"]="Axe", Maces="Mace", ["Two-Handed Maces"]="Mace",
		["Fist Weapons"]="Fist", Staves="Staff", Polearms="Polearm", Wands="Wand", Wand="Wand",
		Bows="Bow", Guns="Gun", Crossbows="Crossbow", Thrown="Thrown" }
	local function has(l, v)
		if l then for _, x in ipairs(l) do if x == v then return true end end end
		return false
	end
	if slot == "Shield" then return cp.shield and true or false end
	if ASLOT[slot] and ARM[typ] then return has(cp.armor, typ) end
	if WSLOT[slot] then
		local wt = WMAP[typ]; if not wt then return false end
		if not has(cp.weap, wt) then return false end
		if slot=="Off Hand" and cp.dw == false then return false end
		if (slot=="One-Hand" or slot=="Main Hand" or slot=="Off Hand") and has(cp.no1, wt) then return false end
		if slot=="Two-Hand" and has(cp.no2, wt) then return false end
		return true
	end
	return true
end
-- dual-wield gate: off-hand WEAPONS require dual-wield (Held In Off-hand / Shield are separate slots)
check(BisBuddyData.prof.classes["Tinker"] and BisBuddyData.prof.classes["Tinker"].dw == false,
	"Tinker cannot dual-wield (baked dw=false)")
check(not hCanUse("Tinker|Invention", "Daggers", "Off Hand"),
	"off-hand dagger REJECTED for non-dual-wield Tinker")
check(hCanUse("Tinker|Invention", "Daggers", "One-Hand"),
	"one-hand dagger still allowed for Tinker (main-hand use)")
do
	local barbSpec
	for k in pairs(BisBuddyData.weights) do if k:match("^Barbarian|") then barbSpec = k; break end end
	check(BisBuddyData.prof.classes["Barbarian"] and BisBuddyData.prof.classes["Barbarian"].dw == true,
		"Barbarian can dual-wield (baked dw=true)")
	check(barbSpec ~= nil and hCanUse(barbSpec, "Daggers", "Off Hand"),
		"off-hand dagger ALLOWED for dual-wield Barbarian (" .. tostring(barbSpec) .. ")")
end
-- baked stats present?
check(type(BisBuddyData.items[topStaffId][7]) == "table", "pool items carry baked raw stats (field 7)")
-- effective = bisbeard Invention merged with a huge stamina override
SlashCmdList["BISBUDDY"]("phase 5"); SlashCmdList["BISBUDDY"]("diff ascended")  -- fix caps: phase<=5, tier<=4
local effW = {}; for k,v in pairs(BisBuddyData.weights["Tinker|Invention"]) do effW[k]=v end
effW.stamina = 1000
-- expected #1 Two-Hand from the WIDE usable pool (what the addon ranks when weights
-- are custom), not just bisbeard's curated cells
local pool2h = {}
for _, id in ipairs(BisBuddyData.slotPool["Two-Hand"] or {}) do
	local info = BisBuddyData.items[id]
	if info and (info[4] or 1) <= 5 and (info[5] or 1) <= 4 and hCanUse("Tinker|Invention", info[9], "Two-Hand") then
		pool2h[#pool2h + 1] = { id }
	end
end
local expId, expScore = nil, -1
for _, e in ipairs(pool2h) do local s = hCustomScore(e[1], "Two-Hand", effW); if s > expScore then expScore, expId = s, e[1] end end
check(expId ~= nil and expId ~= topStaffId, "stamina=1000 override predicts a NEW #1 (not the bisbeard staff)")
-- apply via command, then verify the addon ranks the predicted item #1
SlashCmdList["BISBUDDY"]("weight stamina 1000")
check(BisBuddyDB.customWeights["Tinker|Invention"].stamina == 1000, "/bb weight stamina 1000 stored")
registry[expId] = { equipLoc = "INVTYPE_2HWEAPON" }
GameTooltip.lines = {}; GameTooltip.BisBuddyLastLink = nil
GameTooltip.currentLink = linkFor(expId)
for _, fn in ipairs(GameTooltip.hooks.OnTooltipSetItem or {}) do fn(GameTooltip) end
tipText = table.concat(GameTooltip.lines, "\n")
check(tipText:find("#1 BiS Two%-Hand") ~= nil, "custom re-rank: predicted item is now #1 BiS Two-Hand")
check(tipText:find("Custom") ~= nil, "tooltip shows Custom marker when weights are overridden")
-- and the old bisbeard #1 is no longer #1
GameTooltip.lines = {}; GameTooltip.BisBuddyLastLink = nil
GameTooltip.currentLink = linkFor(topStaffId)
for _, fn in ipairs(GameTooltip.hooks.OnTooltipSetItem or {}) do fn(GameTooltip) end
check(table.concat(GameTooltip.lines, "\n"):find("#1 BiS Two%-Hand") == nil, "bisbeard #1 staff is no longer #1 under custom weights")

-- the /bb weights panel: opens, and editing a field applies + re-ranks
SlashCmdList["BISBUDDY"]("weights")
check(_G.BisBuddyWeightsFrame and _G.BisBuddyWeightsFrame:IsShown(), "/bb weights opens the panel")
local editBox = _G["BisBuddyWeightEdit_spirit"]
check(editBox ~= nil, "panel has a per-stat edit box (spirit)")
editBox:SetText("5")
editBox.scripts.OnEditFocusLost(editBox) -- simulate leaving the field
check(BisBuddyDB.customWeights["Tinker|Invention"].spirit == 5, "editing the panel field sets the custom weight")

-- reset returns to bisbeard; the original staff is #1 again
SlashCmdList["BISBUDDY"]("weights reset")
check(BisBuddyDB.customWeights["Tinker|Invention"] == nil, "/bb weights reset clears custom weights")
GameTooltip.lines = {}; GameTooltip.BisBuddyLastLink = nil
GameTooltip.currentLink = linkFor(topStaffId)
for _, fn in ipairs(GameTooltip.hooks.OnTooltipSetItem or {}) do fn(GameTooltip) end
check(table.concat(GameTooltip.lines, "\n"):find("#1 BiS Two%-Hand") ~= nil, "after reset: bisbeard staff is #1 again")

-- ---------- weight-string import / export ----------
-- standard base64 mirroring the addon's codec, to inspect/produce strings
local B64C = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local b64c, b64l = {}, {}
for i = 1, #B64C do b64c[i - 1] = B64C:sub(i, i); b64l[B64C:sub(i, i)] = i - 1 end
local function b64enc(data)
	local out, len, i = {}, #data, 1
	while i <= len do
		local b1, b2, b3 = data:byte(i), data:byte(i + 1), data:byte(i + 2)
		local n1 = math.floor(b1 / 4)
		local n2 = (b1 % 4) * 16 + (b2 and math.floor(b2 / 16) or 0)
		local n3 = b2 and ((b2 % 16) * 4 + (b3 and math.floor(b3 / 64) or 0)) or nil
		local n4 = b3 and (b3 % 64) or nil
		out[#out + 1] = b64c[n1]; out[#out + 1] = b64c[n2]
		out[#out + 1] = n3 and b64c[n3] or "="; out[#out + 1] = n4 and b64c[n4] or "="
		i = i + 3
	end
	return table.concat(out)
end
local function b64dec(data)
	data = data:gsub("[^A-Za-z0-9%+%/%=]", "")
	local out, i, len = {}, 1, #data
	while i <= len do
		local s1, s2, s3, s4 = data:sub(i, i), data:sub(i + 1, i + 1), data:sub(i + 2, i + 2), data:sub(i + 3, i + 3)
		local c1, c2 = b64l[s1] or 0, b64l[s2] or 0
		local c3, c4 = b64l[s3], b64l[s4]
		out[#out + 1] = string.char(c1 * 4 + math.floor(c2 / 16))
		if s3 ~= "" and s3 ~= "=" then out[#out + 1] = string.char((c2 % 16) * 16 + math.floor((c3 or 0) / 4)) end
		if s4 ~= "" and s4 ~= "=" then out[#out + 1] = string.char(((c3 or 0) % 4) * 64 + (c4 or 0)) end
		i = i + 4
	end
	return table.concat(out)
end

-- export current (bisbeard) weights, decode, confirm base64-of-flat-JSON
SlashCmdList["BISBUDDY"]("export")
local expStr = lastChat(1):match("|cff88ff88(.-)|r")
check(expStr ~= nil and #expStr > 0, "/bb export prints a weight string")
local decoded = b64dec(expStr or "")
check(decoded:find('"spellPower":1', 1, true) ~= nil, "export = base64 of flat JSON with bisbeard keys")

-- round-trip: custom weight -> export -> reset -> import restores it
SlashCmdList["BISBUDDY"]("weight stamina 7")
SlashCmdList["BISBUDDY"]("export")
local rt = lastChat(1):match("|cff88ff88(.-)|r")
SlashCmdList["BISBUDDY"]("weights reset")
check(BisBuddyDB.customWeights["Tinker|Invention"] == nil, "cleared before import")
SlashCmdList["BISBUDDY"]("import " .. rt)
local cw = BisBuddyDB.customWeights["Tinker|Invention"]
check(cw and cw.stamina == 7, "round-trip import restores stamina=7")
check(cw and cw.spellPower == 1, "round-trip import restores spellPower=1")

-- GearWeights-format string imports with REPLACE semantics
SlashCmdList["BISBUDDY"]("weights reset")
local gw = b64enc('{"intellect":2,"spellPower":3}')
SlashCmdList["BISBUDDY"]("import " .. gw)
cw = BisBuddyDB.customWeights["Tinker|Invention"]
check(cw and cw.intellect == 2 and cw.spellPower == 3, "import GearWeights string sets int=2, sp=3")
check(cw and cw.critRating == 0, "import REPLACE: unlisted bisbeard stat (crit) pinned to 0")
-- garbage import is rejected, weights unchanged
SlashCmdList["BISBUDDY"]("weights reset")
local before = BisBuddyDB.customWeights["Tinker|Invention"]
SlashCmdList["BISBUDDY"]("import not-a-real-string!!!")
check(BisBuddyDB.customWeights["Tinker|Invention"] == before, "garbage import is rejected safely")
SlashCmdList["BISBUDDY"]("weights reset")

-- spec override
SlashCmdList["BISBUDDY"]("spec Incineration")
check(lastChat(2):find("Pyromancer|Incineration", 1, true) ~= nil, "spec override maps Incineration -> Pyromancer|Incineration")
SlashCmdList["BISBUDDY"]("spec auto")

-- ---------- robust spec detection (unknown client return signatures) ----------
-- name at return position #2 (retail-style: id, name, ...) must still resolve
_G.SpecializationUtil.GetSpecializationInfo = function(id) return 42, "Invention" end
SlashCmdList["BISBUDDY"]("rescan")
check(lastChat(3):find("Tinker|Invention", 1, true) ~= nil, "robust: spec name at return #2 resolves")
-- lowercase spec-only name resolves (case-insensitive)
_G.SpecializationUtil.GetSpecializationInfo = function(id) return "invention" end
SlashCmdList["BISBUDDY"]("rescan")
check(lastChat(3):find("Tinker|Invention", 1, true) ~= nil, "robust: lowercase spec name resolves")
-- full "Class|Spec" string resolves
_G.SpecializationUtil.GetSpecializationInfo = function(id) return "Tinker|Invention" end
SlashCmdList["BISBUDDY"]("rescan")
check(lastChat(3):find("Tinker|Invention", 1, true) ~= nil, "robust: full Class|Spec string resolves")
-- missing SpecializationUtil -> no crash, just no detection
local savedSU = _G.SpecializationUtil
_G.SpecializationUtil = nil
SlashCmdList["BISBUDDY"]("rescan")
check(true, "robust: missing SpecializationUtil does not error")
-- /bb debug runs and dumps the API diagnostics even with SU missing
local chatN2 = #chatLog
SlashCmdList["BISBUDDY"]("debug")
check(#chatLog > chatN2 and table.concat(chatLog, "\n", chatN2 + 1):find("MISSING", 1, true) ~= nil,
	"/bb debug reports SpecializationUtil MISSING safely")
_G.SpecializationUtil = savedSU
_G.SpecializationUtil.GetSpecializationInfo = function(id) return "Invention" end
SlashCmdList["BISBUDDY"]("rescan")
chatN2 = #chatLog
SlashCmdList["BISBUDDY"]("debug")
local dbg = table.concat(chatLog, "\n", chatN2 + 1)
check(dbg:find("GetSpecializationInfo", 1, true) ~= nil and dbg:find("resolved:", 1, true) ~= nil,
	"/bb debug dumps spec API + resolved spec + gear scan")

-- GetCurrentSpecializationInfo path (Ascension's archetype-oriented call)
_G.SpecializationUtil.GetSpecializationInfo = function(id) return "Specialization: 1" end -- slot name, no match
_G.SpecializationUtil.GetCurrentSpecializationInfo = function() return "Invention", "icon", nil, nil, true end
SlashCmdList["BISBUDDY"]("rescan")
check(lastChat(3):find("Tinker|Invention", 1, true) ~= nil, "detect via GetCurrentSpecializationInfo (nil-safe scan)")

-- real-client shape: slot number + generic "Specialization: N" name -> no auto-detect
_G.SpecializationUtil.GetCurrentSpecializationInfo = function() return "Specialization: 1", "icon", nil, nil, true end
_G.SpecializationUtil.GetActiveSpecialization = function() return 1 end
SlashCmdList["BISBUDDY"]("spec auto")
SlashCmdList["BISBUDDY"]("rescan")
check(lastChat(4):find("couldn't auto%-detect") ~= nil, "real-client shape: falls back to manual with a clear hint")

-- manual /bb spec persists PER CHARACTER (survives, keyed by name@realm)
SlashCmdList["BISBUDDY"]("spec heretic")
check(BisBuddyDB.charSpec and BisBuddyDB.charSpec["Testchar@TestRealm"] == "Cultist|Heretic",
	"/bb spec heretic saves Cultist|Heretic for this character")
check(lastChat(2):find("Cultist|Heretic", 1, true) ~= nil, "/bb spec heretic resolves + applies")
-- a different character does NOT inherit it
_G.UnitName = function() return "Otherchar" end
SlashCmdList["BISBUDDY"]("rescan")
check(BisBuddyDB.charSpec["Otherchar@TestRealm"] == nil, "per-character: other char not affected by the override")
_G.UnitName = function() return "Testchar" end

-- ---------- main setup panel (/bb GUI) ----------
SlashCmdList["BISBUDDY"]("") -- no-arg opens the panel
check(_G.BisBuddyFrame and _G.BisBuddyFrame:IsShown(), "/bb opens the setup panel")
local panel = _G.BisBuddyFrame
-- drive a taint-free MakeDropdown: run its builder, collecting the offered rows
local function driveDD(dd)
	local rows = {}
	dd.builder(function(text, func, checked, keepOpen)
		rows[#rows + 1] = { text = text, func = func, checked = checked, keepOpen = keepOpen }
	end)
	return rows
end
-- spec picker: level 1 lists classes (navigable); drilling in lists that class's specs
local rows = driveDD(panel.specDD)
local cultistRow
for _, r in ipairs(rows) do if r.text:find("Cultist", 1, true) and r.keepOpen then cultistRow = r end end
check(cultistRow ~= nil, "spec picker lists classes to drill into (Cultist)")
cultistRow.func()                                  -- navigate into Cultist
rows = driveDD(panel.specDD)
local hereticRow
for _, r in ipairs(rows) do if r.text == "Heretic" then hereticRow = r end end
check(hereticRow ~= nil, "spec picker lists a class's specs (Heretic under Cultist)")
BisBuddyDB.charSpec["Testchar@TestRealm"] = nil
hereticRow.func()
check(BisBuddyDB.charSpec["Testchar@TestRealm"] == "Cultist|Heretic", "picking a spec in the panel saves it per character")
panel.specDD.navState = nil
-- phase + difficulty pickers drive the same setters
rows = driveDD(panel.phaseDD)
rows[3].func()
check(BisBuddyDB.phase == 3, "panel phase picker sets phase")
rows = driveDD(panel.diffDD)
rows[4].func()
check(BisBuddyDB.maxDiff == 4, "panel diff picker sets max difficulty")
-- checkboxes (PvP/crafted filters moved to the Sources panel; covered by /bb pvp|crafted above)
panel.tooltipCB:SetChecked(false); panel.tooltipCB.scripts.OnClick(panel.tooltipCB)
check(BisBuddyDB.tooltip == false, "tooltip checkbox toggles db.tooltip")
panel.tooltipCB:SetChecked(true); panel.tooltipCB.scripts.OnClick(panel.tooltipCB)
-- /bb again closes it
SlashCmdList["BISBUDDY"]("")
check(not panel:IsShown(), "/bb again closes the panel")

-- first-login auto-open when no spec can be detected, then never nags again
BisBuddyDB.welcomed = {}
BisBuddyDB.charSpec = {}
_G.SpecializationUtil.GetCurrentSpecializationInfo = function() return "Specialization: 1" end
_G.SpecializationUtil.GetSpecializationInfo = function() return "Specialization: 1" end
_G.SpecializationUtil.GetActiveSpecialization = function() return 1 end
ev.scripts.OnEvent(ev, "PLAYER_LOGIN")
check(panel:IsShown(), "first login with no detectable spec auto-opens the panel")
panel:Hide()
ev.scripts.OnEvent(ev, "PLAYER_LOGIN")
check(not panel:IsShown(), "second login does not re-open the panel (welcomed once)")

-- ---------- talent tree panel (/bb talents) ----------
if BisBuddyTalents and BisBuddyTalents.trees["Tinker"] then
	SlashCmdList["BISBUDDY"]("spec Invention") -- ensure Tinker|Invention active
	SlashCmdList["BISBUDDY"]("talents")
	check(_G.BisBuddyTalentsFrame and _G.BisBuddyTalentsFrame:IsShown(), "/bb talents opens the tree panel")
	local tp = _G.BisBuddyTalentsFrame
	local shown = 0
	for _, b in ipairs(tp.nodes) do if b.shown then shown = shown + 1 end end
	check(shown > 20, "talent panel renders nodes (" .. shown .. " shown)")
	-- traffic-light variety: some green nodes, some red
	local greens, reds = 0, 0
	for _, b in ipairs(tp.nodes) do
		if b.shown and b.tg then
			if b.tg > 0.8 and b.tr < 0.3 then greens = greens + 1
			elseif b.tr > 0.6 and b.tg < 0.3 then reds = reds + 1 end
		end
	end
	check(greens > 5, "panel colours core talents green (" .. greens .. ")")
	check(reds > 0, "panel colours rarely-taken talents red (" .. reds .. ")")
	-- a node carries a take% tooltip line
	local hasPct = false
	for _, b in ipairs(tp.nodes) do if b.shown and b.tpct and b.tpct:find("Taken by") then hasPct = true break end end
	check(hasPct, "talent nodes carry a take-rate tooltip")
	SlashCmdList["BISBUDDY"]("talents") -- close
	check(not tp:IsShown(), "/bb talents again closes the panel")

	-- raid/dungeon toggle + % labels (only when both datasets are baked)
	local inv = BisBuddyTalents.takeRates["Tinker|Invention"]
	if inv and inv.raid and inv.dungeon then
		check(BisBuddyTalents.sources ~= nil, "TalentData exposes a sources list")
		BisBuddyDB.talentSource = "raid"
		SlashCmdList["BISBUDDY"]("talents") -- open
		check(tp.srcBtn and tp.srcBtn.shown, "source toggle shows when both datasets exist")
		local labelled = 0
		for _, b in ipairs(tp.nodes) do if b.shown and b.pctlabel and b.pctlabel.shown then labelled = labelled + 1 end end
		check(labelled > 0, "contested talents show a take-rate % label (" .. labelled .. ")")
		SlashCmdList["BISBUDDY"]("talents dungeon")
		check(BisBuddyDB.talentSource == "dungeon", "/bb talents dungeon switches source")
		local differ = false
		for id, p in pairs(inv.raid.pct) do if (inv.dungeon.pct[id] or -1) ~= p then differ = true break end end
		check(differ, "raid and dungeon take-rates actually differ")
		SlashCmdList["BISBUDDY"]("talents raid")
		check(BisBuddyDB.talentSource == "raid", "/bb talents raid switches back")
		if tp:IsShown() then SlashCmdList["BISBUDDY"]("talents") end -- close
	end
end

-- ---------- BiS Lists browser (/bb list) ----------
SlashCmdList["BISBUDDY"]("spec Invention") -- a spec that has ranked data
SlashCmdList["BISBUDDY"]("list")
check(_G.BisBuddyBrowseFrame and _G.BisBuddyBrowseFrame:IsShown(), "/bb list opens the BiS Lists browser")
local bp = _G.BisBuddyBrowseFrame
-- the slot dropdown lists only slots that have data
local slotRows = driveDD(bp.slotDD)
check(#slotRows > 0, "browser slot dropdown lists slots with data (" .. #slotRows .. ")")
-- pick the first offered slot and confirm ranked rows render with item ids
slotRows[1].func()
local browsed = 0
for _, r in ipairs(bp.rows) do if r.shown and r.itemId then browsed = browsed + 1 end end
check(browsed > 0, "browser renders ranked rows for the picked slot (" .. browsed .. ")")
-- changing phase while it's open keeps it in sync (BuildRankIndex -> RenderBrowse)
SlashCmdList["BISBUDDY"]("phase 1")
local browsed2 = 0
for _, r in ipairs(bp.rows) do if r.shown and r.itemId then browsed2 = browsed2 + 1 end end
check(browsed2 > 0, "browser stays populated after a phase change (" .. browsed2 .. ")")

-- de-dup: same base item's difficulty/version variants collapse into one row.
SlashCmdList["BISBUDDY"]("phase 5")
SlashCmdList["BISBUDDY"]("diff mythic+")   -- widest set of difficulty variants
local slotInfos = driveDD(bp.slotDD)
local expandable, chosenSlot
for _, info in ipairs(slotInfos) do
	info.func() -- select this slot + render
	for _, r in ipairs(bp.rows) do
		if r.shown and r.expandKey then expandable, chosenSlot = r, info.text break end
	end
	if expandable then break end
end
check(expandable ~= nil, "browser finds a multi-version item to collapse (slot " .. tostring(chosenSlot) .. ")")
-- header rows carry unique item names (no base item repeated)
local names, dup = {}, false
for _, r in ipairs(bp.rows) do
	if r.shown and r.groupName then
		if names[r.groupName] then dup = true end
		names[r.groupName] = true
	end
end
check(not dup, "browser collapses same-name variants (no duplicate item among header rows)")
-- expand shows the item's other versions; a second click collapses again
if expandable then
	local before = 0
	for _, r in ipairs(bp.rows) do if r.shown then before = before + 1 end end
	expandable.scripts.OnClick(expandable) -- plain click (shift not down) => expand
	local after = 0
	for _, r in ipairs(bp.rows) do if r.shown then after = after + 1 end end
	check(after > before, "browser expands an item's other difficulties on click (" .. before .. " -> " .. after .. ")")
	expandable.scripts.OnClick(expandable) -- collapse
	local recol = 0
	for _, r in ipairs(bp.rows) do if r.shown then recol = recol + 1 end end
	check(recol == before, "browser collapses again on a second click (" .. recol .. ")")
end

SlashCmdList["BISBUDDY"]("list") -- close
check(not bp:IsShown(), "/bb list again closes the browser")

-- ---------- Best Enchants panel (/bb enchants) ----------
check(type(BisBuddyData.enchants) == "table" and #BisBuddyData.enchants > 0,
	"Data.lua bakes enchants (" .. #(BisBuddyData.enchants or {}) .. ")")
SlashCmdList["BISBUDDY"]("spec Invention")
SlashCmdList["BISBUDDY"]("enchants")
check(_G.BisBuddyEnchantsFrame and _G.BisBuddyEnchantsFrame:IsShown(), "/bb enchants opens the Best Enchants panel")
local ep = _G.BisBuddyEnchantsFrame
local eheaders, eexpand, sawSP = 0, nil, false
for _, r in ipairs(ep.rows) do
	if r.shown and r.enchSlot then
		eheaders = eheaders + 1
		if r.expandKey then eexpand = eexpand or r end
		if (r.text:GetText() or ""):find("SP") then sawSP = true end
	end
end
check(eheaders > 0, "enchants panel lists a best enchant per slot (" .. eheaders .. " slots)")
check(sawSP, "caster (Invention) enchant picks feature spell power")
check(eexpand ~= nil, "at least one slot offers alternate enchants (expandable)")
if eexpand then
	local before = 0
	for _, r in ipairs(ep.rows) do if r.shown then before = before + 1 end end
	eexpand.scripts.OnClick(eexpand)
	local after = 0
	for _, r in ipairs(ep.rows) do if r.shown then after = after + 1 end end
	check(after > before, "enchants panel expands alternates on click (" .. before .. " -> " .. after .. ")")
	eexpand.scripts.OnClick(eexpand)
end
SlashCmdList["BISBUDDY"]("enchants") -- close
check(not ep:IsShown(), "/bb enchants again closes the panel")

-- ---------- My Gear panel (/bb gear) ----------
SlashCmdList["BISBUDDY"]("spec Invention")
-- equip a weak head; drop a strong, usable head in your bags
registry[960001] = { equipLoc = "INVTYPE_HEAD", subType = "Cloth", stats = { ITEM_MOD_SPELL_POWER_SHORT = 5 } }
equipped[1] = 960001
registry[960002] = { equipLoc = "INVTYPE_HEAD", subType = "Cloth", stats = { ITEM_MOD_SPELL_POWER_SHORT = 40 } }
bags[0][1] = 960002
SlashCmdList["BISBUDDY"]("gear")
check(_G.BisBuddyGearFrame and _G.BisBuddyGearFrame:IsShown(), "/bb gear opens the My Gear panel")
local gp = _G.BisBuddyGearFrame
check((gp.header:GetText() or ""):find("of BiS", 1, true) ~= nil, "gear panel shows an overall % of BiS")
-- Head is the first slot row; it should flag the better bag item (green up-arrow)
check((gp.rows[1].c2:GetText() or ""):find("\226\134\145", 1, true) ~= nil, "gear flags a better Head item sitting in bags")
-- a 'Farm next' section is present (plenty of unowned BiS upgrades)
local sawFarm = false
for _, r in ipairs(gp.rows) do if r.shown and r.c2 and (r.c2:GetText() or ""):find("Farm next", 1, true) then sawFarm = true end end
check(sawFarm, "gear panel lists a 'Farm next' section")
-- swap the head into the equipped slot; a BAG_UPDATE refreshes it to 'worn'
equipped[1] = 960002; bags[0][1] = 960001
ev.scripts.OnEvent(ev, "BAG_UPDATE")
check((gp.rows[1].c2:GetText() or ""):find("worn", 1, true) ~= nil, "gear updates to 'worn' when equipped beats bags (BAG_UPDATE refresh)")
SlashCmdList["BISBUDDY"]("gear")
check(not gp:IsShown(), "/bb gear again closes the panel")
equipped[1] = nil; bags[0][1] = nil

-- ---------- out-of-date version check (DBM-style) ----------
-- broadcast on entering world: announces our version + a query, on GUILD
_G.sentAddonMsgs = {}
ev.scripts.OnEvent(ev, "PLAYER_ENTERING_WORLD")
do
	local sawV, sawQ = false, false
	for _, m in ipairs(sentAddonMsgs) do
		if m.prefix == "BisBuddyVer" and m.channel == "GUILD" then
			if m.msg == "V1.6.0" then sawV = true elseif m.msg == "Q" then sawQ = true end
		end
	end
	check(sawV and sawQ, "version broadcast sends V<ver> + Q to guild on entering world")
end
-- an older peer version does NOT warn
local vchat = #chatLog
ev.scripts.OnEvent(ev, "CHAT_MSG_ADDON", "BisBuddyVer", "V1.0.0", "GUILD", "Oldie")
check(#chatLog == vchat, "older peer version does not warn")
-- a query from a peer replies with our version (whisper to them)
_G.sentAddonMsgs = {}
ev.scripts.OnEvent(ev, "CHAT_MSG_ADDON", "BisBuddyVer", "Q", "GUILD", "Asker")
do
	local replied = false
	for _, m in ipairs(sentAddonMsgs) do
		if m.prefix == "BisBuddyVer" and m.msg == "V1.6.0" and m.channel == "WHISPER" and m.target == "Asker" then replied = true end
	end
	check(replied, "answers a peer's version query with our version")
end
-- our own broadcast is ignored (no warn even if it looked newer)
vchat = #chatLog
ev.scripts.OnEvent(ev, "CHAT_MSG_ADDON", "BisBuddyVer", "V9.9.9", "GUILD", "Testchar")
check(#chatLog == vchat, "ignores our own version broadcast")
-- a NEWER peer version warns once
ev.scripts.OnEvent(ev, "CHAT_MSG_ADDON", "BisBuddyVer", "V1.7.0", "GUILD", "Updated")
check(lastChat(1):find("newer version", 1, true) ~= nil and lastChat(1):find("1.7.0", 1, true) ~= nil,
	"newer peer version warns you're out of date")
-- ...and only once (latched)
vchat = #chatLog
ev.scripts.OnEvent(ev, "CHAT_MSG_ADDON", "BisBuddyVer", "V1.4.0", "GUILD", "Updated2")
check(#chatLog == vchat, "out-of-date warning fires only once per session")

-- ---------- group loot helper (/bb loot) ----------
SlashCmdList["BISBUDDY"]("spec Invention")
_G.GetNumPartyMembers = function() return 4 end -- we're in a party now
local lootId = topStaffId               -- a ranked BiS two-hander
local lootLink = linkFor(lootId)
equipped[16] = nil                      -- empty weapon -> the staff is a big upgrade for us
_G.sentAddonMsgs = {}
SlashCmdList["BISBUDDY"]("loot " .. lootLink)
do
	local sawQ = false
	for _, m in ipairs(sentAddonMsgs) do
		if m.prefix == "BisBuddyLoot" and m.channel == "PARTY" and m.msg:find("^Q") then sawQ = true end
	end
	check(sawQ, "/bb loot broadcasts a query to the party")
end
-- a party member answers, then the collection timer fires
ev.scripts.OnEvent(ev, "CHAT_MSG_ADDON", "BisBuddyLoot", "A" .. lootId .. ";7;3", "WHISPER", "Bob")
local lt = _G.BisBuddyLootTimer
lt:GetScript("OnUpdate")(lt, 5) -- dt >= 3s -> LootFinish
do
	local out = lastChat(2)
	check(out:find("loot check", 1, true) ~= nil, "loot check prints a summary")
	check(out:find("Bob", 1, true) ~= nil and out:find("Testchar", 1, true) ~= nil,
		"summary includes both yourself and the peer who answered")
end
-- as a responder: a group member asks us -> we whisper an answer back
_G.sentAddonMsgs = {}
ev.scripts.OnEvent(ev, "CHAT_MSG_ADDON", "BisBuddyLoot", "Q" .. lootLink, "PARTY", "Sue")
do
	local replied = false
	for _, m in ipairs(sentAddonMsgs) do
		if m.prefix == "BisBuddyLoot" and m.channel == "WHISPER" and m.target == "Sue" and m.msg:find("^A") then replied = true end
	end
	check(replied, "we answer a group member's loot query (whisper back)")
end
-- opt out: /bb loot off -> we stay silent
SlashCmdList["BISBUDDY"]("loot off")
_G.sentAddonMsgs = {}
ev.scripts.OnEvent(ev, "CHAT_MSG_ADDON", "BisBuddyLoot", "Q" .. lootLink, "PARTY", "Sue")
do
	local replied = false
	for _, m in ipairs(sentAddonMsgs) do if m.prefix == "BisBuddyLoot" and m.msg:find("^A") then replied = true end end
	check(not replied, "with loot sharing off, we don't answer queries")
end
-- and a query on a non-group channel (e.g. WHISPER) is ignored (privacy)
SlashCmdList["BISBUDDY"]("loot on")
_G.sentAddonMsgs = {}
ev.scripts.OnEvent(ev, "CHAT_MSG_ADDON", "BisBuddyLoot", "Q" .. lootLink, "WHISPER", "Ganker")
do
	local replied = false
	for _, m in ipairs(sentAddonMsgs) do if m.prefix == "BisBuddyLoot" and m.msg:find("^A") then replied = true end end
	check(not replied, "a loot query outside PARTY/RAID is ignored")
end

-- ---------- Reserve Planner (/bb sr) ----------
SlashCmdList["BISBUDDY"]("spec Invention")
SlashCmdList["BISBUDDY"]("sr")
check(_G.BisBuddySRFrame and _G.BisBuddySRFrame:IsShown(), "/bb sr opens the Reserve Planner")
local rp = _G.BisBuddySRFrame
-- raid dropdown lists the raids; pick Naxxramas
local raidRows = driveDD(rp.raidDD)
local naxx
for _, r in ipairs(raidRows) do if r.text == "Naxxramas" then naxx = r end end
check(naxx ~= nil, "reserve planner raid dropdown lists Naxxramas")
naxx.func()
-- difficulty dropdown -> tier 3 (Mythic)
local diffRows = driveDD(rp.diffDD)
diffRows[3].func()
-- rows populate, and the top `count` are starred to reserve
local rows, starred = 0, 0
for _, r in ipairs(rp.rows) do
	if r.shown then
		rows = rows + 1
		if (r.text:GetText() or ""):find("\226\152\133", 1, true) then starred = starred + 1 end
	end
end
check(rows > 0, "reserve planner lists this raid's gear for the spec (" .. rows .. ")")
check(starred == (BisBuddyDB.sr.count or 2), "top " .. (BisBuddyDB.sr.count or 2) .. " are starred to reserve")
-- SR count field changes how many are starred
rp.countEB:SetText("4"); rp.countEB.scripts.OnEnterPressed(rp.countEB)
local starred4 = 0
for _, r in ipairs(rp.rows) do if r.shown and (r.text:GetText() or ""):find("\226\152\133", 1, true) then starred4 = starred4 + 1 end end
check(starred4 == 4, "changing SR count restars the top N (4)")
-- sort toggle flips between upgrade and best-item
rp.sortBtn.scripts.OnClick(rp.sortBtn)
check(BisBuddyDB.sr.sortBy == "score", "sort toggle -> best item")
rp.sortBtn.scripts.OnClick(rp.sortBtn)
check(BisBuddyDB.sr.sortBy == "upgrade", "sort toggle -> biggest upgrade")
SlashCmdList["BISBUDDY"]("sr")
check(not rp:IsShown(), "/bb sr again closes the Reserve Planner")

-- ============================================================================
-- 1H vs 2H off-hand-aware comparison (v1.8.0)
-- ============================================================================
SlashCmdList["BISBUDDY"]("spec Invention")     -- caster: spellPower=1, intellect=0.442
for s = 1, 18 do equipped[s] = nil end
for b = 0, 4 do for s = 1, 16 do bags[b][s] = nil end end
BisBuddyDB.lockOffHand = nil

registry[700001] = { equipLoc = "INVTYPE_2HWEAPON", subType = "Staves", stats = { ITEM_MOD_SPELL_POWER_SHORT = 100 } }
equipped[16] = 700001                           -- equipped 2H staff, score 100
registry[700002] = { equipLoc = "INVTYPE_HOLDABLE", subType = "Miscellaneous", stats = { ITEM_MOD_SPELL_POWER_SHORT = 40 } }
bags[0][1] = 700002                             -- best owned off-hand, score 40
registry[700004] = { equipLoc = "INVTYPE_HOLDABLE", stats = { ITEM_MOD_SPELL_POWER_SHORT = 60 } } -- a stronger OH, for the lock test
registry[700003] = { equipLoc = "INVTYPE_WEAPON", subType = "Daggers", stats = { ITEM_MOD_SPELL_POWER_SHORT = 70 } } -- hovered 1H, score 70
ev.scripts.OnEvent(ev, "PLAYER_EQUIPMENT_CHANGED")

local function tipFor(id)
	GameTooltip.lines = {}
	GameTooltip.BisBuddyLastLink = nil
	GameTooltip.currentLink = linkFor(id)
	for _, fn in ipairs(GameTooltip.hooks.OnTooltipSetItem or {}) do fn(GameTooltip) end
	return table.concat(GameTooltip.lines, "\n")
end
local function clean(s) return (s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")) end

-- 1H alone = 70 vs 100 (a downgrade); paired with the best owned OH (40) it's
-- (70+40)=110 vs 100 = +10% upgrade
local t = tipFor(700003)
check(t:find("%(110 vs 100%)") ~= nil, "1H vs 2H pairs the best owned off-hand: (110 vs 100)  [" .. clean(t) .. "]")
check(t:find("as 1H %+") ~= nil, "1H vs 2H tooltip notes the assumed off-hand")

bags[0][1] = nil                                -- no owned off-hand -> judge the 1H alone
local t2 = tipFor(700003)
check(t2:find("%(70 vs 100%)") ~= nil, "no owned off-hand -> 1H judged alone (70 vs 100)  [" .. clean(t2) .. "]")
bags[0][1] = 700002

SlashCmdList["BISBUDDY"]("lockoh " .. linkFor(700004))
check(BisBuddyDB.lockOffHand and BisBuddyDB.lockOffHand.id == 700004, "/bb lockoh pins an off-hand")
local t3 = tipFor(700003)                        -- locked OH (60) overrides auto (40): (70+60)=130
check(t3:find("%(130 vs 100%)") ~= nil, "locked off-hand overrides auto: (130 vs 100)  [" .. clean(t3) .. "]")
check(t3:find("locked") ~= nil, "tooltip flags the off-hand as locked")
SlashCmdList["BISBUDDY"]("lockoh off")
check(BisBuddyDB.lockOffHand == nil, "/bb lockoh off clears the lock")

equipped[16] = nil                               -- no 2H equipped -> pairing must NOT apply
ev.scripts.OnEvent(ev, "PLAYER_EQUIPMENT_CHANGED")
local t4 = tipFor(700003)
check(t4:find("as 1H %+") == nil, "no 2H equipped -> no off-hand pairing")

-- ============================================================================
-- Curated supplement (Extras) -- bisbeard-missing items
-- ============================================================================
for s = 1, 18 do equipped[s] = nil end           -- empty trinkets so an extra trinket is a clear upgrade
ev.scripts.OnEvent(ev, "PLAYER_EQUIPMENT_CHANGED")
registry[800001] = { equipLoc = "INVTYPE_TRINKET", stats = { ITEM_MOD_SPELL_POWER_SHORT = 5000 } } -- the "seal" bisbeard lacks
GameTooltip.currentLink = linkFor(800001)
SlashCmdList["BISBUDDY"]("extra save")
local capLine = lastChat(2)
check(capLine:find("%[800001%] = {") ~= nil, "/bb extra prints a paste-ready Extras line")
check(capLine:find("sp = 5000") ~= nil, "captured line carries the item's stats")
check(capLine:find('slot = "Trinket"') ~= nil, "captured line carries the slot")
check(BisBuddyDB.userExtras and BisBuddyDB.userExtras[800001] ~= nil, "/bb extra save persists the extra")

local te = tipFor(800001)                         -- now ranks + tagged Extra on its tooltip
check(clean(te):find("Extra:") ~= nil, "supplement item is tagged 'Extra' on its tooltip  [" .. clean(te) .. "]")
check(te:find("BiS Trinket") ~= nil, "supplement item ranks as BiS for its slot")

SlashCmdList["BISBUDDY"]("extra clear")
local te2 = tipFor(800001)
check(clean(te2):find("Extra:") == nil, "/bb extra clear un-ranks the supplement item")

print(allOK and "\nALL TESTS PASSED" or "\nSOME TESTS FAILED")
os.exit(allOK and 0 or 1)
