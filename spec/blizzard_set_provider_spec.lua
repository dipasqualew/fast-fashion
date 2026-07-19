local loader = require("addon_loader")
local fake = require("fake_wow")

describe("ns.newBlizzardSetProvider", function()
    local ns = loader.load()

    local SET_ID = 1234
    local OUTFIT_ID = "blizzard:1234"

    ---@param overrides table?
    ---@return TransmogSetInfo
    local function set(overrides)
        local info = { setID = SET_ID, name = "Judgement Armor" }
        for key, value in pairs(overrides or {}) do
            info[key] = value
        end
        return info
    end

    ---One entry of a set's item list. `itemModifiedAppearanceID` is a *sourceID* despite
    ---the name, which is exactly the confusion these tests exist to pin down.
    ---@param sourceID number
    ---@param overrides table?
    ---@return TransmogSetItemInfo
    local function item(sourceID, overrides)
        local entry = { itemID = sourceID * 10, itemModifiedAppearanceID = sourceID }
        for key, value in pairs(overrides or {}) do
            entry[key] = value
        end
        return entry
    end

    ---@param visualID number?
    ---@param overrides table?
    ---@return AppearanceSourceInfo
    local function source(visualID, overrides)
        local info = { visualID = visualID }
        for key, value in pairs(overrides or {}) do
            info[key] = value
        end
        return info
    end

    ---Builds a provider over a fake client. The config table is handed back so a test can
    ---mutate it mid-run and model data streaming in after a failed read.
    ---@param config table? `{ sets, items, sources }`
    ---@return BlizzardSetProvider provider
    ---@return table recorded
    ---@return table config the very table the fake keeps reading
    local function newProvider(config)
        config = config or {}
        local api, recorded = fake.newTransmogApi(config)
        return ns.newBlizzardSetProvider({ api = api }), recorded, config
    end

    ---A provider over one set whose items and sources are all resolvable.
    ---@param items TransmogSetItemInfo[]
    ---@param sources table<number, AppearanceSourceInfo>
    ---@return BlizzardSetProvider provider, table recorded, table config
    local function newProviderWithSlots(items, sources)
        return newProvider({
            sets = { set() },
            items = { [SET_ID] = items },
            sources = sources,
        })
    end

    ---@param slots OutfitSlot[]
    ---@return number[]
    local function inventorySlotsOf(slots)
        local list = {}
        for index, slot in ipairs(slots) do
            list[index] = slot.inventorySlot
        end
        return list
    end

    it("is exported by the addon files", function()
        assert.is_function(ns.newBlizzardSetProvider)
    end)

    describe("converting a Blizzard set into an Outfit", function()
        ---Everything the client can tell us about a set, in one row.
        local FULL = {
            setID = SET_ID,
            name = "Judgement Armor",
            description = "Tier 2 Paladin",
            label = "Vanilla Raid",
            expansionID = 0,
            patchID = 10200,
            classMask = 2,
            requiredFaction = "Horde",
            validForCharacter = true,
            uiOrder = 7,
        }

        ---@return Outfit
        local function onlyOutfit(overrides)
            local provider = newProvider({ sets = { set(overrides or FULL) } })
            local outfits = provider.getOutfits()
            assert.equal(1, #outfits)
            return outfits[1]
        end

        ---@type { field: string, expected: any }[]
        local cases = {
            { field = "id", expected = OUTFIT_ID },
            { field = "origin", expected = "blizzard" },
            { field = "name", expected = "Judgement Armor" },
            { field = "description", expected = "Tier 2 Paladin" },
            { field = "blizzardSetID", expected = SET_ID },
            { field = "expansionID", expected = 0 },
            { field = "patchID", expected = 10200 },
            { field = "classMask", expected = 2 },
            { field = "requiredFaction", expected = "Horde" },
            { field = "originallyValidForCharacter", expected = true },
        }

        for _, case in ipairs(cases) do
            it("maps " .. case.field, function()
                assert.equal(case.expected, onlyOutfit()[case.field])
            end)
        end

        -- The ID is namespaced at construction so a community outfit can never collide
        -- with a Blizzard set once the second provider is live.
        it("namespaces the id as blizzard:<setID>", function()
            assert.equal(ns.outfitId("blizzard", SET_ID), onlyOutfit().id)
        end)

        -- "Alliance" / "Horde" arrive from the client as strings and stay strings; the
        -- model never converts them to a bitmask or a boolean.
        it("keeps requiredFaction as a string", function()
            assert.is_string(onlyOutfit().requiredFaction)
        end)

        it("carries no faction restriction when the client reports none", function()
            assert.is_nil(onlyOutfit({ setID = SET_ID, name = "Any" }).requiredFaction)
        end)

        it("starts every outfit with an empty tag list", function()
            assert.same({}, onlyOutfit().tags)
        end)

        -- Blizzard leaves `description` empty on plenty of sets and puts the useful
        -- string in `label` instead; a gallery row with a blank subtitle is the bug.
        it("falls back to label when the set has no description", function()
            local outfit = onlyOutfit({ setID = SET_ID, name = "Judgement", label = "Vanilla Raid" })

            assert.equal("Vanilla Raid", outfit.description)
        end)

        it("prefers the description over the label when both are present", function()
            assert.equal("Tier 2 Paladin", onlyOutfit().description)
        end)

        it("leaves the description absent when the client gives neither", function()
            assert.is_nil(onlyOutfit({ setID = SET_ID, name = "Judgement" }).description)
        end)

        ---@type { label: string, value: boolean? }[]
        local validity = {
            { label = "true", value = true },
            { label = "false", value = false },
        }

        for _, case in ipairs(validity) do
            it("records validForCharacter " .. case.label .. " as metadata only", function()
                local outfit = onlyOutfit({ setID = SET_ID, name = "Judgement", validForCharacter = case.value })

                assert.equal(case.value, outfit.originallyValidForCharacter)
            end)
        end
    end)

    describe("sets the gallery cannot show", function()
        ---@type { label: string, info: table }[]
        local skipped = {
            { label = "no name at all", info = { setID = SET_ID } },
            { label = "an empty name", info = { setID = SET_ID, name = "" } },
            { label = "no setID", info = { name = "Judgement Armor" } },
        }

        for _, case in ipairs(skipped) do
            it("skips a set with " .. case.label, function()
                local provider = newProvider({ sets = { case.info } })

                assert.same({}, provider.getOutfits())
            end)
        end

        it("keeps the usable sets when an unusable one sits between them", function()
            local provider = newProvider({
                sets = {
                    set({ setID = 1, name = "First" }),
                    { setID = 2 },
                    set({ setID = 3, name = "Third" }),
                },
            })

            local outfits = provider.getOutfits()

            assert.equal(2, #outfits)
            assert.equal("blizzard:1", outfits[1].id)
            assert.equal("blizzard:3", outfits[2].id)
        end)

        -- "Hidden until collected" is a state the gallery wants to *display*, not a
        -- reason to drop the row.
        it("keeps a hidden-until-collected set", function()
            local provider = newProvider({ sets = { set({ hiddenUntilCollected = true }) } })

            assert.equal(1, #provider.getOutfits())
        end)
    end)

    describe("building slots", function()
        local SOURCE_ID = 5555
        local ITEM_ID = SOURCE_ID * 10
        local VISUAL_ID = 77

        ---The single most important behaviour in the module: the slot's identity is the
        ---*visual*, resolved from the sourceID. Wearing the visual is what lets a Rogue
        ---reproduce a Druid set; the sourceID and itemID are only hints.
        it("resolves itemModifiedAppearanceID through getSourceInfo to a visualID", function()
            local provider = newProviderWithSlots(
                { item(SOURCE_ID, { invSlot = 1 }) },
                { [SOURCE_ID] = source(VISUAL_ID) }
            )

            local slots = provider.getOutfits()[1].slots

            assert.equal(1, #slots)
            assert.equal(VISUAL_ID, slots[1].appearanceID)
        end)

        it("never uses the sourceID as the appearance", function()
            local provider = newProviderWithSlots(
                { item(SOURCE_ID, { invSlot = 1 }) },
                { [SOURCE_ID] = source(VISUAL_ID) }
            )

            assert.not_equal(SOURCE_ID, provider.getOutfits()[1].slots[1].appearanceID)
        end)

        it("never uses the itemID as the appearance", function()
            local provider = newProviderWithSlots(
                { item(SOURCE_ID, { invSlot = 1 }) },
                { [SOURCE_ID] = source(VISUAL_ID) }
            )

            assert.not_equal(ITEM_ID, provider.getOutfits()[1].slots[1].appearanceID)
        end)

        it("keeps the listed source and item as hints for reproducing the look", function()
            local provider = newProviderWithSlots(
                { item(SOURCE_ID, { invSlot = 1 }) },
                { [SOURCE_ID] = source(VISUAL_ID, { sourceID = SOURCE_ID, itemID = ITEM_ID }) }
            )

            local slot = provider.getOutfits()[1].slots[1]

            assert.equal(SOURCE_ID, slot.preferredSourceID)
            assert.equal(ITEM_ID, slot.preferredItemID)
        end)

        it("orders slots by inventory slot however the client listed them", function()
            local provider = newProviderWithSlots({
                item(3, { invSlot = 5 }),
                item(1, { invSlot = 1 }),
                item(2, { invSlot = 3 }),
            }, {
                [1] = source(11),
                [2] = source(22),
                [3] = source(33),
            })

            assert.same({ 1, 3, 5 }, inventorySlotsOf(provider.getOutfits()[1].slots))
        end)

        it("falls back to the source's inventorySlot when the item entry has none", function()
            local provider = newProviderWithSlots(
                { item(SOURCE_ID) },
                { [SOURCE_ID] = source(VISUAL_ID, { inventorySlot = 7 }) }
            )

            assert.same({ 7 }, inventorySlotsOf(provider.getOutfits()[1].slots))
        end)

        it("prefers the item entry's invSlot over the source's", function()
            local provider = newProviderWithSlots(
                { item(SOURCE_ID, { invSlot = 1 }) },
                { [SOURCE_ID] = source(VISUAL_ID, { inventorySlot = 7 }) }
            )

            assert.same({ 1 }, inventorySlotsOf(provider.getOutfits()[1].slots))
        end)

        -- Nothing downstream can place a slotless piece on a character, and guessing a
        -- slot would put the wrong appearance on the preview.
        it("skips an entry no one can place, keeping the rest of the set", function()
            local provider = newProviderWithSlots({
                item(1, { invSlot = 1 }),
                item(2),
                item(3, { invSlot = 3 }),
            }, {
                [1] = source(11),
                [2] = source(22),
                [3] = source(33),
            })

            assert.same({ 1, 3 }, inventorySlotsOf(provider.getOutfits()[1].slots))
        end)

        -- Sets occasionally list two items for one slot (a recolour shipped alongside);
        -- taking the first keeps the outfit a single coherent look.
        it("keeps the first entry when two items claim the same slot", function()
            local provider = newProviderWithSlots({
                item(1, { invSlot = 1 }),
                item(2, { invSlot = 1 }),
            }, {
                [1] = source(11),
                [2] = source(22),
            })

            local slots = provider.getOutfits()[1].slots

            assert.equal(1, #slots)
            assert.equal(11, slots[1].appearanceID)
        end)

        it("gives a set with no items an outfit with no slots", function()
            local provider = newProviderWithSlots({}, {})

            assert.same({}, provider.getOutfits()[1].slots)
        end)

        -- An empty set is a resolved answer, not an unresolved one, so it must be cached
        -- like any other rather than re-queried on every read.
        it("caches the empty answer for a set with no items", function()
            local provider, recorded = newProviderWithSlots({}, {})

            assert.same({}, provider.getOutfits()[1].slots)
            assert.same({}, provider.getOutfits()[1].slots)

            assert.equal(1, #recorded.setAppearances)
        end)
    end)

    describe("data the client has not streamed in yet", function()
        local SOURCE_ID = 5555
        local VISUAL_ID = 77

        it("reads no slots while the set's appearances are unavailable", function()
            local provider = newProvider({ sets = { set() }, items = {} })

            assert.same({}, provider.getOutfits()[1].slots)
        end)

        it("reads no slots while a source is unresolved", function()
            local provider = newProvider({
                sets = { set() },
                items = { [SET_ID] = { item(SOURCE_ID, { invSlot = 1 }) } },
                sources = {},
            })

            assert.same({}, provider.getOutfits()[1].slots)
        end)

        -- A source row can arrive before its visual does. Half-resolved is unresolved.
        it("reads no slots while a source has no visualID yet", function()
            local provider = newProvider({
                sets = { set() },
                items = { [SET_ID] = { item(SOURCE_ID, { invSlot = 1 }) } },
                sources = { [SOURCE_ID] = source(nil, { inventorySlot = 1 }) },
            })

            assert.same({}, provider.getOutfits()[1].slots)
        end)

        it("drops the whole set rather than a partial look when one piece is unresolved", function()
            local provider = newProvider({
                sets = { set() },
                items = { [SET_ID] = { item(1, { invSlot = 1 }), item(2, { invSlot = 2 }) } },
                sources = { [1] = source(11) },
            })

            assert.same({}, provider.getOutfits()[1].slots)
        end)

        -- The retry is the point: an unresolved piece is not a missing piece, and caching
        -- the empty answer would freeze that lie in for the whole session.
        it("returns the real slots once the appearances arrive", function()
            local provider, _, config = newProvider({
                sets = { set() },
                items = {},
                sources = { [SOURCE_ID] = source(VISUAL_ID) },
            })
            assert.same({}, provider.getOutfits()[1].slots)

            config.items[SET_ID] = { item(SOURCE_ID, { invSlot = 1 }) }

            local slots = provider.getOutfits()[1].slots
            assert.equal(1, #slots)
            assert.equal(VISUAL_ID, slots[1].appearanceID)
        end)

        it("returns the real slots once the source arrives", function()
            local provider, _, config = newProvider({
                sets = { set() },
                items = { [SET_ID] = { item(SOURCE_ID, { invSlot = 1 }) } },
                sources = {},
            })
            assert.same({}, provider.getOutfits()[1].slots)

            config.sources[SOURCE_ID] = source(VISUAL_ID)

            assert.equal(VISUAL_ID, provider.getOutfits()[1].slots[1].appearanceID)
        end)

        it("asks the client again on every read until the data resolves", function()
            local provider, recorded = newProvider({ sets = { set() }, items = {} })

            local outfit = provider.getOutfits()[1]
            assert.same({}, outfit.slots)
            assert.same({}, outfit.slots)

            assert.equal(2, #recorded.setAppearances)
        end)
    end)

    describe("laziness", function()
        local SOURCE_ID = 5555

        ---@return BlizzardSetProvider provider, table recorded
        local function newLazyProvider()
            return newProviderWithSlots(
                { item(SOURCE_ID, { invSlot = 1 }) },
                { [SOURCE_ID] = source(77) }
            )
        end

        -- Listing the gallery costs one cheap metadata call; the expensive per-row work
        -- happens only as the player actually looks at a row.
        it("resolves nothing while merely listing the outfits", function()
            local provider, recorded = newLazyProvider()

            provider.getOutfits()

            assert.same({}, recorded.setAppearances)
            assert.same({}, recorded.sourceInfo)
        end)

        it("resolves the set the moment its slots are read", function()
            local provider, recorded = newLazyProvider()

            assert.is_table(provider.getOutfits()[1].slots)

            assert.same({ SET_ID }, recorded.setAppearances)
            assert.same({ SOURCE_ID }, recorded.sourceInfo)
        end)

        it("serves a second read from cache", function()
            local provider, recorded = newLazyProvider()
            local outfit = provider.getOutfits()[1]

            assert.is_table(outfit.slots)
            assert.is_table(outfit.slots)

            assert.equal(1, #recorded.setAppearances)
            assert.equal(1, #recorded.sourceInfo)
        end)

        it("caches per set rather than per outfit handle", function()
            local provider, recorded = newLazyProvider()

            assert.is_table(provider.getOutfits()[1].slots)
            assert.is_table(provider.getOutfit(OUTFIT_ID).slots)

            assert.equal(1, #recorded.setAppearances)
        end)

        it("reads the set list once and reuses it", function()
            local provider, recorded = newLazyProvider()

            provider.getOutfits()
            provider.getOutfits()

            assert.equal(1, recorded.allSets)
        end)
    end)

    describe("getOutfit", function()
        it("returns the outfit for a known id", function()
            local provider = newProvider({ sets = { set() } })

            assert.equal("Judgement Armor", provider.getOutfit(OUTFIT_ID).name)
        end)

        it("returns nothing for an id no set produced", function()
            local provider = newProvider({ sets = { set() } })

            assert.is_nil(provider.getOutfit("blizzard:9999"))
        end)

        it("returns nothing for an id from another origin", function()
            local provider = newProvider({ sets = { set() } })

            assert.is_nil(provider.getOutfit("community:1234"))
        end)

        -- The gallery may hand out an id before anything called getOutfits, so the
        -- lookup has to populate the index itself.
        it("builds the index on first use", function()
            local provider = newProvider({ sets = { set() } })

            assert.is_not_nil(provider.getOutfit(OUTFIT_ID))
        end)
    end)

    describe("baseSetID", function()
        -- Blizzard reports a base set's own ID as its baseSetID; the model reserves the
        -- field for "this is a variant *of* something else".
        it("is absent when the client points the set at itself", function()
            local provider = newProvider({ sets = { set({ baseSetID = SET_ID }) } })

            assert.is_nil(provider.getOutfits()[1].baseSetID)
        end)

        it("is absent when the client reports no base at all", function()
            local provider = newProvider({ sets = { set() } })

            assert.is_nil(provider.getOutfits()[1].baseSetID)
        end)

        it("is the real base for a variant", function()
            local provider = newProvider({ sets = { set({ setID = 2, name = "Recolour", baseSetID = 1 }) } })

            assert.equal(1, provider.getOutfits()[1].baseSetID)
        end)
    end)

    describe("getVariantsOf", function()
        ---A base set and two recolours, plus one unrelated set.
        ---@return BlizzardSetProvider
        local function newFamilyProvider()
            return newProvider({
                sets = {
                    set({ setID = 1, name = "Judgement", baseSetID = 1 }),
                    set({ setID = 2, name = "Judgement Recoloured", baseSetID = 1 }),
                    set({ setID = 3, name = "Judgement Recoloured Again", baseSetID = 1 }),
                    set({ setID = 9, name = "Bloodfang", baseSetID = 9 }),
                },
            })
        end

        ---@param outfits Outfit[]
        ---@return string[]
        local function idsOf(outfits)
            local ids = {}
            for index, outfit in ipairs(outfits) do
                ids[index] = outfit.id
            end
            return ids
        end

        it("lists the recolours of a base set", function()
            local provider = newFamilyProvider()

            assert.same({ "blizzard:2", "blizzard:3" }, idsOf(provider.getVariantsOf("blizzard:1")))
        end)

        -- Asking from a variant must give the same family, minus itself: the gallery does
        -- not know or care which row of a family the player clicked.
        it("lists the siblings and the base when asked from a variant", function()
            local provider = newFamilyProvider()

            assert.same({ "blizzard:1", "blizzard:3" }, idsOf(provider.getVariantsOf("blizzard:2")))
        end)

        it("never includes the outfit itself", function()
            local provider = newFamilyProvider()

            for _, outfit in ipairs(provider.getVariantsOf("blizzard:2")) do
                assert.not_equal("blizzard:2", outfit.id)
            end
        end)

        it("leaves other families out", function()
            local provider = newFamilyProvider()

            assert.same({}, idsOf(provider.getVariantsOf("blizzard:9")))
        end)

        it("returns nothing for an unknown id", function()
            local provider = newFamilyProvider()

            assert.same({}, provider.getVariantsOf("blizzard:404"))
        end)

        it("returns nothing when the client has no sets yet", function()
            local provider = newProvider({})

            assert.same({}, provider.getVariantsOf("blizzard:1"))
        end)
    end)

    describe("refresh", function()
        local SOURCE_ID = 5555

        it("picks up sets the client learned about since the last read", function()
            local provider, _, config = newProvider({ sets = { set({ setID = 1, name = "First" }) } })
            assert.equal(1, #provider.getOutfits())

            config.sets = { set({ setID = 1, name = "First" }), set({ setID = 2, name = "Second" }) }
            provider.refresh()

            assert.equal(2, #provider.getOutfits())
        end)

        it("drops the outfit index so a removed set stops resolving", function()
            local provider, _, config = newProvider({ sets = { set() } })
            assert.is_not_nil(provider.getOutfit(OUTFIT_ID))

            config.sets = { set({ setID = 2, name = "Other" }) }
            provider.refresh()

            assert.is_nil(provider.getOutfit(OUTFIT_ID))
        end)

        -- Slot caches survive nothing either: a client that re-reports a set's items is
        -- the whole reason the addon is told to refresh.
        it("rebuilds the slots of a set it had already resolved", function()
            local provider, recorded, config = newProviderWithSlots(
                { item(SOURCE_ID, { invSlot = 1 }) },
                { [SOURCE_ID] = source(77) }
            )
            assert.equal(77, provider.getOutfits()[1].slots[1].appearanceID)

            config.items[SET_ID] = { item(SOURCE_ID, { invSlot = 1 }), item(6, { invSlot = 2 }) }
            config.sources[6] = source(66)
            provider.refresh()

            assert.equal(2, #provider.getOutfits()[1].slots)
            assert.equal(2, #recorded.setAppearances)
        end)
    end)

    describe("the set list not being loaded yet", function()
        it("lists nothing while the client has no set data", function()
            local provider = newProvider({})

            assert.same({}, provider.getOutfits())
        end)

        -- Caching "this account has no sets" for the session is the failure mode: the
        -- gallery would stay empty until a /reload.
        it("asks again on the next call rather than caching emptiness", function()
            local provider, recorded = newProvider({})

            provider.getOutfits()
            provider.getOutfits()

            assert.equal(2, recorded.allSets)
        end)

        it("lists the sets as soon as the client has them", function()
            local provider, _, config = newProvider({})
            assert.same({}, provider.getOutfits())

            config.sets = { set() }

            assert.equal(1, #provider.getOutfits())
        end)

        it("also retries when the client answers with an empty set list", function()
            local provider, recorded, config = newProvider({ sets = {} })
            provider.getOutfits()

            config.sets = { set() }

            assert.equal(1, #provider.getOutfits())
            assert.equal(2, recorded.allSets)
        end)
    end)

    describe("the logger seam", function()
        it("constructs without a logger at all", function()
            local api = fake.newTransmogApi({ sets = { set() }, items = {} })
            local provider = ns.newBlizzardSetProvider({ api = api })

            assert.same({}, provider.getOutfits()[1].slots)
        end)

        it("reports unresolved data through the injected logger", function()
            local lines = {}
            local api = fake.newTransmogApi({ sets = { set() }, items = {} })
            local provider = ns.newBlizzardSetProvider({
                api = api,
                logger = {
                    info = function() end,
                    debug = function(message)
                        lines[#lines + 1] = message
                    end,
                },
            })

            assert.same({}, provider.getOutfits()[1].slots)

            assert.equal(1, #lines)
            assert.is_truthy(lines[1]:find("not available yet", 1, true))
        end)
    end)
end)
