---Hand-written fakes for the slice of the WoW API the addon depends on.
---Everything here is injected through the same seams the game uses (WowEnv /
---BlizzardSetProviderDeps), so no monkey patching is needed anywhere.
local fake = {}

---A stand-in for `TransmogAPI`, driven by one readable config table.
---
---The config is read *live* on every call, so a test models the client streaming data in
---by mutating the very table it passed in: start with `items = {}`, let the addon read a
---set and get nothing, then fill `config.items[setID]` and read again. That is the whole
---reason this fake is not a frozen snapshot — retry-after-unavailable is core behaviour.
---
---Shape:
---  `sets`    `TransmogSetInfo[]?` — nil models a client that has not loaded the set list.
---  `items`   `table<number, TransmogSetItemInfo[]>` — per set; a missing key is unresolved.
---  `sources` `table<number, AppearanceSourceInfo>` — per sourceID; a missing key is unresolved.
---@param config table? `{ sets, items, sources }`
---@return TransmogAPI api
---@return table recorded `{ allSets = integer, setAppearances = number[], sourceInfo = number[] }`
function fake.newTransmogApi(config)
    config = config or {}
    local recorded = { allSets = 0, setAppearances = {}, sourceInfo = {} }

    local api = {}

    function api.getAllSets()
        recorded.allSets = recorded.allSets + 1
        return config.sets
    end

    function api.getSetAppearances(setID)
        recorded.setAppearances[#recorded.setAppearances + 1] = setID
        return (config.items or {})[setID]
    end

    function api.getSourceInfo(sourceID)
        recorded.sourceInfo[#recorded.sourceInfo + 1] = sourceID
        return (config.sources or {})[sourceID]
    end

    return api, recorded
end

---A complete fake WowEnv plus the recordings the test asserts on.
---
---`options.transmog` accepts the same config table `newTransmogApi` does, so a boot test
---can declare the client's set data inline.
---@param options table? `{ transmog = table?, db = table? }`
---@return table env
---@return table recorded `{ lines = string[], db = table, transmog = table }`
function fake.newEnv(options)
    options = options or {}
    local lines = {}
    local db = options.db or {}
    local transmog, transmogRecorded = fake.newTransmogApi(options.transmog)

    local env = {
        print = function(message)
            lines[#lines + 1] = message
        end,
        transmog = transmog,
        db = db,
    }

    return env, {
        lines = lines,
        db = db,
        transmog = transmogRecorded,
        ---The adapter table itself, so a test can prove the provider calls *this* object
        ---rather than a global it reached for behind the seam's back.
        transmogApi = transmog,
    }
end

return fake
