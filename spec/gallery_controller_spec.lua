local loader = require("addon_loader")
local fake = require("fake_wow")

describe("ns.newGalleryController", function()
    local ns = loader.load()

    ---@param outfits Outfit[]
    ---@param recorded table? counters the provider adds to, so a test can watch it
    ---@return OutfitProvider
    local function newStubProvider(outfits, recorded)
        recorded = recorded or {}
        recorded.invalidations = recorded.invalidations or 0

        return {
            getOutfits = function()
                return outfits
            end,

            getOutfit = function(id)
                for _, outfit in ipairs(outfits) do
                    if outfit.id == id then
                        return outfit
                    end
                end
                return nil
            end,

            invalidatePending = function()
                recorded.invalidations = recorded.invalidations + 1
            end,
        }
    end

    ---A stub `CollectionResolver`. The controller only ever reads `wearable`, `unresolved`
    ---and `missingCount` off a row, so a table of pre-resolved rows keyed by outfit id
    ---keeps this spec about filtering and sorting rather than about counting slots.
    ---@param rows table<string, ResolvedOutfit>
    ---@return CollectionResolver collection
    ---@return table recorded `{ resolved, refreshes, invalidations }`
    local function newStubCollection(rows)
        local recorded = { resolved = {}, refreshes = 0, invalidations = 0 }

        local collection = {
            resolve = function(outfit)
                recorded.resolved[#recorded.resolved + 1] = outfit.id
                return rows[outfit.id]
            end,

            refresh = function()
                recorded.refreshes = recorded.refreshes + 1
            end,

            invalidatePending = function()
                recorded.invalidations = recorded.invalidations + 1
            end,
        }

        return collection, recorded
    end

    ---One row of the gallery, declared as the two facts the controller reasons about.
    ---@class RowSpec
    ---@field id string
    ---@field name string?
    ---@field wearable boolean?
    ---@field missing number?
    ---@field unresolved boolean?
    ---@field originallyValidForCharacter boolean?

    ---@param spec RowSpec
    ---@return Outfit outfit, ResolvedOutfit row
    local function buildRow(spec)
        ---@type Outfit
        local outfit = {
            id = spec.id,
            origin = "blizzard",
            name = spec.name or spec.id,
            tags = {},
            slots = {},
            originallyValidForCharacter = spec.originallyValidForCharacter,
        }

        ---@type ResolvedOutfit
        local row = {
            outfit = outfit,
            wearable = spec.wearable == true,
            collectedCount = 0,
            missingCount = spec.missing or 0,
            totalCount = spec.missing or 0,
            slots = {},
            unresolved = spec.unresolved == true,
        }

        return outfit, row
    end

    ---Builds a controller over one provider per group, in the order given.
    ---@param groups RowSpec[][]
    ---@param options table? `{ logger }`
    ---@return GalleryController controller
    ---@return table recorded the collection resolver's
    ---@return table providerRecorded shared by every provider in the list
    local function newControllerOver(groups, options)
        options = options or {}
        local providers = {}
        local rows = {}
        local providerRecorded = {}

        for index, group in ipairs(groups) do
            local outfits = {}
            for position, spec in ipairs(group) do
                local outfit, row = buildRow(spec)
                outfits[position] = outfit
                rows[spec.id] = row
            end
            providers[index] = newStubProvider(outfits, providerRecorded)
        end

        local collection, recorded = newStubCollection(rows)
        local controller = ns.newGalleryController({
            providers = providers,
            collection = collection,
            logger = options.logger,
        })

        return controller, recorded, providerRecorded
    end

    ---@param specs RowSpec[]
    ---@param options table?
    ---@return GalleryController controller, table recorded, table providerRecorded
    local function newController(specs, options)
        return newControllerOver({ specs }, options)
    end

    ---@param rows GalleryRow[]
    ---@return string[]
    local function idsOf(rows)
        local ids = {}
        for index, row in ipairs(rows) do
            ids[index] = row.outfit.id
        end
        return ids
    end

    ---A gallery with one row of every interesting kind.
    ---@type RowSpec[]
    local MIXED = {
        { id = "a", wearable = true, missing = 2 },
        { id = "b", wearable = false, missing = 5 },
        { id = "c", wearable = true, missing = 0 },
        { id = "d", unresolved = true },
    }

    it("is exported by the addon files", function()
        assert.is_function(ns.newGalleryController)
    end)

    describe("defaults", function()
        it("starts showing every set", function()
            local controller = newController(MIXED)

            assert.equal(ns.GALLERY_FILTER_ALL, controller.getFilter())
        end)

        it("starts unsorted", function()
            local controller = newController(MIXED)

            assert.equal(ns.GALLERY_SORT_NONE, controller.getSort())
        end)

        it("shows every row before the player touches a control", function()
            local controller = newController(MIXED)

            assert.same({ "a", "b", "c", "d" }, idsOf(controller.getRows()))
        end)
    end)

    describe("gathering rows", function()
        -- The second provider is the community outfit source that ships later; the
        -- controller must already be indifferent to where a row came from.
        it("takes rows from every provider in the list", function()
            local controller = newControllerOver({
                { { id = "a" }, { id = "b" } },
                { { id = "c" } },
            })

            assert.same({ "a", "b", "c" }, idsOf(controller.getRows()))
        end)

        it("keeps the providers in the order they were registered", function()
            local controller = newControllerOver({
                { { id = "z" } },
                { { id = "a" } },
            })

            assert.same({ "z", "a" }, idsOf(controller.getRows()))
        end)

        it("shows nothing when no provider has any outfit yet", function()
            local controller = newControllerOver({ {}, {} })

            assert.same({}, controller.getRows())
        end)
    end)

    describe("filtering", function()
        ---@type { filter: string, expected: string[] }[]
        local cases = {
            { filter = ns.GALLERY_FILTER_ALL, expected = { "a", "b", "c", "d" } },
            -- The unresolved row rides along with every answer: a set must never vanish
            -- from the gallery merely because its data is still arriving.
            { filter = ns.GALLERY_FILTER_WEARABLE, expected = { "a", "c", "d" } },
            { filter = ns.GALLERY_FILTER_UNWEARABLE, expected = { "b", "d" } },
        }

        for _, case in ipairs(cases) do
            it("shows the right rows under " .. case.filter, function()
                local controller = newController(MIXED)

                controller.setFilter(case.filter)

                assert.same(case.expected, idsOf(controller.getRows()))
            end)

            it("remembers the " .. case.filter .. " filter it was given", function()
                local controller = newController(MIXED)

                controller.setFilter(case.filter)

                assert.equal(case.filter, controller.getFilter())
            end)
        end

        -- Acceptance criterion 3, at the gallery level. `originallyValidForCharacter` is
        -- the game's answer about the *original* class restriction; the filter must use
        -- the resolver's answer over every available source instead. Trusting the class
        -- mask here would hide precisely the Druid-set-on-a-Rogue rows this addon exists
        -- to surface.
        it("shows a class-restricted set that is visually reproducible", function()
            local controller = newController({
                { id = "druid", originallyValidForCharacter = false, wearable = true, missing = 1 },
            })

            controller.setFilter(ns.GALLERY_FILTER_WEARABLE)

            assert.same({ "druid" }, idsOf(controller.getRows()))
        end)

        it("hides a set the character's own class set cannot be reproduced from", function()
            local controller = newController({
                { id = "own", originallyValidForCharacter = true, wearable = false, missing = 1 },
            })

            controller.setFilter(ns.GALLERY_FILTER_WEARABLE)

            assert.same({}, idsOf(controller.getRows()))
        end)

        it("lists a class-restricted but reproducible set as wearable, not unwearable", function()
            local controller = newController({
                { id = "druid", originallyValidForCharacter = false, wearable = true, missing = 1 },
            })

            controller.setFilter(ns.GALLERY_FILTER_UNWEARABLE)

            assert.same({}, idsOf(controller.getRows()))
        end)
    end)

    describe("sorting by missing pieces", function()
        ---@type RowSpec[]
        local BY_MISSING = {
            { id = "a", wearable = true, missing = 3 },
            { id = "b", wearable = true, missing = 0 },
            { id = "c", wearable = true, missing = 7 },
        }

        ---@type { sort: string, expected: string[] }[]
        local cases = {
            { sort = ns.GALLERY_SORT_MISSING_ASC, expected = { "b", "a", "c" } },
            { sort = ns.GALLERY_SORT_MISSING_DESC, expected = { "c", "a", "b" } },
            -- "none" is the provider's own ordering, which for Blizzard sets is the
            -- client's uiOrder — the arrangement the player already knows.
            { sort = ns.GALLERY_SORT_NONE, expected = { "a", "b", "c" } },
        }

        for _, case in ipairs(cases) do
            it("orders the rows for " .. case.sort, function()
                local controller = newController(BY_MISSING)

                controller.setSort(case.sort)

                assert.same(case.expected, idsOf(controller.getRows()))
            end)

            it("remembers the " .. case.sort .. " sort it was given", function()
                local controller = newController(BY_MISSING)

                controller.setSort(case.sort)

                assert.equal(case.sort, controller.getSort())
            end)
        end

        it("sorts the rows that survived the filter, not the whole list", function()
            local controller = newController({
                { id = "a", wearable = true, missing = 3 },
                { id = "b", wearable = false, missing = 0 },
                { id = "c", wearable = true, missing = 1 },
            })

            controller.setFilter(ns.GALLERY_FILTER_WEARABLE)
            controller.setSort(ns.GALLERY_SORT_MISSING_ASC)

            assert.same({ "c", "a" }, idsOf(controller.getRows()))
        end)
    end)

    describe("holding the list still", function()
        -- Without a tiebreak, `table.sort` is free to swap equal rows on every call and
        -- the gallery would visibly reshuffle each time it redrew.
        it("breaks a tie on missing count by name", function()
            local controller = newController({
                { id = "a", name = "Zul'Gurub", wearable = true, missing = 2 },
                { id = "b", name = "Bloodfang", wearable = true, missing = 2 },
                { id = "c", name = "Judgement", wearable = true, missing = 2 },
            })

            controller.setSort(ns.GALLERY_SORT_MISSING_ASC)

            assert.same({ "b", "c", "a" }, idsOf(controller.getRows()))
        end)

        -- Recolours genuinely share a name, so the id is the last resort.
        it("breaks a tie on name by id", function()
            local controller = newController({
                { id = "blizzard:9", name = "Judgement", wearable = true, missing = 2 },
                { id = "blizzard:1", name = "Judgement", wearable = true, missing = 2 },
            })

            controller.setSort(ns.GALLERY_SORT_MISSING_ASC)

            assert.same({ "blizzard:1", "blizzard:9" }, idsOf(controller.getRows()))
        end)

        it("returns the same order on a second read", function()
            local controller = newController({
                { id = "a", name = "Judgement", wearable = true, missing = 2 },
                { id = "b", name = "Judgement", wearable = true, missing = 2 },
                { id = "c", name = "Judgement", wearable = true, missing = 2 },
            })
            controller.setSort(ns.GALLERY_SORT_MISSING_DESC)

            assert.same(idsOf(controller.getRows()), idsOf(controller.getRows()))
        end)
    end)

    describe("rows the player cannot be told anything definite about", function()
        ---@type RowSpec[]
        local WITH_PENDING = {
            { id = "pending", unresolved = true },
            { id = "many", wearable = true, missing = 9 },
            { id = "few", wearable = true, missing = 1 },
        }

        ---@type { filter: string }[]
        local filters = {
            { filter = ns.GALLERY_FILTER_ALL },
            { filter = ns.GALLERY_FILTER_WEARABLE },
            { filter = ns.GALLERY_FILTER_UNWEARABLE },
        }

        for _, case in ipairs(filters) do
            it("keeps an unresolved row under " .. case.filter, function()
                local controller = newController(WITH_PENDING)

                controller.setFilter(case.filter)

                local found = false
                for _, id in ipairs(idsOf(controller.getRows())) do
                    found = found or id == "pending"
                end
                assert.is_true(found)
            end)
        end

        ---An unresolved row's counts are placeholders, so it sits at the bottom in both
        ---directions rather than leading the "fewest missing" list with a fake zero.
        ---@type { sort: string, expected: string[] }[]
        local sorts = {
            { sort = ns.GALLERY_SORT_MISSING_ASC, expected = { "few", "many", "pending" } },
            { sort = ns.GALLERY_SORT_MISSING_DESC, expected = { "many", "few", "pending" } },
        }

        for _, case in ipairs(sorts) do
            it("sorts an unresolved row to the bottom under " .. case.sort, function()
                local controller = newController(WITH_PENDING)

                controller.setSort(case.sort)

                assert.same(case.expected, idsOf(controller.getRows()))
            end)
        end

        it("keeps several unresolved rows in a stable order among themselves", function()
            local controller = newController({
                { id = "z", name = "Zul'Gurub", unresolved = true },
                { id = "a", name = "Bloodfang", unresolved = true },
                { id = "real", wearable = true, missing = 4 },
            })

            controller.setSort(ns.GALLERY_SORT_MISSING_ASC)

            assert.same({ "real", "a", "z" }, idsOf(controller.getRows()))
        end)
    end)

    describe("controls the player can misuse", function()
        ---@return table logger, table lines
        local function newRecordingLogger()
            local lines = {}
            return {
                info = function() end,
                debug = function(message)
                    lines[#lines + 1] = message
                end,
            }, lines
        end

        ---@type { label: string, value: any }[]
        local rubbish = {
            { label = "an unknown string", value = "collected" },
            { label = "nil", value = nil },
            { label = "a number", value = 3 },
        }

        for _, case in ipairs(rubbish) do
            it("keeps the current filter when handed " .. case.label, function()
                local logger = newRecordingLogger()
                local controller = newController(MIXED, { logger = logger })
                controller.setFilter(ns.GALLERY_FILTER_WEARABLE)

                controller.setFilter(case.value)

                assert.equal(ns.GALLERY_FILTER_WEARABLE, controller.getFilter())
            end)

            it("keeps the current sort when handed " .. case.label, function()
                local logger = newRecordingLogger()
                local controller = newController(MIXED, { logger = logger })
                controller.setSort(ns.GALLERY_SORT_MISSING_DESC)

                controller.setSort(case.value)

                assert.equal(ns.GALLERY_SORT_MISSING_DESC, controller.getSort())
            end)
        end

        it("reports an unknown filter through the injected logger", function()
            local logger, lines = newRecordingLogger()
            local controller = newController(MIXED, { logger = logger })

            controller.setFilter("collected")

            assert.equal(1, #lines)
            assert.is_truthy(lines[1]:find("unknown filter", 1, true))
        end)

        it("reports an unknown sort through the injected logger", function()
            local logger, lines = newRecordingLogger()
            local controller = newController(MIXED, { logger = logger })

            controller.setSort("byName")

            assert.equal(1, #lines)
            assert.is_truthy(lines[1]:find("unknown sort", 1, true))
        end)

        it("constructs without a logger at all", function()
            local controller = newController(MIXED)

            controller.setFilter("collected")

            assert.equal(ns.GALLERY_FILTER_ALL, controller.getFilter())
        end)
    end)

    ---This is the performance fix, and the one behaviour here that a player feels: opening
    ---the gallery used to sweep the whole collection because every row was resolved before
    ---it could be listed. On a client reporting thousands of sets that is thousands of
    ---source lookups for a dozen visible rows, and it is why every row read "Loading…".
    describe("resolving no more than the view actually needs", function()
        it("resolves nothing to list the default view", function()
            local controller, recorded = newController(MIXED)

            controller.getRows()

            assert.same({}, recorded.resolved)
        end)

        it("hands the default view its rows unresolved", function()
            local controller = newController(MIXED)

            for _, row in ipairs(controller.getRows()) do
                assert.is_nil(row.resolved)
            end
        end)

        it("still lists every set in the default view", function()
            local controller = newController(MIXED)

            assert.same({ "a", "b", "c", "d" }, idsOf(controller.getRows()))
        end)

        it("resolves nothing however many times the default view is redrawn", function()
            local controller, recorded = newController(MIXED)

            controller.getRows()
            controller.getRows()
            controller.getRows()

            assert.same({}, recorded.resolved)
        end)

        ---A wearability filter has to know every set's wearability and a missing-count sort
        ---has to know every set's count, so those views genuinely cannot be answered from
        ---the set list alone.
        ---@type { label: string, apply: fun(controller: GalleryController) }[]
        local demanding = {
            {
                label = "a wearability filter",
                apply = function(controller)
                    controller.setFilter(ns.GALLERY_FILTER_WEARABLE)
                end,
            },
            {
                label = "a missing-count sort",
                apply = function(controller)
                    controller.setSort(ns.GALLERY_SORT_MISSING_ASC)
                end,
            },
        }

        for _, case in ipairs(demanding) do
            it("reports that " .. case.label .. " needs full resolution", function()
                local controller = newController(MIXED)

                case.apply(controller)

                assert.is_true(controller.needsFullResolution())
            end)

            it("resolves every row under " .. case.label, function()
                local controller, recorded = newController(MIXED)

                case.apply(controller)
                controller.getRows()

                assert.equal(4, #recorded.resolved)
            end)

            it("carries the resolution on the row under " .. case.label, function()
                local controller = newController(MIXED)

                case.apply(controller)

                for _, row in ipairs(controller.getRows()) do
                    assert.is_not_nil(row.resolved)
                end
            end)
        end

        it("reports that the default view needs no full resolution", function()
            local controller = newController(MIXED)

            assert.is_false(controller.needsFullResolution())
        end)

        -- What the presenter calls for the handful of rows actually on screen.
        it("resolves a single outfit on demand", function()
            local controller, recorded = newController(MIXED)
            local row = controller.getRows()[1]

            local resolved = controller.resolve(row.outfit)

            assert.equal("a", resolved.outfit.id)
            assert.same({ "a" }, recorded.resolved)
        end)
    end)

    describe("invalidatePending", function()
        -- The client has streamed more data in: retire the "not yet" answers so they are
        -- asked once more, and leave the settled ones alone.
        it("passes the word to the collection resolver", function()
            local controller, recorded = newController(MIXED)

            controller.invalidatePending()

            assert.equal(1, recorded.invalidations)
        end)

        -- The provider holds its own pending sets, and a set that never rebuilds its slots
        -- leaves every row below it unresolvable no matter how often the resolvers retry.
        it("passes the word to every provider", function()
            local controller, _, providerRecorded = newControllerOver({
                { { id = "a" } },
                { { id = "b" } },
            })

            controller.invalidatePending()

            assert.equal(2, providerRecorded.invalidations)
        end)

        -- Community outfit providers arrive later and need not implement it.
        it("tolerates a provider that has none", function()
            local collection = newStubCollection({})
            local controller = ns.newGalleryController({
                providers = { { getOutfits = function() return {} end, getOutfit = function() return nil end } },
                collection = collection,
            })

            assert.has_no.errors(function()
                controller.invalidatePending()
            end)
        end)

        it("leaves the filter and sort the player chose alone", function()
            local controller = newController(MIXED)
            controller.setFilter(ns.GALLERY_FILTER_WEARABLE)

            controller.invalidatePending()

            assert.equal(ns.GALLERY_FILTER_WEARABLE, controller.getFilter())
        end)
    end)

    describe("refresh", function()
        -- Everything the player sees is character-specific and derived; the providers'
        -- set metadata is not, so only the resolutions are dropped.
        it("delegates to the collection resolver", function()
            local controller, recorded = newController(MIXED)

            controller.refresh()

            assert.equal(1, recorded.refreshes)
        end)

        it("leaves the filter and sort the player chose alone", function()
            local controller = newController(MIXED)
            controller.setFilter(ns.GALLERY_FILTER_WEARABLE)
            controller.setSort(ns.GALLERY_SORT_MISSING_DESC)

            controller.refresh()

            assert.equal(ns.GALLERY_FILTER_WEARABLE, controller.getFilter())
            assert.equal(ns.GALLERY_SORT_MISSING_DESC, controller.getSort())
        end)
    end)

    describe("over the real resolvers", function()
        ---@param sourceID number
        ---@param visualID number
        ---@param overrides table?
        ---@return AppearanceSourceInfo
        local function source(sourceID, visualID, overrides)
            local info = {
                sourceID = sourceID,
                visualID = visualID,
                isValidSourceForPlayer = false,
                isCollected = false,
                canDisplayOnPlayer = false,
            }
            for key, value in pairs(overrides or {}) do
                info[key] = value
            end
            return info
        end

        ---@param id string
        ---@param name string
        ---@param appearanceIDs number[]
        ---@param originallyValid boolean
        ---@return Outfit
        local function outfit(id, name, appearanceIDs, originallyValid)
            local slots = {}
            for index, appearanceID in ipairs(appearanceIDs) do
                slots[index] = { inventorySlot = index, appearanceID = appearanceID }
            end
            return {
                id = id,
                origin = "blizzard",
                name = name,
                tags = {},
                slots = slots,
                originallyValidForCharacter = originallyValid,
            }
        end

        -- The full stack answering acceptance criterion 3: a Rogue filtering to "can wear"
        -- sees the Druid set, because an unrestricted leather source exists for each of
        -- its visuals, and does not see the plate set, whose visuals are plate-only.
        it("filters on reproducible visuals rather than the original class restriction", function()
            local api = fake.newTransmogApi({
                appearanceSources = {
                    [1] = {
                        source(10, 1, { isCollected = true }),
                        source(11, 1, { isValidSourceForPlayer = true, isCollected = true }),
                    },
                    [2] = { source(20, 2, { isValidSourceForPlayer = true }) },
                    [3] = { source(30, 3, { isCollected = true, canDisplayOnPlayer = true }) },
                },
            })
            local collection = ns.newCollectionResolver({
                appearances = ns.newAppearanceResolver({ api = api }),
            })
            local controller = ns.newGalleryController({
                providers = {
                    newStubProvider({
                        outfit("blizzard:1", "Druid Tier", { 1, 2 }, false),
                        outfit("blizzard:2", "Plate Tier", { 3 }, false),
                    }),
                },
                collection = collection,
            })

            controller.setFilter(ns.GALLERY_FILTER_WEARABLE)

            assert.same({ "blizzard:1" }, idsOf(controller.getRows()))
        end)
    end)
end)
