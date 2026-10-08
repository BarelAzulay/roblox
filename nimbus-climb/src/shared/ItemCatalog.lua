-- ItemCatalog: the usable consumables sold in the lobby item shop and bound to the hotbar (keys 1-3).
-- Pure data, safe on server and client. Plain Lua 5.1-compatible syntax only.
--
--   ItemDef = { Id, Name, Blurb, Price (cloud tokens), Glyph (short symbol for the slot), Color, Rarity }
--   ItemCatalog.List      array in hotbar order: heal_cloud, shield_bubble, phoenix_feather
--   ItemCatalog.ById      map id -> ItemDef
--   ItemCatalog.Get(id)   -> ItemDef|nil
--
-- The effects themselves (40% heal, 8 s shield, revive at 50%) live in ItemService; the numbers
-- are repeated in the Blurb text so the UI can describe them. Rarity is a Config.Rarities id, so
-- CloudUI.RarityColor(def.Rarity) tints the slot border.

local ItemCatalog = {}

local function C(r, g, b)
	return Color3.fromRGB(r, g, b)
end

ItemCatalog.List = {
	{
		Id = "heal_cloud",
		Name = "Heal Cloud",
		Blurb = "A fluffy little cloud that heals 40% of your max health. Match only.",
		Price = 30,
		Glyph = "\226\153\165", -- U+2665 heart
		Color = C(118, 206, 148),
		Rarity = "Common",
	},
	{
		Id = "shield_bubble",
		Name = "Shield Bubble",
		Blurb = "Wrap yourself in a bubble: nothing can hurt you for 8 seconds. Match only.",
		Price = 45,
		Glyph = "\226\151\142", -- U+25CE bullseye ring
		Color = C(104, 176, 232),
		Rarity = "Uncommon",
	},
	{
		Id = "phoenix_feather",
		Name = "Phoenix Feather",
		Blurb = "Instantly revives the nearest downed teammate with 50% health. Only used up if someone was revived.",
		Price = 150,
		Glyph = "\226\156\166", -- U+2726 four-pointed star
		Color = C(236, 142, 70),
		Rarity = "Rare",
	},
}

ItemCatalog.ById = {}
for _, def in ipairs(ItemCatalog.List) do
	ItemCatalog.ById[def.Id] = def
end

function ItemCatalog.Get(id)
	if type(id) ~= "string" then
		return nil
	end
	return ItemCatalog.ById[id]
end

return ItemCatalog
