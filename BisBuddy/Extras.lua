-- BisBuddy curated supplement.
--
-- Items BisBeard (coa.bisbeard.com) doesn't index but that are real, usable
-- gear on Ascension: quest / class-book rewards, custom items, world drops the
-- BiS site simply never scored. Anything listed here is merged into the ranked
-- lists, shown on tooltips as "Extra: #N BiS", and included in farm-next -- it
-- is scored per-spec with the same stat weights as bisbeard's own items, so a
-- caster trinket ranks high for casters and low for melee automatically.
--
-- HOW TO ADD AN ITEM (takes ~5 seconds in-game):
--   1. Hover the item anywhere (bag, vendor, dungeon journal, chat link).
--   2. Type  /bb extra        -> pops a copyable, ready-to-paste line.
--      or    /bb extra save   -> also saves it to YOUR character immediately
--                                (personal, persists) AND prints the line to
--                                share so it can be baked in here for everyone.
--   3. Paste the line into the table below (between the { } ).
--
-- FORMAT:  [itemId] = { name = "...", slot = "...", stats = { code = val, ... }, source = "...", class = "..." },
--   slot   : a BisBeard slot name --
--            Head Neck Shoulders Back Chest Wrists Hands Waist Legs Feet
--            Finger Trinket Ranged
--            "Main Hand" "One-Hand" "Two-Hand" "Off Hand" Shield "Held In Off-hand"
--   stats  : short codes (same as Data.lua) --
--            int str agi sta spi sp hp cr ht hit res exp ap rap fap arp spen
--            mp5 hp5 def dg par blk bv sbv arm   and  dps (weapon/ranged dps)
--            (resistances etc. don't affect scoring, so they can be omitted)
--   source : shown on the tooltip (optional)
--   class  : restrict to a single class name, e.g. "Tinker" (optional; OMIT for
--            items everyone can use -- correct for Ascension class-book rewards,
--            which are unlocked for all classes)

BisBuddyExtras = {

	-- Enchanted Seal of Eldre'Thalas -- Dire Maul class-book reward (~30 spell
	-- power / 10 fire resist), usable by everyone on Ascension. BisBeard doesn't
	-- list it. Hover it in-game and run  /bb extra  to fill in the real item id
	-- and exact stats, then uncomment the line below (fire res is cosmetic here):
	--
	-- [00000] = { name = "Enchanted Seal of Eldre'Thalas", slot = "Trinket", stats = { sp = 30 }, source = "Dire Maul class book" },

}
