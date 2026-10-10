-- PetKeys: per-copy pet keys (ARCHITECTURE_V3.md "Phase 2 build contract", "Pet keys" + section 11).
-- Pure data + logic: no Instances, safe on the server, the client and inside the save code.
-- Plain Lua 5.1-compatible syntax only.
--
-- A pet COPY is identified by a key string:
--   "<petId>"              a Normal copy          (old profiles: every plain petId is a valid key)
--   "<petId>@Golden"       a Golden copy          (x1.5 stats / perks, gold finish)
--   "<petId>@Rainbow"      a Rainbow copy         (x2.5 stats / perks, rainbow shimmer)
--   "hyb:<uid>"            a fused hybrid         (may also carry "@Golden" / "@Rainbow")
-- Keys are canonical: "cat@Normal" is not a key (Normal copies have no suffix), petIds and hybrid uids only use
-- letters, digits, "_" and "-" (so a key never contains ",", ";", "=", "/" or spaces and fits a csv attribute).
--
-- Where copies live in a profile (or in the client's ProfileSync snapshot, which has the same shape):
--   Pets[petId]     = count                                      Normal copies (unchanged since v2)
--   Tiers[petId]    = { Golden = n, Rainbow = n }                tier copies
--   Hybrids[uid]    = { Body = petId, Style = petId, Elements = {...}, Name, Rarity, Tier }
--                     ONE unique creature per uid. Its key is "hyb:<uid>" plus the record's Tier suffix, so
--                     Count("hyb:<uid>@Golden") is 1 only while the record's Tier is "Golden".
--
-- API (the contract):
--   PetKeys.Parse(key) -> { Key, PetId, Tier, HybridId } | nil      nil for anything that is not a canonical key.
--                         Tier is "Normal" | "Golden" | "Rainbow"; PetId is nil for hybrids, HybridId nil otherwise.
--   PetKeys.Make(petId, tier) -> key | nil                           Make("cat", "Golden") -> "cat@Golden";
--                         tier nil / "Normal" -> "cat"; petId may also be "hyb:<uid>" or a key (its tier is replaced)
--   PetKeys.Count(profile, key) -> n                                 copies owned (0 for junk)
--   PetKeys.Add(profile, key, n [, record]) -> ok                    n defaults to 1; refuses (false, nothing changed)
--                         junk, unknown catalog pets and stacks above Config.Pets.MaxPerStack. A hybrid key needs n = 1
--                         and `record` ({Body, Style, Elements, Name, Rarity, ...}); its uid must be free.
--   PetKeys.Remove(profile, key, n) -> ok                            never below 0: false (nothing changed) when fewer
--                         than n copies are owned. Removing a hybrid key deletes its record. Empty entries are cleaned.
--   PetKeys.List(profile) -> { key... }                              every owned key (count > 0) that DefOf can
--                         describe, in catalog order (rarity, then name; Normal, Golden, Rainbow), hybrids last by name
--   PetKeys.DefOf(key, profile) -> def | nil                         the catalog def for a Normal key; a derived def
--                         for tiers (Look.Finish = "Golden" | "Rainbow"); a merged def for hybrids (needs `profile`, or
--                         anything with a `Hybrids` table, for the record). Treat every def as READ-ONLY (shared/cached).
--   PetKeys.StatMultiplier(tier) -> 1 | 1.5 | 2.5                     also accepts a key ("cat@Golden" -> 1.5)
--
-- Derived defs (tiers and hybrids) carry every PetDef field PetBuilder / the menus read, plus:
--   Id = Key = the key (so PetBuilder caches every variant on its own), PetId (catalog id; nil for hybrids),
--   Tier, StatMultiplier, DisplayName ("Golden Pebble Pup"), and for hybrids IsHybrid = true, HybridId, Body, Style,
--   Elements (deduplicated, both parents' when the record has none), BodyDef / StyleDef (the parents' catalog defs);
--   tier defs also CatalogDef (the Normal def). Stats / Perks / Special.Power are the BASE values
--   (tier not applied): callers multiply by StatMultiplier(tier) like they scale by level.
-- Hybrid merge rules (section 11 + the Phase 2 contract): the FIRST parent (Body) gives the species, body colour
--   (Primary) and eyes, the special and the shape; the SECOND (Style) gives Secondary, the wings (style + colour), the
--   accessory (the Body's when the Style has none) and its element (Elements = both, deduplicated). Rarity = the
--   higher of the two (or the record's), Stats and Perks = the parents' average x1.2, Role from the merged stats,
--   Name = the record's or a blend of both names ("Pip Penguin" + "Ember Phoenix" -> "Pengnix").
--
-- Extras (nothing depends on them): Tiers, TierMultiplier, HybridPrefix, HybridStatBonus, Base(key), TierOf(key),
--   NextTier(tier), HybridKey(uid, tier), IsHybridKey(key), ValidHybridId(uid), NewHybridId(profile, seed),
--   BlendName(nameA, nameB), DisplayName(key, profile), CleanHybrid(record), Owned(profile) -> { [key] = n }.

local PetKeys = {}

local Shared = script.Parent
local Config = require(Shared.Config)

PetKeys.Tiers = { "Normal", "Golden", "Rainbow" }
PetKeys.TierMultiplier = { Normal = 1, Golden = 1.5, Rainbow = 2.5 }
PetKeys.HybridPrefix = "hyb:"
PetKeys.HybridStatBonus = 1.2 -- section 11: a hybrid's stats are its parents' average x1.2
PetKeys.MaxKeyLength = 48 -- DataService refuses longer keys
PetKeys.MaxHybridIdLength = 24

local TIER_INDEX = { Normal = 1, Golden = 2, Rainbow = 3 }
local NEXT_TIER = { Normal = "Golden", Golden = "Rainbow" }
local MAX_PET_ID_LENGTH = 40 -- leaves room for "@Rainbow" inside MaxKeyLength
local MAX_NAME_LENGTH = 32
local DEF_CACHE_LIMIT = 256

----------------------------------------------------------------------
-- PetCatalog (resolved lazily: it requires Config only, but load order must never matter)
----------------------------------------------------------------------
local catalog = nil
local catalogResolved = false

local function getCatalog()
	if not catalogResolved then
		catalogResolved = true
		local module = Shared:FindFirstChild("PetCatalog")
		if module then
			local ok, result = pcall(require, module)
			if ok and type(result) == "table" then
				catalog = result
			else
				warn("[PetKeys] PetCatalog failed to load: " .. tostring(result))
			end
		end
	end
	return catalog
end

local function catalogDef(petId)
	local c = getCatalog()
	if not c or type(c.Get) ~= "function" then
		return nil
	end
	local ok, def = pcall(c.Get, petId)
	if ok and type(def) == "table" then
		return def
	end
	return nil
end

-- true when the catalog is loaded and does NOT know petId (without a catalog nothing is called unknown)
local function unknownPet(petId)
	local c = getCatalog()
	if not c or type(c.Get) ~= "function" then
		return false
	end
	return catalogDef(petId) == nil
end

local function maxStack()
	local pets = Config.Pets
	local n = type(pets) == "table" and tonumber(pets.MaxPerStack)
	if n and n >= 1 then
		return math.floor(n)
	end
	return 99
end

local function rarityOrder(rarityId)
	for _, r in ipairs(Config.Rarities or {}) do
		if r.Id == rarityId then
			return r.Order or 0
		end
	end
	return nil
end

----------------------------------------------------------------------
-- Keys
----------------------------------------------------------------------
local function validPetId(id)
	return type(id) == "string" and #id >= 1 and #id <= MAX_PET_ID_LENGTH and string.find(id, "^[%w_%-]+$") ~= nil
end

function PetKeys.ValidHybridId(uid)
	return type(uid) == "string" and #uid >= 1 and #uid <= PetKeys.MaxHybridIdLength and string.find(uid, "^[%w_%-]+$") ~= nil
end

local function validTier(tier)
	return type(tier) == "string" and TIER_INDEX[tier] ~= nil
end

-- key -> base ("cat" | "hyb:<uid>"), tier ("Normal" | ...) or nil when the suffix is not canonical
local function split(key)
	local base, tier = string.match(key, "^(.-)@([%w]+)$")
	if base == nil then
		return key, "Normal"
	end
	if tier ~= "Golden" and tier ~= "Rainbow" then
		return nil -- "@Normal" and unknown suffixes are not keys
	end
	return base, tier
end

function PetKeys.Parse(key)
	if type(key) ~= "string" or #key < 1 or #key > PetKeys.MaxKeyLength then
		return nil
	end
	local base, tier = split(key)
	if not base then
		return nil
	end
	local prefix = PetKeys.HybridPrefix
	if string.sub(base, 1, #prefix) == prefix then
		local uid = string.sub(base, #prefix + 1)
		if not PetKeys.ValidHybridId(uid) then
			return nil
		end
		return { Key = key, PetId = nil, Tier = tier, HybridId = uid }
	end
	if not validPetId(base) then
		return nil
	end
	return { Key = key, PetId = base, Tier = tier, HybridId = nil }
end

function PetKeys.Make(petId, tier)
	if tier == nil then
		tier = "Normal"
	end
	if not validTier(tier) then
		return nil
	end
	local parsed = PetKeys.Parse(petId)
	if not parsed then
		return nil
	end
	local base = parsed.PetId or (PetKeys.HybridPrefix .. parsed.HybridId)
	local key = base
	if tier ~= "Normal" then
		key = base .. "@" .. tier
	end
	if #key > PetKeys.MaxKeyLength then
		return nil
	end
	return key
end

function PetKeys.HybridKey(uid, tier)
	if not PetKeys.ValidHybridId(uid) then
		return nil
	end
	return PetKeys.Make(PetKeys.HybridPrefix .. uid, tier)
end

function PetKeys.Base(key)
	local parsed = PetKeys.Parse(key)
	if not parsed then
		return nil
	end
	return parsed.PetId or (PetKeys.HybridPrefix .. parsed.HybridId)
end

function PetKeys.TierOf(key)
	local parsed = PetKeys.Parse(key)
	return parsed and parsed.Tier or nil
end

function PetKeys.IsHybridKey(key)
	local parsed = PetKeys.Parse(key)
	return parsed ~= nil and parsed.HybridId ~= nil
end

function PetKeys.NextTier(tier)
	return NEXT_TIER[tier]
end

function PetKeys.StatMultiplier(tier)
	if tier == nil then
		return 1
	end
	local m = PetKeys.TierMultiplier[tier]
	if m then
		return m
	end
	local parsed = PetKeys.Parse(tier) -- a key
	if parsed then
		return PetKeys.TierMultiplier[parsed.Tier] or 1
	end
	return 1
end

----------------------------------------------------------------------
-- Hybrid records
----------------------------------------------------------------------
local function cleanName(name)
	if type(name) ~= "string" then
		return nil
	end
	name = string.gsub(name, "[%c]", "")
	name = string.match(name, "^%s*(.-)%s*$")
	if #name < 1 or #name > MAX_NAME_LENGTH then
		return nil
	end
	return name
end

local function validElementSet()
	local set = {}
	local E = Config.Elements
	for _, e in ipairs(type(E) == "table" and type(E.Order) == "table" and E.Order or {}) do
		set[e] = true
	end
	return set
end

local function cleanElements(list)
	local out = {}
	if type(list) ~= "table" then
		return out
	end
	local valid = validElementSet()
	local seen = {}
	for _, e in ipairs(list) do
		if type(e) == "string" and valid[e] and not seen[e] and #out < 4 then
			seen[e] = true
			out[#out + 1] = e
		end
	end
	return out
end

-- Untrusted record -> a clean copy { Body, Style, Elements, Name?, Rarity?, Tier } (plus extra scalar fields the
-- fusion code may keep, e.g. a look seed), or nil when Body / Style are not pet ids.
function PetKeys.CleanHybrid(raw)
	if type(raw) ~= "table" or not validPetId(raw.Body) or not validPetId(raw.Style) then
		return nil
	end
	local rec = {
		Body = raw.Body,
		Style = raw.Style,
		Elements = cleanElements(raw.Elements),
		Name = cleanName(raw.Name),
		Rarity = nil,
		Tier = validTier(raw.Tier) and raw.Tier or "Normal",
	}
	if type(raw.Rarity) == "string" and rarityOrder(raw.Rarity) then
		rec.Rarity = raw.Rarity
	end
	local extras = 0
	for k, v in pairs(raw) do
		if rec[k] == nil and k ~= "Rarity" and k ~= "Name" and type(k) == "string" and #k <= 24 and extras < 8 then
			local t = type(v)
			if (t == "number" and v == v and v ~= math.huge and v ~= -math.huge) or t == "boolean" or (t == "string" and #v <= 64) then
				rec[k] = v
				extras = extras + 1
			end
		end
	end
	return rec
end

local function hybridRecord(profile, uid)
	local hybrids = type(profile) == "table" and profile.Hybrids
	local rec = type(hybrids) == "table" and hybrids[uid]
	if type(rec) == "table" then
		return rec
	end
	return nil
end

local function recordTier(rec)
	if validTier(rec.Tier) then
		return rec.Tier
	end
	return "Normal"
end

-- A uid not used by profile.Hybrids yet ("h" + base-36 digits). `seed` (number) varies the start.
function PetKeys.NewHybridId(profile, seed)
	local hybrids = type(profile) == "table" and type(profile.Hybrids) == "table" and profile.Hybrids or {}
	local digits = "0123456789abcdefghijklmnopqrstuvwxyz"
	local n = math.floor(tonumber(seed) or os.time()) % 2176782336 -- 36^6
	if n < 0 then
		n = -n
	end
	for _ = 1, 1000 do
		local v, s = n, ""
		repeat
			local d = v % 36
			s = string.sub(digits, d + 1, d + 1) .. s
			v = math.floor(v / 36)
		until v == 0
		local uid = "h" .. s
		if hybrids[uid] == nil then
			return uid
		end
		n = (n + 7919) % 2176782336
	end
	return nil
end

----------------------------------------------------------------------
-- Counting, adding, removing
----------------------------------------------------------------------
local function count(v)
	if type(v) == "number" and v == v and v > 0 and v ~= math.huge then
		return math.floor(v)
	end
	return 0
end

function PetKeys.Count(profile, key)
	if type(profile) ~= "table" then
		return 0
	end
	local parsed = PetKeys.Parse(key)
	if not parsed then
		return 0
	end
	if parsed.HybridId then
		local rec = hybridRecord(profile, parsed.HybridId)
		if rec and recordTier(rec) == parsed.Tier then
			return 1
		end
		return 0
	end
	if parsed.Tier == "Normal" then
		local pets = profile.Pets
		return type(pets) == "table" and count(pets[parsed.PetId]) or 0
	end
	local tiers = profile.Tiers
	local entry = type(tiers) == "table" and tiers[parsed.PetId]
	return type(entry) == "table" and count(entry[parsed.Tier]) or 0
end

local function ensure(holder, field)
	local t = holder[field]
	if type(t) ~= "table" then
		t = {}
		holder[field] = t
	end
	return t
end

local function wholeAmount(n)
	if n == nil then
		return 1
	end
	if type(n) ~= "number" or n ~= n or n < 1 or n == math.huge or n ~= math.floor(n) then
		return nil
	end
	return n
end

function PetKeys.Add(profile, key, n, record)
	if type(profile) ~= "table" then
		return false
	end
	local amount = wholeAmount(n)
	local parsed = PetKeys.Parse(key)
	if not amount or not parsed then
		return false
	end
	if parsed.HybridId then
		if amount ~= 1 or hybridRecord(profile, parsed.HybridId) then
			return false -- a hybrid is one unique creature; its uid must be free
		end
		local rec = PetKeys.CleanHybrid(record)
		if not rec then
			return false
		end
		rec.Tier = parsed.Tier
		ensure(profile, "Hybrids")[parsed.HybridId] = rec
		return true
	end
	if unknownPet(parsed.PetId) then
		return false
	end
	local have = PetKeys.Count(profile, key)
	if have + amount > maxStack() then
		return false
	end
	if parsed.Tier == "Normal" then
		ensure(profile, "Pets")[parsed.PetId] = have + amount
	else
		local entry = ensure(ensure(profile, "Tiers"), parsed.PetId)
		entry[parsed.Tier] = have + amount
	end
	return true
end

function PetKeys.Remove(profile, key, n)
	if type(profile) ~= "table" then
		return false
	end
	local amount = wholeAmount(n)
	local parsed = PetKeys.Parse(key)
	if not amount or not parsed then
		return false
	end
	local have = PetKeys.Count(profile, key)
	if have < amount then
		return false
	end
	if parsed.HybridId then
		profile.Hybrids[parsed.HybridId] = nil
		return true
	end
	local left = have - amount
	if parsed.Tier == "Normal" then
		if left > 0 then
			profile.Pets[parsed.PetId] = left
		else
			profile.Pets[parsed.PetId] = nil
		end
		return true
	end
	local entry = profile.Tiers[parsed.PetId]
	if left > 0 then
		entry[parsed.Tier] = left
	else
		entry[parsed.Tier] = nil
		if next(entry) == nil then
			profile.Tiers[parsed.PetId] = nil
		end
	end
	return true
end

-- Extra: { [key] = count } of every owned copy (junk entries skipped; no catalog check).
function PetKeys.Owned(profile)
	local out = {}
	if type(profile) ~= "table" then
		return out
	end
	for petId, n in pairs(type(profile.Pets) == "table" and profile.Pets or {}) do
		if validPetId(petId) and count(n) > 0 then
			out[petId] = count(n)
		end
	end
	for petId, entry in pairs(type(profile.Tiers) == "table" and profile.Tiers or {}) do
		if validPetId(petId) and type(entry) == "table" then
			for _, tier in ipairs({ "Golden", "Rainbow" }) do
				if count(entry[tier]) > 0 then
					out[petId .. "@" .. tier] = count(entry[tier])
				end
			end
		end
	end
	for uid, rec in pairs(type(profile.Hybrids) == "table" and profile.Hybrids or {}) do
		local key = type(rec) == "table" and PetKeys.HybridKey(uid, recordTier(rec))
		if key then
			out[key] = 1
		end
	end
	return out
end

----------------------------------------------------------------------
-- Definitions
----------------------------------------------------------------------
local defCache = {} -- [signature] = derived def
local defCacheSize = 0

local function cachePut(sig, def)
	if defCacheSize >= DEF_CACHE_LIMIT then
		defCache = {}
		defCacheSize = 0
	end
	defCache[sig] = def
	defCacheSize = defCacheSize + 1
	return def
end

local function shallowCopy(t)
	local out = {}
	for k, v in pairs(t) do
		out[k] = v
	end
	return out
end

-- "Pip Penguin" + "Ember Phoenix" -> "Pengnix": the front half of the first name's last word (usually the creature)
-- and the back half of the second name's last word, capitalised. When both end in the same word ("Cloudy Dragon" +
-- "Twilight Dragon") the first name's FIRST word is used instead ("Clogon"); words of 3 letters or fewer are used
-- whole ("Biscuit Bear" + "Aurora Fox" -> "Befox").
function PetKeys.BlendName(a, b)
	local lastA = type(a) == "string" and string.match(a, "([%a]+)[^%a]*$") or nil
	local firstA = type(a) == "string" and string.match(a, "^[^%a]*([%a]+)") or nil
	local last = type(b) == "string" and string.match(b, "([%a]+)[^%a]*$") or nil
	local first = lastA
	if first and last and string.lower(first) == string.lower(last) and firstA then
		first = firstA
	end
	if not first and not last then
		return "Fusion"
	end
	first = first or last
	last = last or first
	-- short words (3 letters or fewer: "Pup", "Fox", "Owl") are used whole, longer ones by half
	local front = first
	if #first > 3 then
		front = string.sub(first, 1, math.ceil(#first / 2))
	end
	local back = last
	if #last > 3 then
		back = string.sub(last, #last - math.floor(#last / 2) + 1)
	end
	local name = string.lower(front .. back)
	return string.upper(string.sub(name, 1, 1)) .. string.sub(name, 2)
end

local function tierLabel(tier, name)
	if tier == "Normal" then
		return name
	end
	return tier .. " " .. tostring(name)
end

local function tierDef(base, key, tier)
	local sig = "t|" .. key
	local cached = defCache[sig]
	if cached and cached.CatalogDef == base then
		return cached
	end
	local def = shallowCopy(base)
	def.CatalogDef = base -- the catalog def it was derived from
	def.Id = key
	def.Key = key
	def.PetId = base.Id
	def.Tier = tier
	def.StatMultiplier = PetKeys.TierMultiplier[tier] or 1
	def.DisplayName = tierLabel(tier, base.Name)
	local look = shallowCopy(type(base.Look) == "table" and base.Look or {})
	look.Finish = tier
	def.Look = look
	return cachePut(sig, def)
end

local function average(a, b, bonus)
	local out = {}
	for k, v in pairs(type(a) == "table" and a or {}) do
		if type(v) == "number" then
			out[k] = v
		end
	end
	for k, v in pairs(type(b) == "table" and b or {}) do
		if type(v) == "number" then
			out[k] = (out[k] or 0) + v
		end
	end
	for k, v in pairs(out) do
		out[k] = v / 2 * bonus
	end
	return out
end

local function higherRarity(a, b)
	local oa, ob = rarityOrder(a) or 0, rarityOrder(b) or 0
	if ob > oa then
		return b
	end
	return a
end

local function hybridDef(key, parsed, rec)
	local body = catalogDef(rec.Body)
	local style = catalogDef(rec.Style)
	if not body and not style then
		return nil
	end
	body = body or style
	style = style or body
	local tier = parsed.Tier
	local elementsKey = table.concat(type(rec.Elements) == "table" and rec.Elements or {}, "+")
	local sig = table.concat({ "h", key, rec.Body, rec.Style, tostring(rec.Name), tostring(rec.Rarity), elementsKey, tostring(rec.Seed) }, "|")
	local cached = defCache[sig]
	if cached and cached.BodyDef == body and cached.StyleDef == style then
		return cached
	end

	local bl = type(body.Look) == "table" and body.Look or {}
	local sl = type(style.Look) == "table" and style.Look or {}
	local look = {
		Species = bl.Species,
		Primary = bl.Primary,
		Eye = bl.Eye,
		Secondary = sl.Secondary or bl.Secondary,
		WingStyle = sl.WingStyle or bl.WingStyle,
		WingColor = sl.WingColor or bl.WingColor,
		Accessory = sl.Accessory or bl.Accessory,
		Glow = bl.Glow == true or sl.Glow == true,
		Hybrid = true,
		BodyId = body.Id,
		StyleId = style.Id,
		Seed = rec.Seed,
	}
	if tier ~= "Normal" then
		look.Finish = tier
	end

	local elements = cleanElements(rec.Elements)
	if #elements == 0 then
		elements = cleanElements({ body.Element, style.Element })
	end
	local rarity = rec.Rarity
	if type(rarity) ~= "string" or not rarityOrder(rarity) then
		rarity = higherRarity(body.Rarity, style.Rarity)
	end
	local bonus = PetKeys.HybridStatBonus
	local stats = average(body.Stats, style.Stats, bonus)
	local role = body.Role
	if type(stats.Income) == "number" and type(stats.Power) == "number" then
		role = (stats.Income > stats.Power) and "Economy" or "Combat"
	end
	local special = nil
	if type(body.Special) == "table" then
		special = shallowCopy(body.Special)
	end
	local name = cleanName(rec.Name) or PetKeys.BlendName(body.Name, style.Name)

	local def = {
		Id = key,
		Key = key,
		PetId = nil,
		IsHybrid = true,
		HybridId = parsed.HybridId,
		Body = body.Id,
		Style = style.Id,
		BodyDef = body,
		StyleDef = style,
		Name = name,
		DisplayName = tierLabel(tier, name),
		Rarity = rarity,
		Blurb = "A fusion of " .. tostring(body.Name) .. " and " .. tostring(style.Name) .. ".",
		Look = look,
		Perks = average(body.Perks, style.Perks, bonus),
		Role = role,
		Stats = stats,
		Special = special,
		Element = elements[1],
		Elements = elements,
		Tier = tier,
		StatMultiplier = PetKeys.TierMultiplier[tier] or 1,
	}
	return cachePut(sig, def)
end

function PetKeys.DefOf(key, profile)
	local parsed = PetKeys.Parse(key)
	if not parsed then
		return nil
	end
	if parsed.HybridId then
		local rec = hybridRecord(profile, parsed.HybridId)
		if not rec or not validPetId(rec.Body) or not validPetId(rec.Style) then
			return nil
		end
		return hybridDef(key, parsed, rec)
	end
	local base = catalogDef(parsed.PetId)
	if not base then
		return nil
	end
	if parsed.Tier == "Normal" then
		return base
	end
	return tierDef(base, key, parsed.Tier)
end

function PetKeys.DisplayName(key, profile)
	local def = PetKeys.DefOf(key, profile)
	if not def then
		return nil
	end
	return def.DisplayName or def.Name
end

----------------------------------------------------------------------
-- Listing
----------------------------------------------------------------------
local function catalogPosition()
	local pos = {}
	local c = getCatalog()
	if c and type(c.Pets) == "table" then
		for i, def in ipairs(c.Pets) do
			if type(def) == "table" and def.Id ~= nil then
				pos[def.Id] = i
			end
		end
	end
	return pos
end

function PetKeys.List(profile)
	local owned = PetKeys.Owned(profile)
	local pos = catalogPosition()
	local hasCatalog = next(pos) ~= nil
	local plain, hybrids = {}, {}
	for key in pairs(owned) do
		local parsed = PetKeys.Parse(key)
		if parsed and parsed.HybridId then
			local def = PetKeys.DefOf(key, profile)
			if def then
				hybrids[#hybrids + 1] = { Key = key, Name = def.Name, Order = rarityOrder(def.Rarity) or 0 }
			end
		elseif parsed and (not hasCatalog or pos[parsed.PetId]) then
			plain[#plain + 1] = { Key = key, Pos = pos[parsed.PetId] or math.huge, PetId = parsed.PetId, Tier = TIER_INDEX[parsed.Tier] }
		end
	end
	table.sort(plain, function(a, b)
		if a.Pos ~= b.Pos then
			return a.Pos < b.Pos
		end
		if a.PetId ~= b.PetId then
			return a.PetId < b.PetId
		end
		return a.Tier < b.Tier
	end)
	table.sort(hybrids, function(a, b)
		if a.Order ~= b.Order then
			return a.Order < b.Order
		end
		if a.Name ~= b.Name then
			return a.Name < b.Name
		end
		return a.Key < b.Key
	end)
	local out = {}
	for _, e in ipairs(plain) do
		out[#out + 1] = e.Key
	end
	for _, e in ipairs(hybrids) do
		out[#out + 1] = e.Key
	end
	return out
end

return PetKeys
