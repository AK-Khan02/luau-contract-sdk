--!nocheck

local Contracts = require("../../src/Contracts")
local RateLimiter = require("../../src/Core/RateLimiter")
local Schema = require("../../src/Core/Schema")

return function(test)
	test:section("Schema string boundaries")

	local capped = Schema.string({ maxLength = 12 })
	test:expect("string at maxLength passes", Schema.validate(capped, string.rep("a", 12)).ok, true)
	local tooLong = Schema.validate(capped, string.rep("a", 13))
	test:expect("string one over maxLength fails", tooLong.ok, false)
	test:expectMatch("string maxLength failure names the limit", tooLong.reason, "expected string length <= 12")

	local floored = Schema.string({ minLength = 3 })
	test:expect("string at minLength passes", Schema.validate(floored, "abc").ok, true)
	local tooShort = Schema.validate(floored, "ab")
	test:expect("string one under minLength fails", tooShort.ok, false)
	test:expectMatch("string minLength failure names the limit", tooShort.reason, "expected string length >= 3")
	test:expect("empty string fails minLength", Schema.validate(floored, "").ok, false)
	test:expect("unconstrained string accepts empty", Schema.validate(Schema.string(), "").ok, true)
	test:expect("string rejects numbers", Schema.validate(Schema.string(), 5).ok, false)

	test:section("Schema stringId edge inputs")

	local id = Contracts.stringId()
	for _, valid in ipairs({ "_", "-", "_-_", "Rifle", "Rifle_2-b", string.rep("a", 80) }) do
		test:expect("stringId accepts " .. string.format("%q", valid), Schema.validate(id, valid).ok, true)
	end
	for _, invalid in ipairs({ "", "a b", "../Rifle", "Rifle!", string.rep("a", 81), "tab\tchar" }) do
		test:expect("stringId rejects " .. string.format("%q", invalid), Schema.validate(id, invalid).ok, false)
	end
	test:expectMatch("stringId pattern failure uses its description", Schema.validate(id, "a b").reason, "expected string id")

	test:section("Schema numeric boundaries")

	local ranged = Schema.integer(1, 10)
	test:expect("integer at min passes", Schema.validate(ranged, 1).ok, true)
	test:expect("integer at max passes", Schema.validate(ranged, 10).ok, true)
	local underMin = Schema.validate(ranged, 0)
	test:expect("integer below min fails", underMin.ok, false)
	test:expectMatch("integer min failure names the bound", underMin.reason, "expected integer >= 1")
	local overMax = Schema.validate(ranged, 11)
	test:expect("integer above max fails", overMax.ok, false)
	test:expectMatch("integer max failure names the bound", overMax.reason, "expected integer <= 10")
	test:expect("fractional value fails integer", Schema.validate(ranged, 1.5).ok, false)
	test:expect("infinity fails integer", Schema.validate(ranged, math.huge).ok, false)
	test:expect("nan fails integer", Schema.validate(ranged, 0 / 0).ok, false)
	test:expect("negative zero is a valid integer", Schema.validate(Schema.integer(), -0).ok, true)

	local boundedNumber = Schema.number({ min = 0.5, max = 2.5 })
	test:expect("number at min passes", Schema.validate(boundedNumber, 0.5).ok, true)
	test:expect("number at max passes", Schema.validate(boundedNumber, 2.5).ok, true)
	test:expect("number below min fails", Schema.validate(boundedNumber, 0.4999).ok, false)
	test:expect("number above max fails", Schema.validate(boundedNumber, 2.5001).ok, false)
	test:expect("infinity fails number", Schema.validate(Schema.number(), math.huge).ok, false)
	test:expect("negative infinity fails number", Schema.validate(Schema.number(), -math.huge).ok, false)
	test:expect("nan fails number", Schema.validate(Schema.number(), 0 / 0).ok, false)

	test:section("Schema vector3 boundaries")

	local unitish = Schema.vector3({ unitish = true })
	test:expect("unitish accepts magnitude at lower bound", Schema.validate(unitish, { X = 0.001, Y = 0, Z = 0 }).ok, true)
	test:expect("unitish accepts magnitude at upper bound", Schema.validate(unitish, { X = 1.25, Y = 0, Z = 0 }).ok, true)
	test:expect("unitish rejects magnitude below lower bound", Schema.validate(unitish, { X = 0.0009, Y = 0, Z = 0 }).ok, false)
	test:expect("unitish rejects magnitude above upper bound", Schema.validate(unitish, { X = 1.2501, Y = 0, Z = 0 }).ok, false)
	local zeroVector = Schema.validate(unitish, { X = 0, Y = 0, Z = 0 })
	test:expect("unitish rejects the zero vector", zeroVector.ok, false)
	test:expectMatch("unitish failure says unit-ish", zeroVector.reason, "expected unit-ish vector")
	test:expect("non-finite component is not Vector3-like", Schema.validate(unitish, { X = math.huge, Y = 0, Z = 0 }).ok, false)
	local hugeMagnitude = Schema.validate(unitish, { X = 1, Y = 0, Z = 0, Magnitude = math.huge })
	test:expect("non-finite Magnitude field fails", hugeMagnitude.ok, false)
	test:expectMatch("non-finite magnitude failure is specific", hugeMagnitude.reason, "expected finite vector magnitude")

	local ranged3 = Schema.vector3({ minMagnitude = 2, maxMagnitude = 4 })
	test:expect("vector at minMagnitude passes", Schema.validate(ranged3, { X = 2, Y = 0, Z = 0 }).ok, true)
	test:expect("vector at maxMagnitude passes", Schema.validate(ranged3, { X = 4, Y = 0, Z = 0 }).ok, true)
	test:expect("vector below minMagnitude fails", Schema.validate(ranged3, { X = 1.999, Y = 0, Z = 0 }).ok, false)
	test:expect("vector above maxMagnitude fails", Schema.validate(ranged3, { X = 4.001, Y = 0, Z = 0 }).ok, false)

	test:section("Schema custom validators")

	local normalizing = Schema.custom("trimmed", function(value)
		if type(value) ~= "string" then
			return "expected a string to trim"
		end
		return true, nil, (string.gsub(value, "^%s+", ""))
	end)
	local normalized = Schema.validate(normalizing, "  hello")
	test:expect("custom validator accepts", normalized.ok, true)
	test:expect("custom validator can normalize the value", normalized.value, "hello")

	local rejected = Schema.validate(normalizing, 42)
	test:expect("custom validator rejects with its reason", rejected.ok, false)
	test:expectMatch("custom rejection carries the reason text", rejected.reason, "expected a string to trim")

	local throwing = Schema.custom("explodes", function()
		error("validator blew up")
	end)
	local thrown = Schema.validate(throwing, 1)
	test:expect("throwing validator fails instead of propagating", thrown.ok, false)
	test:expectMatch("throwing validator failure carries the error", thrown.reason, "validator blew up")

	local terse = Schema.custom("terse", function()
		return false
	end)
	test:expectMatch("custom failure without reason names the validator", Schema.validate(terse, 1).reason, "failed terse validation")

	local shorthand = Schema.validate(function(value)
		return value == "ok"
	end, "ok")
	test:expect("plain function shorthand validates", shorthand.ok, true)

	test:section("Schema object boundaries")

	local strictObject = Schema.object({
		ItemId = Contracts.stringId(),
	}, {
		allowExtra = false,
	})
	local missingField = Schema.validate(strictObject, {})
	test:expect("empty payload fails required fields", missingField.ok, false)
	test:expectMatch("missing field failure names the path", missingField.reason, "ItemId")
	local extraField = Schema.validate(strictObject, { ItemId = "Rifle", Extra = true })
	test:expect("extra field is rejected", extraField.ok, false)
	test:expectMatch("extra field failure names the field", extraField.reason, "Extra: unexpected field")
	test:expect("allowExtra accepts unknown fields", Schema.validate(Schema.object({}, { allowExtra = true }), { Anything = 1 }).ok, true)
	test:expect("empty strict object accepts empty payload", Schema.validate(Schema.object({}), {}).ok, true)
	test:expect("empty strict object rejects any field", Schema.validate(Schema.object({}), { x = 1 }).ok, false)
	test:expect("object rejects non-tables", Schema.validate(strictObject, "nope").ok, false)
	test:expect("array-like table fails shaped object", Schema.validate(strictObject, { "Rifle" }).ok, false)

	test:section("Diagnostics capacity boundaries")

	test:expectError("capacity zero is rejected", "Diagnostics capacity must be at least 1", function()
		Contracts.diagnostics({ capacity = 0 })
	end)

	local tiny = Contracts.diagnostics({ capacity = 1 })
	tiny:record({ level = "error", name = "First" })
	tiny:record({ level = "error", name = "Second" })
	tiny:record({ level = "error", name = "Third" })
	test:expect("capacity one keeps a single record", tiny:count(), 1)
	test:expect("capacity one keeps the newest record", tiny:last().name, "Third")
	test:expect("capacity one counts every drop", tiny:droppedCount(), 2)
	tiny:clear()
	test:expect("clear resets the dropped count", tiny:droppedCount(), 0)

	local limited = Contracts.diagnostics()
	for index = 1, 5 do
		limited:record({ level = "error", name = "Entry" .. index })
	end
	local found = limited:find({ level = "error", limit = 2 })
	test:expect("find honors its limit", #found, 2)
	test:expect("find returns newest matches first", found[1].name, "Entry5")

	test:section("RateLimiter window boundaries")

	local state = { now = 0 }
	local function clock()
		return state.now
	end

	local limiter = RateLimiter.new({ maxRequests = 2, windowSeconds = 1 }, clock)
	test:expect("first request passes", limiter:check("player", "Fire"), true)
	test:expect("second request at limit passes", limiter:check("player", "Fire"), true)
	test:expect("third request in window fails", limiter:check("player", "Fire"), false)

	state.now = 0.9999
	test:expect("request just before the window edge still fails", limiter:check("player", "Fire"), false)
	state.now = 1
	test:expect("request exactly at the window edge resets", limiter:check("player", "Fire"), true)

	local fractional = RateLimiter.new({ maxRequests = 1, windowSeconds = 0.5 }, clock)
	state.now = 10
	test:expect("fractional window first request passes", fractional:check("player", "Dash"), true)
	state.now = 10.4999
	test:expect("fractional window blocks before the edge", fractional:check("player", "Dash"), false)
	state.now = 10.5
	test:expect("fractional window resets at the edge", fractional:check("player", "Dash"), true)

	state.now = 20
	local independent = RateLimiter.new({ maxRequests = 1, windowSeconds = 100 }, clock)
	test:expect("key A consumes its budget", independent:check("playerA", "Fire"), true)
	test:expect("key A is exhausted", independent:check("playerA", "Fire"), false)
	test:expect("key B is unaffected by key A", independent:check("playerB", "Fire"), true)
	test:expect("same key different action is unaffected", independent:check("playerA", "Reload"), true)
	test:expect("nil keys share one anonymous bucket", independent:check(nil, "Fire"), true)
	test:expect("anonymous bucket is exhausted by nil keys", independent:check(nil, "Fire"), false)

	local overridden = RateLimiter.new({ maxRequests = 10, windowSeconds = 1 }, clock)
	test:expect("per-check override tightens the limit", overridden:check("player", "Buy", { maxRequests = 1 }), true)
	test:expect("per-check override is enforced", overridden:check("player", "Buy", { maxRequests = 1 }), false)
end
