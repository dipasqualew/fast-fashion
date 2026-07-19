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
}

globals = {
    "FastFashionDB", -- SavedVariables
    "SlashCmdList",
    "UISpecialFrames", -- appended to, so Escape closes the gallery
    "_G", -- SLASH_* names have to be set as globals by name
}

exclude_files = { ".luacheckrc" }
