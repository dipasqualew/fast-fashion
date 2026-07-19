local _, ns = ...

---Parses and dispatches `/ff ...`. Pure: it takes the typed string and calls injected
---handlers, so the whole command surface is testable without a chat frame.
---@class SlashCommands
---@field handle fun(input: string?)
---@field commands fun(): string[] Every recognised verb, for the help text.

---@class SlashCommandsDeps
---@field gallery GalleryFrame
---@field controller GalleryController? Drops cached collection state on `/ff refresh`.
---@field wardrobeTab WardrobeTab? Opens the gallery in its Collections tab when available.
---@field logger Logger
---@field db table SavedVariables root, for the persisted debug flag.

---@param input string?
---@return string verb
---@return string rest
local function parse(input)
    input = input or ""
    local verb, rest = input:match("^%s*(%S*)%s*(.-)%s*$")
    return (verb or ""):lower(), rest or ""
end

---@param deps SlashCommandsDeps
---@return SlashCommands
function ns.newSlashCommands(deps)
    local gallery = deps.gallery
    local controller = deps.controller
    local wardrobeTab = deps.wardrobeTab
    local logger = deps.logger
    local db = deps.db

    ---The gallery's home is the Wardrobe tab where one could be attached, and the
    ---standalone window everywhere else.
    local function openGallery()
        if wardrobeTab then
            wardrobeTab.select()
            return
        end
        gallery.toggle()
    end

    local handlers = {}
    ---Declaration order is help order, so the list a player sees matches the list here.
    local order = {}

    ---@param verb string
    ---@param help string
    ---@param handler fun(rest: string)
    local function command(verb, help, handler)
        handlers[verb] = { help = help, run = handler }
        order[#order + 1] = verb
    end

    command("sets", "open the set gallery", openGallery)

    command("refresh", "re-read collection state from the client", function()
        -- Dropping the cached resolutions is the actual refresh; redrawing without it just
        -- re-renders the same answers the resolvers already had.
        if controller then
            controller.refresh()
        end
        gallery.refresh()
        logger.info("refreshed")
    end)

    command("debug", "toggle diagnostic logging", function()
        -- Persisted, because the reason to turn debug on is usually a problem that only
        -- shows up during login, before anyone can type the command.
        db.debug = not db.debug
        logger.setDebug(db.debug)
        logger.info("debug logging " .. (db.debug and "on" or "off"))
    end)

    command("help", "show this list", function()
        logger.info("commands:")
        for _, verb in ipairs(order) do
            logger.info("  /ff " .. verb .. " — " .. handlers[verb].help)
        end
    end)

    return {
        ---@param input string?
        handle = function(input)
            local verb, rest = parse(input)

            -- A bare `/ff` is the command a player types most, so it does the thing they
            -- most likely want rather than lecturing them with a help screen.
            if verb == "" then
                openGallery()
                return
            end

            local handler = handlers[verb]
            if not handler then
                logger.info("unknown command '" .. verb .. "'. Try /ff help")
                return
            end

            handler.run(rest)
        end,

        commands = function()
            local list = {}
            for index, verb in ipairs(order) do
                list[index] = verb
            end
            return list
        end,
    }
end
