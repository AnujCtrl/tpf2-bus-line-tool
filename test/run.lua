-- Run from the repo root:  lua5.4 test/run.lua
package.path = "res/scripts/?.lua;test/?.lua;" .. package.path
local fake = require("fake_api")

local files = {
  "test_smoke",
  "test_discovery",
  "test_geometry",
  "test_upgrade_rules",
}

local passed, failed = 0, 0
for _, file in ipairs(files) do
  local ok, cases = pcall(require, file)
  if not ok then
    failed = failed + 1
    print(("FAIL %s: could not load: %s"):format(file, tostring(cases)))
  else
    local names = {}
    for name in pairs(cases) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
      fake.reset()
      local ok2, err = pcall(cases[name])
      if ok2 then
        passed = passed + 1
      else
        failed = failed + 1
        print(("FAIL %s.%s: %s"):format(file, name, tostring(err)))
      end
    end
  end
end
print(("%d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
