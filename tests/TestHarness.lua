--!strict

export type Harness = {
	passed: number,
	failed: number,
	erroredSuites: number,
	check: (Harness, string, any, string?) -> (),
	expect: (Harness, string, any, any) -> (),
	expectMatch: (Harness, string, any, string) -> (),
	expectError: (Harness, string, string, any, ...any) -> (),
	suite: (Harness, string) -> (),
	section: (Harness, string) -> (),
	suiteError: (Harness, string, any) -> (),
	summary: (Harness) -> (),
}

local TestHarness = {}

local function formatScalar(value: any): string
	local valueType = type(value)
	if valueType == "string" then
		return string.format("%q", value) .. " (string)"
	end
	return tostring(value) .. " (" .. valueType .. ")"
end

local function formatValue(value: any): string
	if type(value) == "table" then
		local parts: { string } = {}
		for key, child in pairs(value) do
			table.insert(parts, tostring(key) .. "=" .. formatScalar(child))
			if #parts >= 6 then
				table.insert(parts, "...")
				break
			end
		end
		return "{" .. table.concat(parts, ", ") .. "}"
	end
	return formatScalar(value)
end

function TestHarness.new(): Harness
	local suiteName: string? = nil
	local sectionName: string? = nil
	local harness: any = {
		passed = 0,
		failed = 0,
		erroredSuites = 0,
	}

	local function location(): string
		local parts: { string } = {}
		if suiteName ~= nil then
			table.insert(parts, suiteName)
		end
		if sectionName ~= nil then
			table.insert(parts, sectionName)
		end
		return table.concat(parts, " > ")
	end

	local function fail(name: string, details: string?)
		harness.failed += 1
		local currentLocation = location()
		local line = "  FAIL: " .. (currentLocation ~= "" and currentLocation .. " > " or "") .. name
		if details ~= nil then
			line ..= "\n        " .. details
		end
		print(line)
	end

	harness.check = function(_: Harness, name: string, condition: any, details: string?)
		if condition then
			harness.passed += 1
		else
			fail(name, details)
		end
	end

	harness.expect = function(_: Harness, name: string, got: any, want: any)
		if got == want then
			harness.passed += 1
		else
			fail(name, "expected " .. formatValue(want) .. ", got " .. formatValue(got))
		end
	end

	harness.expectMatch = function(_: Harness, name: string, text: any, fragment: string)
		if type(text) == "string" and string.find(text, fragment, 1, true) ~= nil then
			harness.passed += 1
		else
			fail(name, "expected text containing " .. formatValue(fragment) .. ", got " .. formatValue(text))
		end
	end

	harness.expectError = function(_: Harness, name: string, fragment: string, fn: any, ...: any)
		local ok, err = pcall(fn, ...)
		if ok then
			fail(name, "expected an error containing " .. formatValue(fragment) .. ", but the call succeeded")
			return
		end
		local message = tostring(err)
		if string.find(message, fragment, 1, true) ~= nil then
			harness.passed += 1
		else
			fail(name, "expected error containing " .. formatValue(fragment) .. ", got " .. formatValue(message))
		end
	end

	harness.suite = function(_: Harness, name: string)
		suiteName = name
		sectionName = nil
	end

	harness.section = function(_: Harness, name: string)
		sectionName = name
		print(name)
	end

	harness.suiteError = function(_: Harness, name: string, err: any)
		harness.erroredSuites += 1
		fail("suite " .. name .. " errored", tostring(err))
	end

	harness.summary = function(_: Harness)
		print(("%d passed, %d failed"):format(harness.passed, harness.failed))

		if harness.failed > 0 then
			error("test failures", 2)
		end
	end

	return harness :: Harness
end

return TestHarness
