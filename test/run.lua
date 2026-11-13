-- Runs test/lib_spec.lua. Works with a plain Lua 5.1+ (lua test/run.lua, from
-- the repo's folder) and inside Rex (rex do test/run.lua).

local src = debug.getinfo(1, "S").source:gsub("^@", "")
local root = (src:match("^(.*)/test/[^/]*$") or ".")
local lib = dofile(root .. "/lib.lua")
local spec = dofile(root .. "/test/lib_spec.lua")

local passed, failed = 0, 0
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
    passed = passed + 1
  else
    failed = failed + 1
    print("FAIL " .. name)
    for _, p in ipairs(problems) do print("     " .. p) end
  end
end

spec(t, lib)
print(string.format("%d passed, %d failed", passed, failed))
if failed > 0 then
  if rex then rex.stop(1) else os.exit(1) end
end
