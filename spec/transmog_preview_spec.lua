local loader = require("addon_loader")
local fake = require("fake_wow")

describe("ns.newTransmogPreview", function()
    local ns = loader.load()

    ---One slot of a resolved outfit, as the preview reads it.
    ---@class PreviewSlotSpec
    ---@field inventorySlot number?
    ---@field resolvedSourceID number?

    ---@param specs PreviewSlotSpec[]
    ---@param overrides table?
    ---@return ResolvedOutfit
    local function outfit(specs, overrides)
        local slots = {}
        for index, spec in ipairs(specs) do
            slots[index] = {
                inventorySlot = spec.inventorySlot,
                appearanceID = index,
                resolvedSourceID = spec.resolvedSourceID,
                collected = true,
                usable = true,
                missing = false,
                unresolved = false,
            }
        end

        local row = {
            outfit = { id = "blizzard:1", origin = "blizzard", name = "Judgement", tags = {}, slots = {} },
            wearable = true,
            collectedCount = #slots,
            missingCount = 0,
            totalCount = #slots,
            slots = slots,
            unresolved = false,
        }
        for key, value in pairs(overrides or {}) do
            row[key] = value
        end
        return row
    end

    ---@param config table? as `fake.newPreviewApi` takes
    ---@return TransmogPreview preview, table recorded
    local function newPreview(config)
        local api, recorded = fake.newPreviewApi(config)
        return ns.newTransmogPreview({ api = api }), recorded
    end

    ---The inventory slots actually handed to the client, in order.
    ---@param recorded table
    ---@return number[]
    local function appliedSlots(recorded)
        local slots = {}
        for index, entry in ipairs(recorded.pending) do
            slots[index] = entry.inventorySlot
        end
        return slots
    end

    ---A three-piece set every slot of which can be shown.
    ---@return ResolvedOutfit
    local function fullOutfit()
        return outfit({
            { inventorySlot = 1, resolvedSourceID = 101 },
            { inventorySlot = 5, resolvedSourceID = 105 },
            { inventorySlot = 7, resolvedSourceID = 107 },
        })
    end

    it("is exported by the addon files", function()
        assert.is_function(ns.newTransmogPreview)
    end)

    describe("applying a set", function()
        it("reports success", function()
            local preview = newPreview()

            assert.is_true(preview.preview(fullOutfit()).ok)
        end)

        it("sends every slot to the client", function()
            local preview, recorded = newPreview()

            preview.preview(fullOutfit())

            assert.same({ 1, 5, 7 }, appliedSlots(recorded))
        end)

        it("sends the source the resolver picked", function()
            local preview, recorded = newPreview()

            preview.preview(fullOutfit())

            assert.equal(101, recorded.pending[1].sourceID)
        end)

        it("counts what it applied", function()
            local preview = newPreview()

            assert.equal(3, preview.preview(fullOutfit()).applied)
        end)

        -- Leftovers from whatever the player was previewing before would blend into the
        -- new set and show an outfit that is neither.
        it("clears the previous pending appearance first", function()
            local preview, recorded = newPreview()

            preview.preview(fullOutfit())

            assert.equal(1, recorded.cleared)
        end)

        it("clears before it applies anything", function()
            local order = {}
            local preview = ns.newTransmogPreview({
                api = {
                    isAvailable = function() return true end,
                    clearPending = function()
                        order[#order + 1] = "clear"
                    end,
                    setPending = function()
                        order[#order + 1] = "apply"
                        return true
                    end,
                },
            })

            preview.preview(outfit({ { inventorySlot = 1, resolvedSourceID = 101 } }))

            assert.same({ "clear", "apply" }, order)
        end)

        it("brings the wardrobe to the front", function()
            local preview, recorded = newPreview()

            preview.preview(fullOutfit())

            assert.equal(1, recorded.opened)
        end)

        -- `open` is optional on the adapter; a client that cannot raise the frame must
        -- still get the preview applied.
        it("applies the set on a client that cannot raise the frame", function()
            local preview = newPreview({ open = false })

            assert.is_true(preview.preview(fullOutfit()).ok)
        end)
    end)

    describe("slots that cannot carry an appearance", function()
        -- Neck, rings and trinkets have no appearance to set, and sending one is an error
        -- rather than a no-op. A set that happens to list one must not lose the preview.
        it("never sends the neck slot", function()
            local preview, recorded = newPreview()

            preview.preview(outfit({
                { inventorySlot = 1, resolvedSourceID = 101 },
                { inventorySlot = 2, resolvedSourceID = 102 },
            }))

            assert.same({ 1 }, appliedSlots(recorded))
        end)

        it("applies the rest of the set around an untransmoggable slot", function()
            local preview = newPreview()

            local result = preview.preview(outfit({
                { inventorySlot = 1, resolvedSourceID = 101 },
                { inventorySlot = 2, resolvedSourceID = 102 },
            }))

            assert.is_true(result.ok)
            assert.equal(1, result.applied)
        end)

        -- Not skipped, because the player was never going to see that piece anyway;
        -- counting it would announce a shortfall that is not one.
        it("does not count an untransmoggable slot as skipped", function()
            local preview = newPreview()

            local result = preview.preview(outfit({
                { inventorySlot = 1, resolvedSourceID = 101 },
                { inventorySlot = 2, resolvedSourceID = 102 },
            }))

            assert.equal(0, result.skipped)
        end)

        it("ignores a slot the client gave no number for", function()
            local preview, recorded = newPreview()

            preview.preview(outfit({
                { resolvedSourceID = 101 },
                { inventorySlot = 5, resolvedSourceID = 105 },
            }))

            assert.same({ 5 }, appliedSlots(recorded))
        end)
    end)

    describe("slots it could not show", function()
        -- Skipped rather than blanked, so the preview shows what the player is already
        -- wearing there instead of bare skin.
        it("skips a slot with no source at all", function()
            local preview, recorded = newPreview()

            local result = preview.preview(outfit({
                { inventorySlot = 1, resolvedSourceID = 101 },
                { inventorySlot = 5 },
            }))

            assert.equal(1, result.applied)
            assert.equal(1, result.skipped)
            assert.same({ 1 }, appliedSlots(recorded))
        end)

        it("counts a slot the client itself refused as skipped", function()
            local preview = newPreview({ rejectSlots = { [5] = true } })

            local result = preview.preview(fullOutfit())

            assert.equal(2, result.applied)
            assert.equal(1, result.skipped)
        end)

        -- A set that goes on with two pieces missing is a success the player still needs
        -- to be told about, so the attempt stays `ok` and the shortfall is reported.
        it("still succeeds when some slots were skipped", function()
            local preview = newPreview({ rejectSlots = { [5] = true } })

            assert.is_true(preview.preview(fullOutfit()).ok)
        end)
    end)

    describe("refusing to preview", function()
        ---@param config table?
        ---@param row ResolvedOutfit?
        ---@return PreviewResult
        local function refusal(config, row)
            local preview = newPreview(config)
            return preview.preview(row or fullOutfit())
        end

        -- Pending transmog is only accepted while the player is standing at a
        -- transmogrifier; anywhere else the client rejects every SetPending.
        it("refuses with 'unavailable' away from a transmogrifier", function()
            local result = refusal({ available = false })

            assert.is_false(result.ok)
            assert.equal("unavailable", result.reason)
        end)

        it("touches the client at all when it is unavailable", function()
            local preview, recorded = newPreview({ available = false })

            preview.preview(fullOutfit())

            assert.equal(0, recorded.cleared)
            assert.same({}, recorded.pending)
        end)

        -- Previewing a half-streamed set would dress the player in whichever pieces had
        -- arrived, which reads as the addon picking the wrong items rather than as data
        -- still loading.
        it("refuses with 'loading' while the set is unresolved", function()
            local result = refusal(nil, outfit({ { inventorySlot = 1, resolvedSourceID = 101 } }, {
                unresolved = true,
            }))

            assert.is_false(result.ok)
            assert.equal("loading", result.reason)
        end)

        it("clears nothing when the set is still loading", function()
            local preview, recorded = newPreview()

            preview.preview(outfit({ { inventorySlot = 1, resolvedSourceID = 101 } }, { unresolved = true }))

            assert.equal(0, recorded.cleared)
        end)

        it("refuses with 'noSources' when nothing could be applied", function()
            local result = refusal(nil, outfit({ { inventorySlot = 1 }, { inventorySlot = 5 } }))

            assert.is_false(result.ok)
            assert.equal("noSources", result.reason)
        end)

        it("refuses with 'noSources' for a set with no slots at all", function()
            assert.equal("noSources", refusal(nil, outfit({})).reason)
        end)

        it("refuses with 'noSources' when the client rejected every slot", function()
            local result = refusal({ rejectSlots = { [1] = true, [5] = true, [7] = true } })

            assert.equal("noSources", result.reason)
        end)

        ---@type { label: string, config: table?, row: ResolvedOutfit? }[]
        local cases = {
            { label = "unavailable", config = { available = false } },
            { label = "still loading", row = outfit({ { inventorySlot = 1 } }, { unresolved = true }) },
            { label = "out of sources", row = outfit({ { inventorySlot = 1 } }) },
        }

        for _, case in ipairs(cases) do
            it("reports no counts when it is " .. case.label, function()
                local result = refusal(case.config, case.row)

                assert.equal(0, result.applied)
                assert.equal(0, result.skipped)
            end)
        end
    end)

    describe("canPreview", function()
        it("says yes at a transmogrifier", function()
            local preview = newPreview()

            assert.is_true(preview.canPreview())
        end)

        it("says no away from one", function()
            local preview = newPreview({ available = false })

            assert.is_false(preview.canPreview())
        end)

        -- The presenter asks this to decide whether to grey the button out, so an adapter
        -- that answers nothing must read as "no" rather than erroring mid-draw.
        it("says no when the adapter cannot answer at all", function()
            local preview = ns.newTransmogPreview({ api = {} })

            assert.is_false(preview.canPreview())
        end)
    end)

    describe("the logger seam", function()
        it("constructs without a logger at all", function()
            local api = fake.newPreviewApi()
            local preview = ns.newTransmogPreview({ api = api })

            assert.is_true(preview.preview(fullOutfit()).ok)
        end)

        it("reports an unavailable transmog UI through the injected logger", function()
            local lines = {}
            local api = fake.newPreviewApi({ available = false })
            local preview = ns.newTransmogPreview({
                api = api,
                logger = {
                    info = function() end,
                    debug = function(message)
                        lines[#lines + 1] = message
                    end,
                },
            })

            preview.preview(fullOutfit())

            assert.equal(1, #lines)
            assert.is_truthy(lines[1]:find("not available", 1, true))
        end)
    end)
end)
