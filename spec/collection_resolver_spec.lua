local loader = require("addon_loader")
local fake = require("fake_wow")

describe("ns.newCollectionResolver", function()
    local ns = loader.load()

    local OUTFIT_ID = "blizzard:1234"

    ---@param appearanceID number
    ---@param overrides table?
    ---@return AppearanceResolution
    local function resolution(appearanceID, overrides)
        local answer = {
            appearanceID = appearanceID,
            resolvedSourceID = appearanceID * 10,
            usable = false,
            collected = false,
            unresolved = false,
        }
        for key, value in pairs(overrides or {}) do
            answer[key] = value
        end
        return answer
    end

    ---Owned and wearable: the only state that counts towards the collected total.
    ---@param appearanceID number
    ---@return AppearanceResolution
    local function owned(appearanceID)
        return resolution(appearanceID, { usable = true, collected = true })
    end

    ---Wearable by this character but not collected — a missing piece of a wearable set.
    ---@param appearanceID number
    ---@return AppearanceResolution
    local function wearableOnly(appearanceID)
        return resolution(appearanceID, { usable = true })
    end

    ---No source this character can put on. Final answer, not a loading state.
    ---@param appearanceID number
    ---@return AppearanceResolution
    local function unwearable(appearanceID)
        return resolution(appearanceID)
    end

    ---@param appearanceID number
    ---@return AppearanceResolution
    local function pending(appearanceID)
        return resolution(appearanceID, { resolvedSourceID = nil, unresolved = true })
    end

    ---A stub `AppearanceResolver`. The interface is one function returning a small record,
    ---so a table keyed by appearance says everything a test needs — and keeps this spec
    ---about counting slots rather than about reading the client.
    ---@param answers table<number, AppearanceResolution> mutable; a missing key is pending
    ---@return AppearanceResolver appearances
    ---@return table recorded `{ resolved, refreshes, invalidations }`
    ---@return table answers the very table the stub keeps reading
    local function newStubAppearances(answers)
        answers = answers or {}
        local recorded = { resolved = {}, refreshes = 0, invalidations = 0 }

        local appearances = {
            resolve = function(appearanceID, preferredSourceID)
                recorded.resolved[#recorded.resolved + 1] = {
                    appearanceID = appearanceID,
                    preferredSourceID = preferredSourceID,
                }
                return answers[appearanceID] or pending(appearanceID)
            end,

            refresh = function()
                recorded.refreshes = recorded.refreshes + 1
            end,

            invalidatePending = function()
                recorded.invalidations = recorded.invalidations + 1
            end,
        }

        return appearances, recorded, answers
    end

    ---@param appearanceIDs number[] one slot per appearance, in inventory-slot order
    ---@param overrides table?
    ---@return Outfit
    local function outfit(appearanceIDs, overrides)
        local slots = {}
        for index, appearanceID in ipairs(appearanceIDs) do
            slots[index] = {
                inventorySlot = index,
                appearanceID = appearanceID,
                preferredSourceID = appearanceID * 10,
            }
        end

        local built = {
            id = OUTFIT_ID,
            origin = "blizzard",
            name = "Judgement Armor",
            tags = {},
            slots = slots,
        }
        for key, value in pairs(overrides or {}) do
            built[key] = value
        end
        return built
    end

    ---@param answers table<number, AppearanceResolution>?
    ---@return CollectionResolver resolver, table recorded, table answers
    local function newResolver(answers)
        local appearances, recorded, live = newStubAppearances(answers)
        return ns.newCollectionResolver({ appearances = appearances }), recorded, live
    end

    it("is exported by the addon files", function()
        assert.is_function(ns.newCollectionResolver)
    end)

    describe("counting a set's pieces", function()
        ---A four-slot set: two owned, two merely wearable.
        ---@return ResolvedOutfit
        local function partiallyCollected()
            local resolver = newResolver({
                [1] = owned(1),
                [2] = owned(2),
                [3] = wearableOnly(3),
                [4] = wearableOnly(4),
            })
            return resolver.resolve(outfit({ 1, 2, 3, 4 }))
        end

        ---@type { field: string, expected: number }[]
        local counts = {
            { field = "totalCount", expected = 4 },
            { field = "collectedCount", expected = 2 },
            { field = "missingCount", expected = 2 },
        }

        for _, case in ipairs(counts) do
            it("reports " .. case.field .. " for a partially collected outfit", function()
                assert.equal(case.expected, partiallyCollected()[case.field])
            end)
        end

        -- The progress line in the gallery row is "collected / total, N missing"; the two
        -- numbers disagreeing would be visible to the player on every row.
        it("keeps missing as total minus collected", function()
            local row = partiallyCollected()

            assert.equal(row.totalCount - row.collectedCount, row.missingCount)
        end)

        it("counts a fully collected outfit as nothing missing", function()
            local resolver = newResolver({ [1] = owned(1), [2] = owned(2) })

            local row = resolver.resolve(outfit({ 1, 2 }))

            assert.equal(2, row.collectedCount)
            assert.equal(0, row.missingCount)
        end)

        it("counts an outfit the account owns none of as all missing", function()
            local resolver = newResolver({ [1] = wearableOnly(1), [2] = wearableOnly(2) })

            assert.equal(2, resolver.resolve(outfit({ 1, 2 })).missingCount)
        end)

        it("carries the outfit it was asked about", function()
            local resolver = newResolver({ [1] = owned(1) })
            local subject = outfit({ 1 })

            assert.equal(subject, resolver.resolve(subject).outfit)
        end)

        it("resolves one row per slot", function()
            local resolver = newResolver({ [1] = owned(1), [2] = owned(2), [3] = owned(3) })

            assert.equal(3, #resolver.resolve(outfit({ 1, 2, 3 })).slots)
        end)

        it("hands each slot the source the appearance resolver chose", function()
            local resolver = newResolver({ [1] = owned(1) })

            assert.equal(10, resolver.resolve(outfit({ 1 })).slots[1].resolvedSourceID)
        end)

        -- The set's own item is only a hint, but it is the hint the resolver needs to fall
        -- back on when no alternative source qualifies.
        it("passes the slot's preferred source through to the appearance resolver", function()
            local resolver, recorded = newResolver({ [1] = owned(1) })

            resolver.resolve(outfit({ 1 }))

            assert.equal(1, recorded.resolved[1].appearanceID)
            assert.equal(10, recorded.resolved[1].preferredSourceID)
        end)

        it("marks an uncollected slot as missing", function()
            local resolver = newResolver({ [1] = wearableOnly(1) })

            assert.is_true(resolver.resolve(outfit({ 1 })).slots[1].missing)
        end)

        it("does not mark a collected slot as missing", function()
            local resolver = newResolver({ [1] = owned(1) })

            assert.is_false(resolver.resolve(outfit({ 1 })).slots[1].missing)
        end)
    end)

    describe("whether the character can wear the whole set", function()
        it("is wearable when every slot has a source this character can use", function()
            local resolver = newResolver({ [1] = wearableOnly(1), [2] = owned(2) })

            assert.is_true(resolver.resolve(outfit({ 1, 2 })).wearable)
        end)

        -- Wearability is all-or-nothing by definition: an outfit missing one usable slot
        -- cannot be reproduced, however close the rest of it is.
        it("is unwearable when a single slot has no compatible source", function()
            local resolver = newResolver({ [1] = owned(1), [2] = owned(2), [3] = unwearable(3) })

            assert.is_false(resolver.resolve(outfit({ 1, 2, 3 })).wearable)
        end)

        it("still counts the collected pieces of an unwearable set", function()
            local resolver = newResolver({ [1] = owned(1), [2] = owned(2), [3] = unwearable(3) })

            local row = resolver.resolve(outfit({ 1, 2, 3 }))

            assert.equal(2, row.collectedCount)
            assert.equal(1, row.missingCount)
        end)

        it("records the unusable slot so the detail view can point at it", function()
            local resolver = newResolver({ [1] = owned(1), [2] = unwearable(2) })

            local slots = resolver.resolve(outfit({ 1, 2 })).slots

            assert.is_true(slots[1].usable)
            assert.is_false(slots[2].usable)
        end)

        -- Collected and wearable answer different questions: a set can be entirely
        -- reproducible while the account owns none of it.
        it("is wearable even when nothing in it is collected", function()
            local resolver = newResolver({ [1] = wearableOnly(1), [2] = wearableOnly(2) })

            local row = resolver.resolve(outfit({ 1, 2 }))

            assert.is_true(row.wearable)
            assert.equal(0, row.collectedCount)
        end)
    end)

    describe("data the client has not streamed in yet", function()
        ---An outfit the provider could not build slots for. Both shapes reach the resolver
        ---in practice: an empty list from a set whose items are still streaming in, and no
        ---list at all from a provider that gave up before building one.
        ---@type { label: string, build: fun(): Outfit }[]
        local unbuilt = {
            {
                label = "an empty slot list",
                build = function()
                    return outfit({})
                end,
            },
            {
                label = "no slot list at all",
                build = function()
                    local subject = outfit({})
                    subject.slots = nil
                    return subject
                end,
            },
        }

        for _, case in ipairs(unbuilt) do
            it("reports unresolved for an outfit with " .. case.label, function()
                local resolver = newResolver({})

                assert.is_true(resolver.resolve(case.build()).unresolved)
            end)

            -- A 0/0 row is indistinguishable from "you have collected this entire set",
            -- the single most misleading thing the gallery could say about a loading set.
            it("never presents an outfit with " .. case.label .. " as a completed set", function()
                local resolver = newResolver({})

                local row = resolver.resolve(case.build())

                assert.equal(0, row.totalCount)
                assert.is_false(row.wearable)
            end)
        end

        it("reports unresolved when any one slot is still loading", function()
            local resolver = newResolver({ [1] = owned(1), [2] = pending(2) })

            assert.is_true(resolver.resolve(outfit({ 1, 2 })).unresolved)
        end)

        -- Not "unwearable" — the honest answer is that nobody knows yet, and the filter
        -- treats unresolved rows separately for exactly that reason.
        it("refuses to call a still-loading outfit wearable", function()
            local resolver = newResolver({ [1] = wearableOnly(1), [2] = pending(2) })

            assert.is_false(resolver.resolve(outfit({ 1, 2 })).wearable)
        end)

        it("marks the loading slot so the detail view can say so", function()
            local resolver = newResolver({ [1] = owned(1), [2] = pending(2) })

            local slots = resolver.resolve(outfit({ 1, 2 })).slots

            assert.is_falsy(slots[1].unresolved)
            assert.is_true(slots[2].unresolved)
        end)

        -- A provisional answer is cached like any other, just in a bucket that expires.
        -- Re-walking every slot of every still-loading set on every redraw is precisely
        -- what made the gallery stall while reading "Loading…" on every row.
        it("does not re-walk the slots before invalidatePending", function()
            local resolver, recorded = newResolver({ [1] = owned(1), [2] = pending(2) })
            local subject = outfit({ 1, 2 })

            resolver.resolve(subject)
            resolver.resolve(subject)
            resolver.resolve(subject)

            assert.equal(2, #recorded.resolved)
        end)

        it("re-walks the slots after invalidatePending", function()
            local resolver, recorded = newResolver({ [1] = owned(1), [2] = pending(2) })
            local subject = outfit({ 1, 2 })
            resolver.resolve(subject)

            resolver.invalidatePending()
            resolver.resolve(subject)

            assert.equal(4, #recorded.resolved)
        end)

        -- The appearance layer holds its own provisional answers, so invalidating only
        -- this one would re-walk the slots straight back into the same stale "not yet".
        it("invalidates the appearance resolver underneath it", function()
            local resolver, recorded = newResolver({ [1] = owned(1) })

            resolver.invalidatePending()

            assert.equal(1, recorded.invalidations)
        end)

        it("keeps a settled outfit across invalidatePending", function()
            local resolver, recorded = newResolver({ [1] = owned(1) })
            local subject = outfit({ 1 })
            assert.is_false(resolver.resolve(subject).unresolved)

            resolver.invalidatePending()
            resolver.resolve(subject)

            assert.equal(1, #recorded.resolved)
        end)

        it("resolves the outfit once the appearances arrive", function()
            local resolver, _, answers = newResolver({ [1] = owned(1) })
            local subject = outfit({ 1, 2 })
            assert.is_true(resolver.resolve(subject).unresolved)

            answers[2] = owned(2)
            resolver.invalidatePending()

            local row = resolver.resolve(subject)
            assert.is_false(row.unresolved)
            assert.equal(2, row.collectedCount)
            assert.is_true(row.wearable)
        end)
    end)

    describe("caching", function()
        it("resolves an outfit's slots once per session", function()
            local resolver, recorded = newResolver({ [1] = owned(1), [2] = owned(2) })
            local subject = outfit({ 1, 2 })

            resolver.resolve(subject)
            resolver.resolve(subject)
            resolver.resolve(subject)

            assert.equal(2, #recorded.resolved)
        end)

        it("caches per outfit id rather than per outfit handle", function()
            local resolver, recorded = newResolver({ [1] = owned(1) })

            resolver.resolve(outfit({ 1 }))
            resolver.resolve(outfit({ 1 }))

            assert.equal(1, #recorded.resolved)
        end)

        it("keeps separate answers for separate outfits", function()
            local resolver = newResolver({ [1] = owned(1), [2] = unwearable(2) })

            local first = resolver.resolve(outfit({ 1 }, { id = "blizzard:1" }))
            local second = resolver.resolve(outfit({ 2 }, { id = "blizzard:2" }))

            assert.is_true(first.wearable)
            assert.is_false(second.wearable)
        end)

        -- Collecting a piece changes both layers of the answer, so a refresh that stopped
        -- at this module's own cache would keep serving the stale appearance beneath it.
        it("drops its own cache on refresh", function()
            local resolver, recorded, answers = newResolver({ [1] = wearableOnly(1) })
            assert.equal(0, resolver.resolve(outfit({ 1 })).collectedCount)

            answers[1] = owned(1)
            resolver.refresh()

            assert.equal(1, resolver.resolve(outfit({ 1 })).collectedCount)
            assert.equal(2, #recorded.resolved)
        end)

        it("refreshes the appearance resolver underneath it", function()
            local resolver, recorded = newResolver({ [1] = owned(1) })

            resolver.refresh()

            assert.equal(1, recorded.refreshes)
        end)
    end)

    describe("over the real appearance resolver", function()
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

        ---@param appearanceSources table<number, AppearanceSourceInfo[]>
        ---@return CollectionResolver
        local function newWiredResolver(appearanceSources)
            local api = fake.newTransmogApi({ appearanceSources = appearanceSources })
            return ns.newCollectionResolver({ appearances = ns.newAppearanceResolver({ api = api }) })
        end

        -- Acceptance criterion 3 end to end: the set's own shoulders are class-locked, but
        -- an unrestricted leather item shares the visual, so the whole outfit is wearable.
        -- Both layers have to agree for the gallery filter to be right.
        it("calls a class set wearable through unrestricted lookalike sources", function()
            local resolver = newWiredResolver({
                [1] = { source(11, 1, { isValidSourceForPlayer = true, isCollected = true }) },
                [2] = {
                    source(20, 2, { isCollected = true }),
                    source(21, 2, { isValidSourceForPlayer = true, isCollected = true }),
                },
            })

            local row = resolver.resolve(outfit({ 1, 2 }))

            assert.is_true(row.wearable)
            assert.equal(2, row.collectedCount)
        end)

        it("calls the set unwearable when a slot has only class-locked sources", function()
            local resolver = newWiredResolver({
                [1] = { source(11, 1, { isValidSourceForPlayer = true, isCollected = true }) },
                [2] = { source(20, 2, { isCollected = true, canDisplayOnPlayer = true }) },
            })

            local row = resolver.resolve(outfit({ 1, 2 }))

            assert.is_false(row.wearable)
            assert.equal(1, row.collectedCount)
            assert.equal(1, row.missingCount)
        end)

        it("stays unresolved while the client has not listed a slot's sources", function()
            local resolver = newWiredResolver({
                [1] = { source(11, 1, { isValidSourceForPlayer = true, isCollected = true }) },
            })

            assert.is_true(resolver.resolve(outfit({ 1, 2 })).unresolved)
        end)
    end)
end)
