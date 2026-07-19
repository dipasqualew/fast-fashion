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
    "UISpecialFrames",
    "print",
    "C_Transmog",
    "C_TransmogSets",
    "C_TransmogCollection",
}

globals = {
    "FastFashionDB", -- SavedVariables
    "SlashCmdList",
}

exclude_files = { ".luacheckrc" }
