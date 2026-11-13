-- Lets Rex's init.lua load this tool with require("rex-agent-resume") when the
-- repository is cloned beside it, as ~/.config/rex/rex-agent-resume. It is not
-- a Rex config file itself. See the README.
local here = (debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)/[^/]*$") or "."
dofile(here .. "/rex-agent-resume.lua")
