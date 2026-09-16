local t = {}

function t.fake_api_has_model_rep()
  local fake = require("fake_api")
  fake.modelRep({ fake.model("vehicle/bus/a.mdl") })
  assert(api.res.modelRep.find("vehicle/bus/a.mdl") == 0)
  assert(api.res.modelRep.get(0).metadata.description.name == "vehicle/bus/a.mdl")
end

function t.broken_model_raises()
  local fake = require("fake_api")
  fake.modelRep({ fake.model("vehicle/bus/bad.mdl", { broken = true }) })
  local ok = pcall(api.res.modelRep.get, 0)
  assert(not ok)
end

return t
