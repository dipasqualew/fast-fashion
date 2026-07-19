local loader = require("addon_loader")
local fake = require("fake_wow")

describe("ns.newWardrobeTab", function()
    local ns = loader.load()

    ---A stub `GalleryFrame`. The tab only ever shows, hides or toggles it, so counting
    ---those three is the whole contract between them — and `toggles` in particular is how
    ---a test proves the addon fell back to its standalone window.
    ---@return GalleryFrame gallery, table recorded `{ shows, hides, toggles }`
    local function newStubGallery()
        local recorded = { shows = 0, hides = 0, toggles = 0 }

        local gallery = {
            show = function()
                recorded.shows = recorded.shows + 1
            end,

            hide = function()
                recorded.hides = recorded.hides + 1
            end,

            toggle = function()
                recorded.toggles = recorded.toggles + 1
            end,
        }

        return gallery, recorded
    end

    ---@param config table? as `fake.newCollectionsApi` takes
    ---@return WardrobeTab tab
    ---@return table collections recorded
    ---@return table gallery recorded
    local function newTab(config)
        local collections, collectionsRecorded = fake.newCollectionsApi(config)
        local gallery, galleryRecorded = newStubGallery()

        local tab = ns.newWardrobeTab({
            collections = collections,
            gallery = gallery,
        })

        return tab, collectionsRecorded, galleryRecorded
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

        it("shows the gallery when the tab is selected", function()
            local tab, collections, gallery = newTab({ loaded = true })
            tab.attach()

            collections.tabs[1].onSelect()

            assert.equal(1, gallery.shows)
        end)

        -- Picking one of Blizzard's own tabs has to put the gallery away again, or it
        -- would sit on top of the panel the player just asked for.
        it("hides the gallery when the tab is deselected", function()
            local tab, collections, gallery = newTab({ loaded = true })
            tab.attach()

            collections.tabs[1].onDeselect()

            assert.equal(1, gallery.hides)
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
    ---than one the player has to type `/ff` to reach, so every failure here has to fall
    ---back to the standalone window rather than erroring or retrying forever.
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

            it("falls back to the standalone window when " .. case.label, function()
                local tab, _, gallery = newTab(case.config)

                tab.select()

                assert.equal(1, gallery.toggles)
            end)
        end
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

        it("leaves the standalone window alone when the tab worked", function()
            local tab, _, gallery = newTab({ loaded = true })

            tab.select()

            assert.equal(0, gallery.toggles)
        end)

        -- A client that refuses to load the addon is not an error the player should see;
        -- it is the standalone gallery, which works everywhere.
        it("falls back to the standalone window when Collections will not load", function()
            local tab, collections, gallery = newTab({ loadable = false })

            tab.select()

            assert.equal(1, gallery.toggles)
            assert.equal(0, collections.opened)
        end)

        it("keeps working on repeated selects", function()
            local tab, collections = newTab({ loaded = true })

            tab.select()
            tab.select()

            assert.equal(2, collections.opened)
            assert.equal(2, collections.tabClicks)
            assert.equal(1, #collections.tabs)
        end)
    end)

    describe("the logger seam", function()
        it("constructs without a logger at all", function()
            local collections = fake.newCollectionsApi({ loaded = true })
            local gallery = newStubGallery()

            local tab = ns.newWardrobeTab({ collections = collections, gallery = gallery })

            assert.is_true(tab.attach())
        end)

        it("explains a failed attach through the injected logger", function()
            local lines = {}
            local collections = fake.newCollectionsApi({ loaded = true, wardrobe = false })
            local gallery = newStubGallery()

            local tab = ns.newWardrobeTab({
                collections = collections,
                gallery = gallery,
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
