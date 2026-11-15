-- Runs the specs in test/. Works with a plain Lua 5.1+ (lua test/run.lua, from
-- the repo's folder) and inside Rex (rex do test/run.lua).

local src = debug.getinfo(1, "S").source:gsub("^@", "")
local root = (src:match("^(.*)/test/[^/]*$") or ".")
local core = dofile(root .. "/core/init.lua")
core.fakes = assert(loadfile(root .. "/test/fakes.lua"))(core)
local agents, skipped_agents = dofile(root .. "/agents/init.lua")(core)
for _, problem in ipairs(skipped_agents) do print("FAIL loading agents: " .. problem) end
local specs = { "recording_spec", "restore_spec", "protocol_spec", "claude_spec", "codex_spec" }

-- Counts in a table, not locals: in Rex's Lua, once a pcall inside a test has
-- caught an error, a closure's later assignments to outer locals are lost.
local count = { passed = 0, failed = 0 }
local function t(name, fn)
  local problems = {}
  local function eq(got, want)
    if got ~= want then
      problems[#problems + 1] = string.format("got %s, want %s", tostring(got), tostring(want))
    end
  end
  local ok, err = pcall(fn, eq)
  if not ok then problems[#problems + 1] = "error: " .. tostring(err) end
  if #problems == 0 then
    count.passed = count.passed + 1
  else
    count.failed = count.failed + 1
    print("FAIL " .. name)
    for _, p in ipairs(problems) do print("     " .. p) end
  end
end

for _, name in ipairs(specs) do dofile(root .. "/test/" .. name .. ".lua")(t, core, agents) end
print(string.format("%d passed, %d failed", count.passed, count.failed))
if count.failed > 0 or #skipped_agents > 0 then
  if rex then rex.stop(1) else os.exit(1) end
end
