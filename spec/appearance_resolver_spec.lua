local loader = require("addon_loader")
local fake = require("fake_wow")

describe("ns.newAppearanceResolver", function()
    local ns = loader.load()

    local VISUAL_ID = 77

    ---One way to wear a look. The three client flags are three *separate* questions —
    ---may this character transmog it, does the account own it, will the game draw it —
    ---and the resolver's whole job is keeping them apart.
    ---@param sourceID number
    ---@param overrides table?
    ---@return AppearanceSourceInfo
    local function source(sourceID, overrides)
        local info = {
            sourceID = sourceID,
            visualID = VISUAL_ID,
            isValidSourceForPlayer = false,
            isCollected = false,
            canDisplayOnPlayer = false,
        }
        for key, value in pairs(overrides or {}) do
            info[key] = value
        end
        return info
    end

    ---Owned by the account *and* wearable by this character: the only combination that
    ---counts as collected per SPEC "Definitions".
    ---@param sourceID number
    ---@return AppearanceSourceInfo
    local function ownedUsable(sourceID)
        return source(sourceID, { isValidSourceForPlayer = true, isCollected = true, canDisplayOnPlayer = true })
    end

    ---Wearable by this character but not yet collected — good enough for a preview.
    ---@param sourceID number
    ---@return AppearanceSourceInfo
    local function unownedUsable(sourceID)
        return source(sourceID, { isValidSourceForPlayer = true, canDisplayOnPlayer = true })
    end

    ---The account owns it, but this character cannot put it on: a Druid tier piece in a
    ---Rogue's wardrobe.
    ---@param sourceID number
    ---@return AppearanceSourceInfo
    local function ownedUnusable(sourceID)
        return source(sourceID, { isCollected = true })
    end

    ---Nothing legal about it, but the client will still draw it on the model.
    ---@param sourceID number
    ---@return AppearanceSourceInfo
    local function displayableOnly(sourceID)
        return source(sourceID, { canDisplayOnPlayer = true })
    end

    ---Builds a resolver over a fake client. The config table is handed back so a test can
    ---mutate it mid-run and model sources streaming in after a failed read.
    ---@param sources AppearanceSourceInfo[]? nil models a client with no answer yet
    ---@return AppearanceResolver resolver
    ---@return table recorded
    ---@return table config the very table the fake keeps reading
    local function newResolver(sources)
        local config = { appearanceSources = {} }
        if sources then
            config.appearanceSources[VISUAL_ID] = sources
        end
        local api, recorded = fake.newTransmogApi(config)
        return ns.newAppearanceResolver({ api = api }), recorded, config
    end

    it("is exported by the addon files", function()
        assert.is_function(ns.newAppearanceResolver)
    end)

    describe("choosing between the ways to wear a look", function()
        it("resolves a visual the character owns and can wear", function()
            local resolver = newResolver({ ownedUsable(1) })

            local resolution = resolver.resolve(VISUAL_ID)

            assert.equal(1, resolution.resolvedSourceID)
            assert.is_true(resolution.usable)
            assert.is_true(resolution.collected)
            assert.is_false(resolution.unresolved)
        end)

        it("reports the appearance it was asked about", function()
            local resolver = newResolver({ ownedUsable(1) })

            assert.equal(VISUAL_ID, resolver.resolve(VISUAL_ID).appearanceID)
        end)

        -- Order in the client's list is arbitrary. Preferring the owned source keeps the
        -- preview on something the player can actually buy today rather than on a piece
        -- they would have to farm first.
        it("prefers the collected source over an uncollected one listed before it", function()
            local resolver = newResolver({ unownedUsable(1), ownedUsable(2) })

            assert.equal(2, resolver.resolve(VISUAL_ID).resolvedSourceID)
        end)

        it("counts the look as collected when the owned source is listed last", function()
            local resolver = newResolver({ unownedUsable(1), unownedUsable(2), ownedUsable(3) })

            assert.is_true(resolver.resolve(VISUAL_ID).collected)
        end)

        it("settles for a wearable but uncollected source when the account owns none", function()
            local resolver = newResolver({ unownedUsable(1) })

            assert.equal(1, resolver.resolve(VISUAL_ID).resolvedSourceID)
            assert.is_true(resolver.resolve(VISUAL_ID).usable)
            assert.is_false(resolver.resolve(VISUAL_ID).collected)
        end)

        -- A source row with no sourceID is a row nothing downstream can apply to a slot.
        it("ignores a source the client has not given an id yet", function()
            local resolver = newResolver({ source(nil, { isValidSourceForPlayer = true }), ownedUsable(2) })

            assert.equal(2, resolver.resolve(VISUAL_ID).resolvedSourceID)
        end)
    end)

    describe("the Rogue wearing a Druid set", function()
        -- Acceptance criterion 3, at the appearance level: the item the set names is
        -- class-locked, but an unrestricted leather item shares the visual. The look is
        -- therefore reproducible, and answering otherwise would hide the set from the
        -- gallery for exactly the players this addon exists for.
        it("is wearable through an alternative source when the set's own item is not", function()
            local setPiece = ownedUnusable(1)
            local lookalike = ownedUsable(2)
            local resolver = newResolver({ setPiece, lookalike })

            local resolution = resolver.resolve(VISUAL_ID, 1)

            assert.is_true(resolution.usable)
        end)

        it("hands the preview the alternative rather than the set's own item", function()
            local resolver = newResolver({ ownedUnusable(1), ownedUsable(2) })

            assert.equal(2, resolver.resolve(VISUAL_ID, 1).resolvedSourceID)
        end)

        it("counts the look as collected through the alternative source", function()
            local resolver = newResolver({ ownedUnusable(1), ownedUsable(2) })

            assert.is_true(resolver.resolve(VISUAL_ID, 1).collected)
        end)
    end)

    describe("a look this character cannot wear", function()
        -- SPEC "Definitions": owning a source the character cannot use does not satisfy
        -- character-specific collected state. Counting it would show a Rogue a Druid set
        -- as complete and then fail at the transmog vendor.
        it("does not count an owned but unusable source as collected", function()
            local resolver = newResolver({ ownedUnusable(1) })

            assert.is_false(resolver.resolve(VISUAL_ID).collected)
        end)

        it("does not call an owned but unusable source wearable", function()
            local resolver = newResolver({ ownedUnusable(1) })

            assert.is_false(resolver.resolve(VISUAL_ID).usable)
        end)

        it("is a real answer, not an unresolved one", function()
            local resolver = newResolver({ ownedUnusable(1) })

            assert.is_false(resolver.resolve(VISUAL_ID).unresolved)
        end)

        -- The preview may still show a look the character cannot legally transmog; the
        -- row just must not claim it is wearable.
        it("still hands the preview a source the client will draw", function()
            local resolver = newResolver({ ownedUnusable(1), displayableOnly(2) })

            local resolution = resolver.resolve(VISUAL_ID)

            assert.equal(2, resolution.resolvedSourceID)
            assert.is_false(resolution.usable)
        end)

        it("prefers any wearable source over a merely displayable one", function()
            local resolver = newResolver({ displayableOnly(1), unownedUsable(2) })

            assert.equal(2, resolver.resolve(VISUAL_ID).resolvedSourceID)
        end)

        -- The set's own item is the last guess, not the first: if the client offered
        -- nothing at all, the preview is better off trying the piece Blizzard shipped
        -- than showing an empty slot.
        it("falls back to the preferred source when no source qualifies", function()
            local resolver = newResolver({ ownedUnusable(1) })

            assert.equal(99, resolver.resolve(VISUAL_ID, 99).resolvedSourceID)
        end)

        it("resolves to nothing when there is no preferred source either", function()
            local resolver = newResolver({ ownedUnusable(1) })

            assert.is_nil(resolver.resolve(VISUAL_ID).resolvedSourceID)
        end)
    end)

    describe("data the client has not streamed in yet", function()
        ---@type { label: string, sources: AppearanceSourceInfo[]? }[]
        local silences = {
            { label = "has no answer at all", sources = nil },
            -- Every real visual has at least the source it came from, so an empty list is
            -- the client saying "not yet" in its other voice.
            { label = "answers with an empty list", sources = {} },
        }

        for _, case in ipairs(silences) do
            it("reports unresolved when the client " .. case.label, function()
                local resolver = newResolver(case.sources)

                assert.is_true(resolver.resolve(VISUAL_ID).unresolved)
            end)

            it("claims neither usable nor collected when the client " .. case.label, function()
                local resolver = newResolver(case.sources)

                local resolution = resolver.resolve(VISUAL_ID)

                assert.is_false(resolution.usable)
                assert.is_false(resolution.collected)
            end)

            -- Caching "not yet" would freeze the lie in for the whole session: the set
            -- would stay greyed out until a /reload.
            it("asks again on the next read when the client " .. case.label, function()
                local resolver, recorded = newResolver(case.sources)

                resolver.resolve(VISUAL_ID)
                resolver.resolve(VISUAL_ID)

                assert.equal(2, #recorded.appearanceSources)
            end)

            it("resolves once the sources arrive after the client " .. case.label, function()
                local resolver, _, config = newResolver(case.sources)
                assert.is_true(resolver.resolve(VISUAL_ID).unresolved)

                config.appearanceSources[VISUAL_ID] = { ownedUsable(1) }

                local resolution = resolver.resolve(VISUAL_ID)
                assert.is_false(resolution.unresolved)
                assert.is_true(resolution.collected)
            end)
        end
    end)

    describe("caching", function()
        -- Resolution walks the full source list for a visual; a gallery of hundreds of
        -- sets sharing shoulder appearances would pay that repeatedly without the cache.
        it("asks the client once for a visual it has already answered", function()
            local resolver, recorded = newResolver({ ownedUsable(1) })

            resolver.resolve(VISUAL_ID)
            resolver.resolve(VISUAL_ID)
            resolver.resolve(VISUAL_ID)

            assert.equal(1, #recorded.appearanceSources)
        end)

        it("serves the same answer from the cache", function()
            local resolver, _, config = newResolver({ ownedUsable(1) })
            assert.equal(1, resolver.resolve(VISUAL_ID).resolvedSourceID)

            config.appearanceSources[VISUAL_ID] = { ownedUsable(2) }

            assert.equal(1, resolver.resolve(VISUAL_ID).resolvedSourceID)
        end)

        it("caches an answer of 'this character cannot wear it' like any other", function()
            local resolver, recorded = newResolver({ ownedUnusable(1) })

            resolver.resolve(VISUAL_ID)
            resolver.resolve(VISUAL_ID)

            assert.equal(1, #recorded.appearanceSources)
        end)

        -- The player collecting a piece is precisely when the cached answer goes stale.
        it("re-reads the client after a refresh", function()
            local resolver, recorded, config = newResolver({ unownedUsable(1) })
            assert.is_false(resolver.resolve(VISUAL_ID).collected)

            config.appearanceSources[VISUAL_ID] = { ownedUsable(1) }
            resolver.refresh()

            assert.is_true(resolver.resolve(VISUAL_ID).collected)
            assert.equal(2, #recorded.appearanceSources)
        end)
    end)

    describe("the logger seam", function()
        it("constructs without a logger at all", function()
            local api = fake.newTransmogApi({})
            local resolver = ns.newAppearanceResolver({ api = api })

            assert.is_true(resolver.resolve(VISUAL_ID).unresolved)
        end)

        it("reports unresolved sources through the injected logger", function()
            local lines = {}
            local api = fake.newTransmogApi({})
            local resolver = ns.newAppearanceResolver({
                api = api,
                logger = {
                    info = function() end,
                    debug = function(message)
                        lines[#lines + 1] = message
                    end,
                },
            })

            resolver.resolve(VISUAL_ID)

            assert.equal(1, #lines)
            assert.is_truthy(lines[1]:find("not available yet", 1, true))
        end)
    end)
end)
