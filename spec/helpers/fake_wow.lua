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
---`requestItemData` is present unless the config sets it to `false`, which models a client
---build without `C_Item.RequestLoadItemDataByID`. The provider treats it as optional, so
---both shapes have to be expressible.
---@param config table? `{ sets, items, sources, appearanceSources, requestItemData }`
---@return TransmogAPI api
---@return table recorded `{ allSets, setAppearances, sourceInfo, appearanceSources, requestedItems }`
function fake.newTransmogApi(config)
    config = config or {}
    local recorded = {
        allSets = 0,
        setAppearances = {},
        sourceInfo = {},
        appearanceSources = {},
        requestedItems = {},
    }

    local api = {}

    if config.requestItemData ~= false then
        function api.requestItemData(itemID)
            recorded.requestedItems[#recorded.requestedItems + 1] = itemID
        end
    end

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
---`created` records the arguments as given, which is the only way to observe an argument
---that was *absent*: a widget answers any unset field with a chainable no-op method, so
---reading `widget.template` back can never be nil.
---@return table recorded `{ frames, created, byName, escapeClosed }`
function fake.newUi()
    local recorded = { frames = {}, created = {}, byName = {}, escapeClosed = {} }

    local ui = {
        parent = newWidget("Frame", "UIParent"),

        createFrame = function(kind, name, parent, template)
            local widget = newWidget(kind, name)
            widget.template = template
            widget.parent = parent
            recorded.created[#recorded.created + 1] = {
                kind = kind,
                name = name,
                parent = parent,
                template = template,
                widget = widget,
            }
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

---A stand-in for `TransmogPreviewAPI`.
---
---Shape:
---  `available`  `boolean?` — false models a player standing away from a transmogrifier.
---  `rejectSlots` `table<number, boolean>?` — slots the client refuses, so `setPending`
---    answering false is expressible without a hand-rolled stub.
---  `open`       `boolean?` — false drops the optional `open` member entirely.
---@param config table?
---@return TransmogPreviewAPI api
---@return table recorded `{ cleared, pending, opened }`
function fake.newPreviewApi(config)
    config = config or {}
    local recorded = { cleared = 0, pending = {}, opened = 0 }

    local api = {
        isAvailable = function()
            return config.available ~= false
        end,

        clearPending = function()
            recorded.cleared = recorded.cleared + 1
        end,

        setPending = function(inventorySlot, sourceID)
            recorded.pending[#recorded.pending + 1] = {
                inventorySlot = inventorySlot,
                sourceID = sourceID,
            }
            return not (config.rejectSlots or {})[inventorySlot]
        end,
    }

    if config.open ~= false then
        api.open = function()
            recorded.opened = recorded.opened + 1
        end
    end

    return api, recorded
end

---A stand-in for `CollectionsAPI`, the load-on-demand Blizzard_Collections seam.
---
---Shape:
---  `loaded`    `boolean?` — whether Blizzard_Collections is already loaded.
---  `loadable`  `boolean?` — false models the client refusing to load it at all.
---  `wardrobe`  `false?` — drops the wardrobe frame, the "loaded but unrecognisable UI" case.
---  `tab`       `false?` — makes `addTab` fail, the other unrecognisable-UI case.
---@param config table?
---@return CollectionsAPI api
---@return table recorded `{ loads, opened, tabs, tabClicks, callbacks, deliver }`
function fake.newCollectionsApi(config)
    config = config or {}
    local recorded = { loads = 0, opened = 0, tabs = {}, tabClicks = 0, callbacks = {} }

    local loaded = config.loaded == true
    local wardrobe
    if config.wardrobe ~= false then
        wardrobe = newWidget("Frame", "WardrobeCollectionFrame")
    end

    local api = {
        isLoaded = function()
            return loaded
        end,

        load = function()
            recorded.loads = recorded.loads + 1
            if config.loadable == false then
                return false
            end
            loaded = true
            return true
        end,

        onLoaded = function(callback)
            recorded.callbacks[#recorded.callbacks + 1] = callback
        end,

        getWardrobe = function()
            return wardrobe
        end,

        ---What the gallery frame parents itself to when it is embedded.
        getGalleryHost = function()
            return wardrobe
        end,

        addTab = function(host, label, onSelect, onDeselect)
            recorded.tabs[#recorded.tabs + 1] = {
                host = host,
                label = label,
                onSelect = onSelect,
                onDeselect = onDeselect,
            }
            if config.tab == false then
                return nil
            end

            local tab = newWidget("Button", "FastFashionWardrobeTab")
            tab:SetScript("OnClick", function()
                recorded.tabClicks = recorded.tabClicks + 1
                onSelect()
            end)
            return tab
        end,

        openCollections = function()
            recorded.opened = recorded.opened + 1
        end,
    }

    ---The client finishing a load-on-demand: flips the flag and fires every registered
    ---callback, the way ADDON_LOADED does.
    function recorded.deliver()
        loaded = true
        for _, callback in ipairs(recorded.callbacks) do
            callback()
        end
    end

    return api, recorded
end

---A stand-in for `C_Timer.After`, so a test drives time rather than waiting for it.
---@return fun(seconds: number, callback: fun()) after
---@return table recorded `{ queued, elapse }`
function fake.newTimer()
    local recorded = { queued = {} }

    local function after(seconds, callback)
        recorded.queued[#recorded.queued + 1] = { seconds = seconds, callback = callback }
    end

    ---Runs every timer armed so far. The queue is drained *before* the callbacks run, so a
    ---callback that arms a fresh timer leaves it for the next `elapse` instead of looping.
    function recorded.elapse()
        local due = recorded.queued
        recorded.queued = {}
        for _, entry in ipairs(due) do
            entry.callback()
        end
    end

    return after, recorded
end

---A complete fake WowEnv plus the recordings the test asserts on.
---
---`options.transmog` accepts the same config table `newTransmogApi` does, so a boot test
---can declare the client's set data inline.
---Pass `options.ui = true` for a working fake UI; leave it out to model the addon booting
---somewhere no frames can be created, which must not be an error.
---
---`preview`, `collections`, `after` and `events` are each opt-in for the same reason they
---are optional on `WowEnv`: the addon has to boot with none of them, so the default env
---must be the one that has none.
---@param options table? `{ transmog, db, ui, playerClass, preview, collections, after, events }`
---@return table env
---@return table recorded `{ lines, db, transmog, ui, slash, preview, collections, timer, events }`
function fake.newEnv(options)
    options = options or {}
    local lines = {}
    local db = options.db or {}
    local transmog, transmogRecorded = fake.newTransmogApi(options.transmog)

    local ui, uiRecorded
    if options.ui then
        ui, uiRecorded = fake.newUi()
    end

    local preview, previewRecorded
    if options.preview then
        preview, previewRecorded = fake.newPreviewApi(options.preview ~= true and options.preview or nil)
    end

    local collections, collectionsRecorded
    if options.collections then
        collections, collectionsRecorded = fake.newCollectionsApi(
            options.collections ~= true and options.collections or nil
        )
    end

    local after, timerRecorded
    if options.after then
        after, timerRecorded = fake.newTimer()
    end

    ---Records what the addon subscribed to and lets a test push an event back at it, the
    ---way the client's event stream does.
    local events = { registered = {}, handlers = {} }

    ---@param event string
    function events.fire(event)
        for _, handler in ipairs(events.handlers) do
            handler(event)
        end
    end

    local registerEvents
    if options.events then
        registerEvents = function(names, handler)
            for _, name in ipairs(names) do
                events.registered[#events.registered + 1] = name
            end
            events.handlers[#events.handlers + 1] = handler
        end
    end

    local slash = { registrations = {} }

    local env = {
        print = function(message)
            lines[#lines + 1] = message
        end,
        transmog = transmog,
        ui = ui,
        db = db,
        preview = preview,
        collections = collections,
        after = after,
        registerEvents = registerEvents,
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
        preview = previewRecorded,
        collections = collectionsRecorded,
        timer = timerRecorded,
        events = events,
        ---The adapter table itself, so a test can prove the provider calls *this* object
        ---rather than a global it reached for behind the seam's back.
        transmogApi = transmog,
    }
end

return fake
