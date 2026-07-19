local loader = require("addon_loader")
local fake = require("fake_wow")

describe("ns.newWardrobeTab", function()
    local ns = loader.load()

    ---@param config table? as `fake.newCollectionsApi` takes
    ---@param overrides table? `{ logger }`
    ---@return WardrobeTab tab
    ---@return table collections recorded
    ---@return table embedded recorded, as `fake.newEmbeddedGalleryFactory` returns
    local function newTab(config, overrides)
        overrides = overrides or {}
        local collections, collectionsRecorded = fake.newCollectionsApi(config)
        local newEmbeddedGallery, embeddedRecorded = fake.newEmbeddedGalleryFactory()

        local tab = ns.newWardrobeTab({
            collections = collections,
            newEmbeddedGallery = newEmbeddedGallery,
            logger = overrides.logger,
        })

        return tab, collectionsRecorded, embeddedRecorded
    end

    it("is exported by the addon files", function()
        assert.is_function(ns.newWardrobeTab)
    end)

    describe("attaching to a Collections that is already loaded", function()
        it("attaches", function()
            local tab = newTab({ loaded = true })

            assert.is_true(tab.attach())
        end)

        it("reports itself attached afterwards", function()
            local tab = newTab({ loaded = true })

            tab.attach()

            assert.is_true(tab.isAttached())
        end)

        it("adds exactly one tab to the wardrobe frame", function()
            local tab, collections = newTab({ loaded = true })

            tab.attach()

            assert.equal(1, #collections.tabs)
        end)

        it("gives the tab a label the player can read", function()
            local tab, collections = newTab({ loaded = true })

            tab.attach()

            assert.is_string(collections.tabs[1].label)
            assert.is_true(#collections.tabs[1].label > 0)
        end)

        -- Attaching twice would leave two tabs stacked on the panel.
        it("does not add a second tab on a second attach", function()
            local tab, collections = newTab({ loaded = true })

            tab.attach()
            tab.attach()

            assert.equal(1, #collections.tabs)
        end)

        it("builds exactly one embedded gallery", function()
            local tab, _, embedded = newTab({ loaded = true })

            tab.attach()
            tab.attach()

            assert.equal(1, embedded.calls())
        end)

        it("shows the embedded gallery when the tab is selected", function()
            local tab, collections, embedded = newTab({ loaded = true })
            tab.attach()

            collections.tabs[1].onSelect()

            assert.equal(1, embedded.last().shows)
        end)

        -- Picking one of Blizzard's own tabs has to put the gallery away again, or it
        -- would sit on top of the panel the player just asked for.
        it("hides the embedded gallery when the tab is deselected", function()
            local tab, collections, embedded = newTab({ loaded = true })
            tab.attach()

            collections.tabs[1].onDeselect()

            assert.equal(1, embedded.last().hides)
        end)
    end)

    ---The regression. A single gallery that worked out at build time whether it was
    ---embedded parented its "standalone" window to the hidden Wardrobe panel and showed
    ---the player nothing at all. Embedding is now decided at construction, which only
    ---holds while the tab builds its own frame and never reaches for anyone else's.
    describe("the frame it drives", function()
        it("builds the embedded gallery against the host Collections handed over", function()
            local tab, collections, embedded = newTab({ loaded = true })

            tab.attach()

            assert.equal(collections.host, embedded.hosts[1])
        end)

        -- `getGalleryHost` is optional on the interface, so a client without one still has
        -- to get a gallery — parented to the wardrobe frame itself.
        it("falls back to the wardrobe frame when Collections exposes no gallery host", function()
            local tab, collections, embedded = newTab({ loaded = true, galleryHost = false })

            tab.attach()

            assert.equal(collections.wardrobe, embedded.hosts[1])
        end)

        -- Built before the tab exists, because the tab's own onSelect closes over it.
        it("builds the embedded gallery before asking for a tab", function()
            local order = {}
            local collections = fake.newCollectionsApi({ loaded = true })
            local addTab = collections.addTab
            collections.addTab = function(...)
                order[#order + 1] = "addTab"
                return addTab(...)
            end

            local tab = ns.newWardrobeTab({
                collections = collections,
                newEmbeddedGallery = function()
                    order[#order + 1] = "gallery"
                    return fake.newGallery()
                end,
            })
            tab.attach()

            assert.same({ "gallery", "addTab" }, order)
        end)

        -- The standalone window belongs to whoever built it. Reaching for it from here is
        -- precisely what made a failed attach show an invisible window instead of falling
        -- back, so the tab is not even given one.
        it("never touches a standalone gallery, in any path", function()
            local collections, collectionsRecorded = fake.newCollectionsApi({ loaded = true })
            local newEmbeddedGallery = fake.newEmbeddedGalleryFactory()

            local tab = ns.newWardrobeTab({
                collections = collections,
                newEmbeddedGallery = newEmbeddedGallery,
                gallery = fake.newForbidden("the standalone gallery"),
            })

            assert.has_no.errors(function()
                tab.attach()
                tab.select()
                collectionsRecorded.tabs[1].onSelect()
                collectionsRecorded.tabs[1].onDeselect()
            end)
        end)
    end)

    describe("a Collections that is not loaded yet", function()
        -- Blizzard_Collections is load-on-demand: it does not exist at login, and it may
        -- never exist in a session where the player never opens their collections.
        it("cannot attach", function()
            local tab = newTab()

            assert.is_false(tab.attach())
        end)

        it("reports itself unattached", function()
            local tab = newTab()

            tab.attach()

            assert.is_false(tab.isAttached())
        end)

        it("adds no tab to anything", function()
            local tab, collections = newTab()

            tab.attach()

            assert.equal(0, #collections.tabs)
        end)

        -- A gallery built before there is a panel to put it in is a gallery parented to
        -- nothing, which is the shape the original bug took.
        it("builds no embedded gallery", function()
            local tab, _, embedded = newTab()

            tab.attach()

            assert.equal(0, embedded.calls())
        end)

        -- Registered at construction, not on the first attach: the player may open their
        -- collections at any point in the session and the tab has to be there when they do.
        it("registers interest in the addon loading, at construction", function()
            local _, collections = newTab()

            assert.equal(1, #collections.callbacks)
        end)

        it("registers no such interest when Collections is already loaded", function()
            local _, collections = newTab({ loaded = true })

            assert.equal(0, #collections.callbacks)
        end)

        it("attaches itself when the client finishes loading Collections", function()
            local tab, collections = newTab()

            collections.deliver()

            assert.is_true(tab.isAttached())
            assert.equal(1, #collections.tabs)
        end)
    end)

    ---The risky part. A gallery that breaks the default Appearances panel is far worse
    ---than one the player has to type `/ff` to reach, so every failure here has to report
    ---itself to the caller rather than erroring, retrying forever, or quietly showing a
    ---frame the player cannot see.
    describe("a Collections whose UI we do not recognise", function()
        ---@type { label: string, config: table }[]
        local broken = {
            { label = "the wardrobe frame is missing", config = { loaded = true, wardrobe = false } },
            { label = "the tab cannot be added", config = { loaded = true, tab = false } },
        }

        for _, case in ipairs(broken) do
            it("fails to attach when " .. case.label, function()
                local tab = newTab(case.config)

                assert.is_false(tab.attach())
            end)

            it("does not error when " .. case.label, function()
                local tab = newTab(case.config)

                assert.has_no.errors(function()
                    tab.attach()
                end)
            end)

            it("reports itself unattached when " .. case.label, function()
                local tab = newTab(case.config)

                tab.attach()

                assert.is_false(tab.isAttached())
            end)

            -- The reason it failed is a UI that does not expose what we need, which will
            -- not change within a session. Retrying on every click is pure waste.
            it("gives up permanently when " .. case.label, function()
                local tab, collections = newTab(case.config)

                tab.attach()
                tab.attach()
                tab.attach()

                assert.is_true(#collections.tabs <= 1)
            end)

            -- The caller owns the fallback, and it only runs on a falsy answer.
            it("reports select as false when " .. case.label, function()
                local tab = newTab(case.config)

                assert.is_false(tab.select())
            end)

            it("shows no gallery at all when " .. case.label, function()
                local tab, _, embedded = newTab(case.config)

                tab.select()

                for _, gallery in ipairs(embedded.galleries) do
                    assert.equal(0, gallery.shows)
                    assert.equal(0, gallery.toggles)
                end
            end)
        end

        -- Half an attach is worse than none. The gallery is built before `addTab` is
        -- asked — the tab's handlers have to close over it — so a refused tab leaves one
        -- orphaned behind, and nothing may ever drive it: there is no tab to reveal it, and
        -- showing it would draw into a panel the player cannot reach.
        --
        -- The module also drops its reference (`embedded = nil`), which this cannot see:
        -- the orphan is never handed out, so releasing it is GC hygiene rather than
        -- behaviour. What is checkable is that it stays dark through every later call.
        it("never drives the orphaned gallery when the tab cannot be added", function()
            local tab, _, embedded = newTab({ loaded = true, tab = false })

            tab.attach()
            tab.attach()
            tab.select()

            assert.equal(1, embedded.calls())
            assert.equal(0, embedded.last().shows)
            assert.equal(0, embedded.last().hides)
            assert.equal(0, embedded.last().toggles)
            assert.is_false(tab.isAttached())
        end)

        it("builds no further galleries once it has given up", function()
            local tab, _, embedded = newTab({ loaded = true, tab = false })

            tab.attach()
            tab.attach()
            tab.select()

            assert.equal(1, embedded.calls())
        end)
    end)

    describe("select", function()
        -- Loading Collections is deferred all the way to here, so a player who never asks
        -- for the gallery never pays for Blizzard's addon being loaded.
        it("loads Collections on demand", function()
            local tab, collections = newTab()

            tab.select()

            assert.equal(1, collections.loads)
        end)

        it("does not load Collections again once it is loaded", function()
            local tab, collections = newTab({ loaded = true })

            tab.select()

            assert.equal(0, collections.loads)
        end)

        it("attaches on the way through", function()
            local tab = newTab()

            tab.select()

            assert.is_true(tab.isAttached())
        end)

        it("reports success", function()
            local tab = newTab({ loaded = true })

            assert.is_true(tab.select())
        end)

        it("opens the Collections panel", function()
            local tab, collections = newTab({ loaded = true })

            tab.select()

            assert.equal(1, collections.opened)
        end)

        it("clicks the gallery tab so the panel lands on it", function()
            local tab, collections = newTab({ loaded = true })

            tab.select()

            assert.equal(1, collections.tabClicks)
        end)

        it("shows the embedded gallery through that click", function()
            local tab, _, embedded = newTab({ loaded = true })

            tab.select()

            assert.equal(1, embedded.last().shows)
        end)

        -- A client that refuses to load the addon is not an error the player should see;
        -- it is the caller's cue to open the standalone gallery, which works everywhere.
        it("reports false when Collections will not load", function()
            local tab = newTab({ loadable = false })

            assert.is_false(tab.select())
        end)

        it("opens no panel when Collections will not load", function()
            local tab, collections = newTab({ loadable = false })

            tab.select()

            assert.equal(0, collections.opened)
        end)

        -- Nothing to parent a gallery to, so nothing may be built: a frame created here
        -- would be the invisible one the whole redesign exists to prevent.
        it("builds no embedded gallery when Collections will not load", function()
            local tab, _, embedded = newTab({ loadable = false })

            tab.select()

            assert.equal(0, embedded.calls())
        end)

        it("keeps working on repeated selects", function()
            local tab, collections = newTab({ loaded = true })

            tab.select()
            tab.select()

            assert.equal(2, collections.opened)
            assert.equal(2, collections.tabClicks)
            assert.equal(1, #collections.tabs)
        end)

        it("reuses the one embedded gallery across repeated selects", function()
            local tab, _, embedded = newTab({ loaded = true })

            tab.select()
            tab.select()

            assert.equal(1, embedded.calls())
            assert.equal(2, embedded.last().shows)
        end)
    end)

    describe("the logger seam", function()
        it("constructs without a logger at all", function()
            local collections = fake.newCollectionsApi({ loaded = true })
            local newEmbeddedGallery = fake.newEmbeddedGalleryFactory()

            local tab = ns.newWardrobeTab({
                collections = collections,
                newEmbeddedGallery = newEmbeddedGallery,
            })

            assert.is_true(tab.attach())
        end)

        it("explains a failed attach through the injected logger", function()
            local lines = {}
            local tab = newTab({ loaded = true, wardrobe = false }, {
                logger = {
                    info = function() end,
                    debug = function(message)
                        lines[#lines + 1] = message
                    end,
                },
            })

            tab.attach()

            assert.equal(1, #lines)
            assert.is_truthy(lines[1]:find("standalone", 1, true))
        end)
    end)
end)
