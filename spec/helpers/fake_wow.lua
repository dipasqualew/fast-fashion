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
---  `appearanceSources` `table<number, AppearanceSourceInfo[]>` — per visualID; every way to
---    wear that look. A missing key is unresolved; an empty list is the client's other way
---    of saying the same thing.
---@param config table? `{ sets, items, sources, appearanceSources }`
---@return TransmogAPI api
---@return table recorded `{ allSets, setAppearances, sourceInfo, appearanceSources }`
function fake.newTransmogApi(config)
    config = config or {}
    local recorded = { allSets = 0, setAppearances = {}, sourceInfo = {}, appearanceSources = {} }

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

    function api.getAppearanceSources(appearanceID)
        recorded.appearanceSources[#recorded.appearanceSources + 1] = appearanceID
        return (config.appearanceSources or {})[appearanceID]
    end

    return api, recorded
end

---A stand-in widget.
---
---Frame code is only worth calling "thin" if something can drive it, so this fake answers
---the whole widget protocol rather than the handful of methods used today: unknown methods
---are no-ops, which keeps a spec from failing the moment the frame gains a `SetAlpha`.
---The methods tests actually assert on — text, visibility, enablement, click handlers —
---are real and recorded.
---@param kind string
---@param name string?
---@return table widget
local function newWidget(kind, name)
    local widget = {
        kind = kind,
        name = name,
        text = nil,
        shown = true,
        enabled = true,
        scripts = {},
        children = {},
        regions = {},
        textColor = nil,
    }

    function widget.SetText(self, value)
        self.text = value
    end

    function widget.GetText(self)
        return self.text
    end

    function widget.SetTextColor(self, r, g, b)
        self.textColor = { r, g, b }
    end

    function widget.Show(self)
        self.shown = true
    end

    function widget.Hide(self)
        self.shown = false
    end

    function widget.IsShown(self)
        return self.shown
    end

    function widget.SetEnabled(self, value)
        self.enabled = value and true or false
    end

    function widget.IsEnabled(self)
        return self.enabled
    end

    function widget.SetScript(self, event, handler)
        self.scripts[event] = handler
    end

    function widget.SetMinMaxValues(self, minimum, maximum)
        self.minValue = minimum
        self.maxValue = maximum
    end

    ---Fires OnValueChanged, exactly as the client does. That fidelity is the point: a
    ---slider that stayed silent here would let an unguarded redraw-syncs-the-bar feedback
    ---loop pass the suite and only blow the stack in game.
    function widget.SetValue(self, value)
        self.value = value
        local handler = self.scripts.OnValueChanged
        if handler then
            handler(self, value)
        end
    end

    function widget.GetValue(self)
        return self.value
    end

    function widget.GetScript(self, event)
        return self.scripts[event]
    end

    ---Fires a handler the way the client would, passing the widget as self.
    function widget.Click(self)
        local handler = self.scripts.OnClick
        assert(handler, "widget has no OnClick handler")
        handler(self)
    end

    function widget.GetTextWidth(self)
        return #(self.text or "") * 6
    end

    function widget.CreateFontString(self, fontName)
        local region = newWidget("FontString", fontName)
        -- Font strings start blank; only an explicit SetText gives them content.
        region.text = nil
        self.regions[#self.regions + 1] = region
        return region
    end

    function widget.CreateTexture(self)
        local region = newWidget("Texture")
        self.regions[#self.regions + 1] = region
        return region
    end

    return setmetatable(widget, {
        ---Any widget method the addon reaches for that this fake has not modelled is a
        ---no-op returning the widget, so layout calls chain harmlessly.
        __index = function(self, key)
            if type(key) ~= "string" then
                return nil
            end
            local method = function()
                return self
            end
            rawset(self, key, method)
            return method
        end,
    })
end

---A fake `UIAPI` plus the frames it handed out.
---@return table ui
---@return table recorded `{ frames, byName, escapeClosed }`
function fake.newUi()
    local recorded = { frames = {}, byName = {}, escapeClosed = {} }

    local ui = {
        parent = newWidget("Frame", "UIParent"),

        createFrame = function(kind, name, parent, template)
            local widget = newWidget(kind, name)
            widget.template = template
            widget.parent = parent
            -- Frames are born shown in the client; the addon hides what it wants hidden.
            recorded.frames[#recorded.frames + 1] = widget
            if name then
                recorded.byName[name] = widget
            end
            if parent and parent.children then
                parent.children[#parent.children + 1] = widget
            end
            return widget
        end,

        registerEscapeClose = function(globalName)
            recorded.escapeClosed[#recorded.escapeClosed + 1] = globalName
        end,
    }

    return ui, recorded
end

fake.newWidget = newWidget

---A complete fake WowEnv plus the recordings the test asserts on.
---
---`options.transmog` accepts the same config table `newTransmogApi` does, so a boot test
---can declare the client's set data inline.
---Pass `options.ui = true` for a working fake UI; leave it out to model the addon booting
---somewhere no frames can be created, which must not be an error.
---@param options table? `{ transmog = table?, db = table?, ui = boolean?, playerClass = string? }`
---@return table env
---@return table recorded `{ lines, db, transmog, ui, slash }`
function fake.newEnv(options)
    options = options or {}
    local lines = {}
    local db = options.db or {}
    local transmog, transmogRecorded = fake.newTransmogApi(options.transmog)

    local ui, uiRecorded
    if options.ui then
        ui, uiRecorded = fake.newUi()
    end

    local slash = { registrations = {} }

    local env = {
        print = function(message)
            lines[#lines + 1] = message
        end,
        transmog = transmog,
        ui = ui,
        db = db,
        getPlayerClass = function()
            return options.playerClass
        end,
        registerSlash = function(name, commands, handler)
            slash.registrations[#slash.registrations + 1] = {
                name = name,
                commands = commands,
                handler = handler,
            }
        end,
    }

    return env, {
        lines = lines,
        db = db,
        transmog = transmogRecorded,
        ui = uiRecorded,
        slash = slash,
        ---The adapter table itself, so a test can prove the provider calls *this* object
        ---rather than a global it reached for behind the seam's back.
        transmogApi = transmog,
    }
end

return fake
