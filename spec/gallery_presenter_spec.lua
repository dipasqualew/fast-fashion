local loader = require("addon_loader")

describe("ns.newGalleryPresenter", function()
    local ns = loader.load()

    ---One slot of a resolved outfit, declared as the three facts the presenter reads.
    ---@class SlotSpec
    ---@field inventorySlot number?
    ---@field collected boolean?
    ---@field usable boolean?
    ---@field unresolved boolean?

    ---One row of the gallery. `collected`/`total`/`missing` are independent on purpose:
    ---the presenter must render whatever the resolver hands it rather than recomputing.
    ---@class PresenterRowSpec
    ---@field id string
    ---@field name string?
    ---@field description string?
    ---@field wearable boolean?
    ---@field collected number?
    ---@field total number?
    ---@field missing number?
    ---@field unresolved boolean?
    ---@field slots SlotSpec[]?

    ---@param spec SlotSpec
    ---@return ResolvedOutfitSlot
    local function buildSlot(spec)
        return {
            inventorySlot = spec.inventorySlot,
            appearanceID = 1,
            collected = spec.collected == true,
            usable = spec.usable == true,
            missing = spec.collected ~= true,
            unresolved = spec.unresolved == true,
        }
    end

    ---@param spec PresenterRowSpec
    ---@return ResolvedOutfit
    local function buildRow(spec)
        local slots = {}
        for index, slotSpec in ipairs(spec.slots or {}) do
            slots[index] = buildSlot(slotSpec)
        end

        return {
            outfit = {
                id = spec.id,
                origin = "blizzard",
                name = spec.name or spec.id,
                description = spec.description,
                tags = {},
                slots = {},
            },
            wearable = spec.wearable == true,
            collectedCount = spec.collected or 0,
            missingCount = spec.missing or 0,
            totalCount = spec.total or 0,
            slots = slots,
            unresolved = spec.unresolved == true,
        }
    end

    ---A stub `GalleryController`. The presenter only ever reads the row list plus the two
    ---control states, so a stub keeps this spec about wording and selection rather than
    ---about filtering — which `gallery_controller_spec.lua` already owns.
    ---@param specs PresenterRowSpec[]
    ---@return GalleryController gallery
    ---@return table recorded `{ filters, sorts }`
    local function newStubGallery(specs)
        local recorded = { filters = {}, sorts = {} }
        local filter = ns.GALLERY_FILTER_ALL
        local sort = ns.GALLERY_SORT_NONE

        local rows = {}
        for index, spec in ipairs(specs) do
            rows[index] = buildRow(spec)
        end

        local gallery = {
            getRows = function()
                return rows
            end,

            getFilter = function()
                return filter
            end,

            getSort = function()
                return sort
            end,

            setFilter = function(key)
                recorded.filters[#recorded.filters + 1] = key
                filter = key
            end,

            setSort = function(key)
                recorded.sorts[#recorded.sorts + 1] = key
                sort = key
            end,
        }

        return gallery, recorded
    end

    ---@param specs PresenterRowSpec[]
    ---@param playerClass string? what `getPlayerClass` answers; nil models an early login
    ---@return GalleryPresenter presenter, table recorded
    local function newPresenter(specs, playerClass)
        local gallery, recorded = newStubGallery(specs)
        local presenter = ns.newGalleryPresenter({
            gallery = gallery,
            getPlayerClass = function()
                return playerClass
            end,
        })
        return presenter, recorded
    end

    ---@param specs PresenterRowSpec[]
    ---@param playerClass string?
    ---@return GalleryRowView
    local function firstRow(specs, playerClass)
        local presenter = newPresenter(specs, playerClass)
        return presenter.getView().rows[1]
    end

    ---@param controls GalleryControlView[]
    ---@return string[]
    local function activeKeys(controls)
        local keys = {}
        for _, control in ipairs(controls) do
            if control.active then
                keys[#keys + 1] = control.key
            end
        end
        return keys
    end

    ---@param view GalleryDetailView
    ---@return string[]
    local function slotLabels(view)
        local labels = {}
        for index, slot in ipairs(view.slots) do
            labels[index] = slot.label
        end
        return labels
    end

    it("is exported by the addon files", function()
        assert.is_function(ns.newGalleryPresenter)
    end)

    describe("what a row says", function()
        it("names the set", function()
            local row = firstRow({ { id = "a", name = "Thunderheart Regalia" } })

            assert.equal("Thunderheart Regalia", row.name)
        end)

        -- The exact wording SPEC.md's row mock-up asks for.
        it("reads the progress as a fraction of the whole set", function()
            local row = firstRow({ { id = "a", collected = 6, total = 8, missing = 2 } })

            assert.equal("6 / 8 collected", row.progress)
        end)

        it("counts the pieces still to find", function()
            local row = firstRow({ { id = "a", collected = 6, total = 8, missing = 2 } })

            assert.equal("2 missing", row.missing)
        end)

        -- "0 missing" is technically true and reads as a chore; the player has finished
        -- this set and the row should say so.
        it("celebrates a finished set rather than reporting zero missing", function()
            local row = firstRow({ { id = "a", collected = 8, total = 8, missing = 0 } })

            assert.equal("Complete", row.missing)
        end)

        it("carries the set description through as the subtitle", function()
            local row = firstRow({ { id = "a", description = "Tier 2 Paladin" } })

            assert.equal("Tier 2 Paladin", row.subtitle)
        end)
    end)

    describe("the wearability line", function()
        -- Naming the class is the product pitch: "Wearable by Rogue" on a Druid set is the
        -- sentence that tells the player this addon knows something the default UI does not.
        it("names the class when the client has told us one", function()
            local row = firstRow({ { id = "a", wearable = true } }, "Rogue")

            assert.equal("Wearable by Rogue", row.status)
        end)

        ---@type { label: string, class: string? }[]
        local nameless = {
            { label = "the client has not answered yet", class = nil },
            { label = "the client answered with a blank name", class = "" },
        }

        for _, case in ipairs(nameless) do
            it("still says the set is wearable when " .. case.label, function()
                local row = firstRow({ { id = "a", wearable = true } }, case.class)

                assert.equal("Wearable", row.status)
            end)
        end

        it("says so plainly when the character cannot reproduce the set", function()
            local row = firstRow({ { id = "a", wearable = false } }, "Rogue")

            assert.equal("Cannot wear", row.status)
        end)

        -- An unresolved row is not a verdict. Saying "Cannot wear" while the client is
        -- still streaming data would be a lie the player acts on.
        it("withholds a verdict while the set is still resolving", function()
            local row = firstRow({ { id = "a", unresolved = true } }, "Rogue")

            assert.equal("Loading…", row.status)
        end)
    end)

    describe("a row whose data has not arrived", function()
        ---A resolver hands back placeholder counts for an unresolved row, and a
        ---presenter that trusted them would print "0 / 0 collected" and "Complete" —
        ---which reads as a *finished* set. Both fields must refuse to answer instead.
        ---@type { field: string, expected: string }[]
        local cases = {
            { field = "progress", expected = "Loading…" },
            { field = "missing", expected = "" },
        }

        for _, case in ipairs(cases) do
            it("shows no count in " .. case.field .. " while loading", function()
                local row = firstRow({
                    { id = "a", unresolved = true, collected = 0, total = 0, missing = 0 },
                })

                assert.equal(case.expected, row[case.field])
            end)
        end

        it("flags the row as unresolved so the frame can colour it apart", function()
            local row = firstRow({ { id = "a", unresolved = true } })

            assert.is_true(row.unresolved)
        end)
    end)

    describe("the filter and sort controls", function()
        ---@type { key: string }[]
        local filters = {
            { key = ns.GALLERY_FILTER_ALL },
            { key = ns.GALLERY_FILTER_WEARABLE },
            { key = ns.GALLERY_FILTER_UNWEARABLE },
        }

        for _, case in ipairs(filters) do
            it("marks exactly the " .. case.key .. " filter active", function()
                local presenter = newPresenter({ { id = "a" } })
                presenter.setFilter(case.key)

                assert.same({ case.key }, activeKeys(presenter.getView().filters))
            end)

            it("hands the " .. case.key .. " key straight back to the controller", function()
                local presenter, recorded = newPresenter({ { id = "a" } })

                presenter.setFilter(case.key)

                assert.same({ case.key }, recorded.filters)
            end)
        end

        ---@type { key: string }[]
        local sorts = {
            { key = ns.GALLERY_SORT_NONE },
            { key = ns.GALLERY_SORT_MISSING_ASC },
            { key = ns.GALLERY_SORT_MISSING_DESC },
        }

        for _, case in ipairs(sorts) do
            it("marks exactly the " .. case.key .. " sort active", function()
                local presenter = newPresenter({ { id = "a" } })
                presenter.setSort(case.key)

                assert.same({ case.key }, activeKeys(presenter.getView().sorts))
            end)

            it("hands the " .. case.key .. " key straight back to the controller", function()
                local presenter, recorded = newPresenter({ { id = "a" } })

                presenter.setSort(case.key)

                assert.same({ case.key }, recorded.sorts)
            end)
        end

        -- The key is what the frame passes back on click, so a control whose label the
        -- player reads must carry the key the controller understands.
        it("labels every filter control", function()
            local view = newPresenter({ { id = "a" } }).getView()

            for _, control in ipairs(view.filters) do
                assert.is_string(control.label)
                assert.not_equal("", control.label)
            end
        end)
    end)

    describe("an empty list", function()
        ---"No transmog sets found yet" under a wearability filter reads as a broken addon
        ---rather than as a narrow filter, so each filter explains its own emptiness.
        ---@type { filter: string, fragment: string }[]
        local cases = {
            { filter = ns.GALLERY_FILTER_ALL, fragment = "No transmog sets" },
            { filter = ns.GALLERY_FILTER_WEARABLE, fragment = "completely wearable" },
            { filter = ns.GALLERY_FILTER_UNWEARABLE, fragment = "is wearable" },
        }

        for _, case in ipairs(cases) do
            it("explains emptiness in the terms of the " .. case.filter .. " filter", function()
                local presenter = newPresenter({})
                presenter.setFilter(case.filter)

                local message = presenter.getView().emptyMessage
                assert.is_truthy(message and message:find(case.fragment, 1, true))
            end)
        end

        it("says nothing at all when there are rows to show", function()
            local view = newPresenter({ { id = "a" } }).getView()

            assert.is_nil(view.emptyMessage)
        end)
    end)

    describe("selecting a set", function()
        ---@type PresenterRowSpec[]
        local TWO = {
            { id = "a", name = "Bloodfang", wearable = true, collected = 1, total = 2, missing = 1 },
            { id = "b", name = "Judgement", wearable = true, collected = 2, total = 2, missing = 0 },
        }

        it("remembers the id it was given", function()
            local presenter = newPresenter(TWO)

            presenter.select("b")

            assert.equal("b", presenter.getSelectedId())
        end)

        it("marks exactly the selected row", function()
            local presenter = newPresenter(TWO)

            presenter.select("b")

            local rows = presenter.getView().rows
            assert.is_false(rows[1].selected)
            assert.is_true(rows[2].selected)
        end)

        it("expands the selected row into a detail view", function()
            local presenter = newPresenter(TWO)

            presenter.select("b")

            assert.equal("Judgement", presenter.getView().detail.name)
        end)

        it("shows no detail before anything is selected", function()
            local presenter = newPresenter(TWO)

            assert.is_nil(presenter.getView().detail)
        end)

        it("clears the detail when the selection is dropped", function()
            local presenter = newPresenter(TWO)
            presenter.select("b")

            presenter.select(nil)

            assert.is_nil(presenter.getView().detail)
        end)

        -- A stale id survives a refresh that dropped the set; asking for it must be quiet.
        it("shows no detail for a set that is not in the list", function()
            local presenter = newPresenter(TWO)

            presenter.select("nonexistent")

            assert.is_nil(presenter.getView().detail)
        end)

        it("repeats the row's progress and status in the detail pane", function()
            local presenter = newPresenter(TWO, "Rogue")

            presenter.select("a")

            local detail = presenter.getView().detail
            assert.equal("1 / 2 collected", detail.progress)
            assert.equal("Wearable by Rogue", detail.status)
        end)
    end)

    describe("the detail pane's slot list", function()
        ---@param slots SlotSpec[]
        ---@return GalleryDetailView
        local function detailOver(slots)
            local presenter = newPresenter({ { id = "a", slots = slots } })
            presenter.select("a")
            return presenter.getView().detail
        end

        it("names the slots the way the player's character sheet does", function()
            local detail = detailOver({
                { inventorySlot = 1 },
                { inventorySlot = 3 },
                { inventorySlot = 15 },
            })

            assert.same({ "Head", "Shoulders", "Back" }, slotLabels(detail))
        end)

        -- A slot we cannot name is still a slot the player is missing, so it falls back to
        -- the number rather than silently vanishing from the list.
        it("keeps a slot whose number it cannot name", function()
            local detail = detailOver({ { inventorySlot = 1 }, { inventorySlot = 99 } })

            assert.same({ "Head", "Slot 99" }, slotLabels(detail))
        end)

        it("keeps a slot the client gave no number for", function()
            local detail = detailOver({ { inventorySlot = 1 }, { inventorySlot = nil } })

            assert.equal(2, #detail.slots)
        end)

        ---The distinction this pane exists for: "No usable source" is a dead end for this
        ---character, "Not collected" is a to-do, and "Loading…" is neither yet. Flattening
        ---any pair of them would send the player farming something unwearable.
        ---@type { label: string, slot: SlotSpec, expected: string }[]
        local cases = {
            {
                label = "owned and wearable",
                slot = { inventorySlot = 1, collected = true, usable = true },
                expected = "Collected",
            },
            {
                label = "wearable but not yet owned",
                slot = { inventorySlot = 1, collected = false, usable = true },
                expected = "Not collected",
            },
            {
                label = "owned on the account but unusable by this character",
                slot = { inventorySlot = 1, collected = true, usable = false },
                expected = "No usable source",
            },
            {
                label = "neither owned nor wearable",
                slot = { inventorySlot = 1, collected = false, usable = false },
                expected = "No usable source",
            },
            {
                label = "still resolving",
                slot = { inventorySlot = 1, unresolved = true },
                expected = "Loading…",
            },
        }

        for _, case in ipairs(cases) do
            it("calls a slot that is " .. case.label .. " '" .. case.expected .. "'", function()
                local detail = detailOver({ case.slot })

                assert.equal(case.expected, detail.slots[1].state)
            end)
        end

        -- The frame colours slots from these flags, so they must survive the trip intact.
        it("carries the raw flags alongside the wording", function()
            local detail = detailOver({ { inventorySlot = 1, collected = true, usable = true } })

            assert.is_true(detail.slots[1].collected)
            assert.is_true(detail.slots[1].usable)
            assert.is_false(detail.slots[1].unresolved)
        end)
    end)

    describe("what a control does to the selection", function()
        -- A detail pane describing a set the player can no longer find in the list is a
        -- dead end, and changing the filter is exactly what can hide it.
        it("drops the selection when the filter changes", function()
            local presenter = newPresenter({ { id = "a" } })
            presenter.select("a")

            presenter.setFilter(ns.GALLERY_FILTER_WEARABLE)

            assert.is_nil(presenter.getSelectedId())
        end)

        -- Sorting only reorders what is already on screen, so the selected set is still
        -- there and yanking the detail pane away would just be rude.
        it("keeps the selection when the sort changes", function()
            local presenter = newPresenter({ { id = "a" } })
            presenter.select("a")

            presenter.setSort(ns.GALLERY_SORT_MISSING_DESC)

            assert.equal("a", presenter.getSelectedId())
        end)

        it("keeps showing the detail pane after a sort", function()
            local presenter = newPresenter({ { id = "a", name = "Bloodfang" } })
            presenter.select("a")

            presenter.setSort(ns.GALLERY_SORT_MISSING_ASC)

            assert.equal("Bloodfang", presenter.getView().detail.name)
        end)
    end)

    describe("scrolling", function()
        ---@param count number
        ---@return PresenterRowSpec[]
        local function manyRows(count)
            local specs = {}
            for index = 1, count do
                -- Zero-padded so lexical order matches numeric order and a test asserting
                -- on ids reads the same way the list does.
                specs[index] = { id = string.format("row%02d", index) }
            end
            return specs
        end

        ---@param view GalleryView
        ---@return string[]
        local function idsOf(view)
            local ids = {}
            for index, row in ipairs(view.rows) do
                ids[index] = row.id
            end
            return ids
        end

        ---@param count number
        ---@param viewport number?
        ---@return GalleryPresenter
        local function newScrollingPresenter(count, viewport)
            local presenter = newPresenter(manyRows(count))
            presenter.setViewportSize(viewport)
            return presenter
        end

        -- A presenter nobody has given a viewport to is not windowing anything; that is
        -- what keeps every other spec in this file free of scroll bookkeeping.
        it("shows every row until a viewport is declared", function()
            local presenter = newPresenter(manyRows(5))

            assert.equal(5, #presenter.getView().rows)
        end)

        it("draws only the rows that fit the viewport", function()
            local presenter = newScrollingPresenter(10, 3)

            assert.same({ "row01", "row02", "row03" }, idsOf(presenter.getView()))
        end)

        it("reports the full match count even while windowed", function()
            local presenter = newScrollingPresenter(10, 3)

            assert.equal(10, presenter.getView().scroll.total)
        end)

        it("moves the window down by the scrolled offset", function()
            local presenter = newScrollingPresenter(10, 3)

            presenter.scrollTo(4)

            assert.same({ "row05", "row06", "row07" }, idsOf(presenter.getView()))
        end)

        it("moves the window by a relative scroll", function()
            local presenter = newScrollingPresenter(10, 3)

            presenter.scrollBy(2)

            assert.same({ "row03", "row04", "row05" }, idsOf(presenter.getView()))
        end)

        ---@type { label: string, offset: number, expected: number }[]
        local clamped = {
            { label = "past the end", offset = 99, expected = 7 },
            { label = "before the start", offset = -5, expected = 0 },
            { label = "exactly at the last page", offset = 7, expected = 7 },
        }

        for _, case in ipairs(clamped) do
            it("clamps an offset " .. case.label, function()
                local presenter = newScrollingPresenter(10, 3)

                presenter.scrollTo(case.offset)

                assert.equal(case.expected, presenter.getView().scroll.offset)
            end)
        end

        -- The last page must still be a full page rather than a single trailing row, or
        -- scrolling to the bottom leaves most of the list area blank.
        it("keeps the window full at the bottom of the list", function()
            local presenter = newScrollingPresenter(10, 3)

            presenter.scrollTo(99)

            assert.same({ "row08", "row09", "row10" }, idsOf(presenter.getView()))
        end)

        it("cannot scroll a list that fits", function()
            local presenter = newScrollingPresenter(2, 5)

            local scroll = presenter.getView().scroll

            assert.equal(0, scroll.maxOffset)
            assert.is_false(scroll.canScrollDown)
            assert.is_false(scroll.canScrollUp)
        end)

        it("draws every row of a list that fits", function()
            local presenter = newScrollingPresenter(2, 5)

            assert.equal(2, #presenter.getView().rows)
        end)

        ---@type { label: string, offset: number, up: boolean, down: boolean }[]
        local edges = {
            { label = "at the top", offset = 0, up = false, down = true },
            { label = "in the middle", offset = 3, up = true, down = true },
            { label = "at the bottom", offset = 7, up = true, down = false },
        }

        for _, case in ipairs(edges) do
            it("reports the scroll affordances " .. case.label, function()
                local presenter = newScrollingPresenter(10, 3)

                presenter.scrollTo(case.offset)
                local scroll = presenter.getView().scroll

                assert.equal(case.up, scroll.canScrollUp)
                assert.equal(case.down, scroll.canScrollDown)
            end)
        end

        -- The failure this guards is ugly: scroll to the bottom of a long list, switch to
        -- a filter that matches two sets, and a naive window reads past the end and draws
        -- an empty gallery over a list that has matches.
        it("re-clamps when the list shrinks under a scrolled window", function()
            local gallery, _ = newStubGallery(manyRows(10))
            local presenter = ns.newGalleryPresenter({
                gallery = gallery,
                getPlayerClass = function()
                    return nil
                end,
            })
            presenter.setViewportSize(3)
            presenter.scrollTo(7)

            presenter.setViewportSize(20)

            assert.equal(0, presenter.getView().scroll.offset)
            assert.equal(10, #presenter.getView().rows)
        end)

        it("returns to the top when the filter changes", function()
            local presenter = newScrollingPresenter(10, 3)
            presenter.scrollTo(5)

            presenter.setFilter(ns.GALLERY_FILTER_WEARABLE)

            assert.equal(0, presenter.getView().scroll.offset)
        end)

        it("returns to the top when the sort changes", function()
            local presenter = newScrollingPresenter(10, 3)
            presenter.scrollTo(5)

            presenter.setSort(ns.GALLERY_SORT_MISSING_DESC)

            assert.equal(0, presenter.getView().scroll.offset)
        end)

        -- Selection survives scrolling because the player is tracking a set, not a row
        -- position; the detail pane is resolved over the whole list, not the window.
        it("keeps showing the detail of a set scrolled out of view", function()
            local presenter = newScrollingPresenter(10, 3)
            presenter.select("row01")

            presenter.scrollTo(7)

            assert.equal("row01", presenter.getView().detail.id)
        end)
    end)
end)
