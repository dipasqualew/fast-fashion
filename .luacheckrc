std = "lua51"
max_line_length = 120

-- WoW passes (addonName, namespace) as varargs to every file in the .toc.
files["*.lua"] = { ignore = { "212/_" } }

-- Specs run under busted, which injects describe/it/assert/spy/stub as globals.
files["spec/**/*.lua"] = { std = "lua51+busted" }

read_globals = {
    "CreateFrame",
    "UnitClass",
    "UIParent",
    "print",
    "C_Transmog",
    "C_TransmogSets",
    "C_TransmogCollection",
    "C_Item", -- RequestLoadItemDataByID, to make the client stream set items in
    "C_Timer", -- After, for coalescing the client's data-event storms
    "C_AddOns", -- load-on-demand Blizzard_Collections
    "Enum",
    "TransmogUtil",
    "TransmogFrame",
    "WardrobeCollectionFrame",
    "CollectionsJournal",
    "CollectionsJournal_LoadUI",
    "ShowUIPanel",
    "PanelTemplates_SelectTab",
    "PanelTemplates_DeselectTab",
    "hooksecurefunc",
}

globals = {
    "FastFashionDB", -- SavedVariables
    "SlashCmdList",
    "UISpecialFrames", -- appended to, so Escape closes the gallery
    "_G", -- SLASH_* names have to be set as globals by name
}

exclude_files = { ".luacheckrc" }
