local loader = require("addon_loader")
local fake = require("fake_wow")

describe("addon integration", function()
    ---Boot the addon exactly as the client does: every .toc file, in order, then hand
    ---ns.main a fake outside world.
    ---@param options table? `{ addonName = string?, transmog = table?, db = table? }`
    ---@return table app, table recorded
    local function boot(options)
        options = options or {}
        local ns = loader.load(options.addonName)
        local env, recorded = fake.newEnv(options)
        return ns.main(env), recorded
    end

    ---@param setID number
    ---@param name string
    ---@return TransmogSetInfo
    local function set(setID, name)
        return { setID = setID, name = name, baseSetID = setID }
    end

    describe("loading", function()
        it("populates the namespace with every constructor", function()
            local ns = loader.load()

            assert.is_function(ns.newLogger)
            assert.is_function(ns.newBlizzardSetProvider)
            assert.is_function(ns.outfitId)
            assert.is_function(ns.main)
        end)

        it("does not auto-start outside the game", function()
            local ns = loader.load()

            assert.is_nil(ns.app)
        end)
    end)

    describe("wiring", function()
        it("exposes the modules it wired to the caller", function()
            local app = boot()

            assert.is_function(app.logger.info)
            assert.is_function(app.blizzardSets.getOutfits)
            assert.is_function(app.blizzardSets.getOutfit)
        end)

        it("lists the Blizzard provider among the gallery's providers", function()
            local app = boot()

            assert.equal(1, #app.providers)
            assert.equal(app.blizzardSets, app.providers[1])
        end)

        -- Every provider is read through the same interface, so the gallery never has to
        -- learn where an outfit came from when community outfits join the list.
        it("gives every provider the OutfitProvider interface", function()
            local app = boot()

            for _, provider in ipairs(app.providers) do
                assert.is_function(provider.getOutfits)
                assert.is_function(provider.getOutfit)
            end
        end)

        it("prefixes the logger with the addon name", function()
            local app, recorded = boot({ addonName = "fast-fashion" })

            app.logger.info("hello")

            assert.equal("|cff33ff99fast-fashion|r: hello", recorded.lines[1])
        end)

        it("prints nothing merely by booting", function()
            local _, recorded = boot()

            assert.same({}, recorded.lines)
        end)
    end)

    describe("the injected transmog adapter", function()
        it("is what the provider actually reads its sets from", function()
            local app, recorded = boot({
                transmog = { sets = { set(1, "Judgement"), set(2, "Bloodfang") } },
            })

            local outfits = app.blizzardSets.getOutfits()

            assert.same({ "blizzard:1", "blizzard:2" }, { outfits[1].id, outfits[2].id })
            assert.equal(1, recorded.transmog.allSets)
        end)

        it("is not touched at all until something asks for outfits", function()
            local _, recorded = boot({ transmog = { sets = { set(1, "Judgement") } } })

            assert.equal(0, recorded.transmog.allSets)
            assert.same({}, recorded.transmog.setAppearances)
        end)

        it("resolves slots through the same adapter", function()
            local app, recorded = boot({
                transmog = {
                    sets = { set(1, "Judgement") },
                    items = { [1] = { { itemID = 10, itemModifiedAppearanceID = 5, invSlot = 1 } } },
                    sources = { [5] = { visualID = 77 } },
                },
            })

            assert.equal(77, app.blizzardSets.getOutfits()[1].slots[1].appearanceID)
            assert.same({ 1 }, recorded.transmog.setAppearances)
            assert.same({ 5 }, recorded.transmog.sourceInfo)
        end)
    end)

    describe("the logger's SavedVariables flag", function()
        ---@param db table
        ---@return string[] the lines the addon printed
        local function bootAndDebug(db)
            local app, recorded = boot({ db = db })
            app.logger.debug("streaming")
            return recorded.lines
        end

        it("stays quiet when the db does not ask for debug logging", function()
            assert.same({}, bootAndDebug({}))
        end)

        it("emits debug lines when the db asks for them", function()
            local lines = bootAndDebug({ debug = true })

            assert.equal(1, #lines)
            assert.is_truthy(lines[1]:find("streaming", 1, true))
        end)
    end)

    describe("the .toc manifest", function()
        local ROOT = (debug.getinfo(1, "S").source:match("@(.*/)") or "./") .. "../"

        ---@return string[] every .lua file under src/, as `src/Name.lua`
        local function srcFiles()
            local files = {}
            local pipe = assert(io.popen("ls " .. ROOT .. "src"))
            for name in pipe:lines() do
                if name:match("%.lua$") then
                    files[#files + 1] = "src/" .. name
                end
            end
            pipe:close()
            return files
        end

        it("lists every src file plus Main.lua", function()
            local listed = {}
            for _, path in ipairs(loader.tocFiles()) do
                listed[path] = true
            end

            for _, path in ipairs(srcFiles()) do
                assert.is_true(listed[path] == true, path .. " is missing from fast-fashion.toc")
            end
            assert.is_true(listed["Main.lua"] == true, "Main.lua is missing from fast-fashion.toc")
        end)

        it("lists no file that does not exist on disk", function()
            for _, path in ipairs(loader.tocFiles()) do
                local handle = io.open(ROOT .. path, "r")
                assert.is_truthy(handle, path .. " is listed in fast-fashion.toc but does not exist")
                handle:close()
            end
        end)

        it("loads Main.lua last, so the modules exist when it wires them", function()
            local files = loader.tocFiles()

            assert.equal("Main.lua", files[#files])
        end)
    end)
end)
