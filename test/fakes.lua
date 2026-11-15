-- test/fakes.lua: made-up agents and a fake host, for the specs.

local core = ...

local M = {}

M.A = "0193f2a4-5b6c-7d8e-9f01-23456789abcd"
M.B = "3f2a1b4c-5d6e-4f70-8192-a3b4c5d6e7f8"

-- A made-up agent that takes UUIDs and resumes with "<name> --resume <id>".
-- The core knows no agent, so its specs use these, not those in agents/.
function M.agent(name, programs)
  return { name = name, programs = programs or { name }, is_valid_id = core.shell.is_uuid,
           resume_command = function(id) return name .. " --resume " .. id end,
           detect = function() return { id = M.A } end }
end

-- A registry of the made-up agents alpha and beta.
function M.registry() return (core.agent_protocol.new_registry({ M.agent("alpha"), M.agent("beta") })) end

-- A host (the Host protocol) with these files (path -> text, or a table for
-- read_json), these command results (argv[1] -> { ok, stdout }), these JSON
-- texts (text -> value) and this pane title.
function M.host(o)
  local files, commands, json = o.files or {}, o.commands or {}, o.json or {}
  local host = {
    home = "/home/me",
    getenv = function() return nil end,
    now = function() return 1000 end,
    read_file = function(path) local f = files[path] return type(f) == "string" and f or nil end,
    read_json = function(path) local f = files[path] return type(f) == "table" and f or nil end,
    decode_json = function(text)
      if json[text] == nil then error("not JSON: " .. text) end
      return json[text]
    end,
    exec = function(argv) return commands[argv[1]] end,
    warn = function() end,
    terminal_call = function(_, method) if method == "title" then return { title = o.title } end end,
  }
  local problem = core.agent_protocol.problem(core.agent_protocol.HOST, host)
  assert(not problem, problem)
  return host
end

return M
