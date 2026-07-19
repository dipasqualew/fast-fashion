local _, ns = ...

---The shared outfit model. Blizzard sets and, later, community submissions both land
---here, so nothing downstream of a provider needs to know where an outfit came from.
---
---An outfit is canonical and character-independent: it describes a *look*, never one
---character's relationship to it. Everything derived from the logged-in character —
---collected, usable, missing — belongs on ResolvedOutfit and is recomputed, never stored.
---@class Outfit
---@field id string Stable across sessions; "blizzard:1234" for a Blizzard set.
---@field origin OutfitOrigin
---@field name string
---@field description string?
---@field blizzardSetID number?
---@field baseSetID number? Set this outfit is a variant or recolour of; nil when it is the base.
---@field expansionID number?
---@field patchID number?
---@field classMask number? Bitmask of the classes the set was *originally* restricted to.
---@field requiredFaction string? "Alliance", "Horde", or nil for neither.
---@field originallyValidForCharacter boolean? The game's answer to the original restriction only.
---@field tags string[]
---@field slots OutfitSlot[] Ordered by inventory slot, one entry per slot.

---@alias OutfitOrigin "blizzard" | "community"

---One inventory slot of an outfit.
---
---`appearanceID` is the canonical identity: the visual, not the item that happens to carry
---it. The preferred source and item are hints for reproducing the look, kept because the
---Blizzard set names a specific item and that item is the best first guess — but any other
---source sharing the visual is an equally valid way to wear it.
---@class OutfitSlot
---@field inventorySlot number Equipment slot index, e.g. 1 = head.
---@field appearanceID number Visual appearance ID (`visualID`), the canonical slot identity.
---@field preferredSourceID number?
---@field preferredItemID number?

---A character's relationship to an outfit, recomputed per character and never persisted.
---@class ResolvedOutfit
---@field outfit Outfit
---@field wearable boolean Every required slot has at least one source usable by this character.
---@field collectedCount number
---@field missingCount number
---@field totalCount number
---@field slots ResolvedOutfitSlot[]

---@class ResolvedOutfitSlot
---@field appearanceID number
---@field resolvedSourceID number?
---@field collected boolean
---@field usable boolean
---@field missing boolean

---Where outfits come from. The gallery talks only to this interface, so adding community
---outfits later is a matter of registering another provider.
---@class OutfitProvider
---@field getOutfits fun(): Outfit[]
---@field getOutfit fun(id: string): Outfit?

ns.OUTFIT_ORIGIN_BLIZZARD = "blizzard"
ns.OUTFIT_ORIGIN_COMMUNITY = "community"

---Outfit IDs are namespaced by origin so a Blizzard set and a community outfit can never
---collide once both providers are live.
---@param origin OutfitOrigin
---@param key string|number
---@return string
function ns.outfitId(origin, key)
    return origin .. ":" .. tostring(key)
end
