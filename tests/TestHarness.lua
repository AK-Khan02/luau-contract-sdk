--!nocheck

local TestHarness = {}

local function formatValue(value)
	if type(value) == "string" then
		return string.format("%q", value)
	end
	if type(value) == "table" then
		local parts = {}
		for key, child in pairs(value) do
			table.insert(parts, tostring(key) .. "=" .. tostring(child))
			if #parts >= 6 then
				table.insert(parts, "...")
				break
			end
		end
		return "{" .. table.concat(parts, ", ") .. "}"
	end
	return tostring(value)
end

function TestHarness.new()
	local self = {
		passed = 0,
		failed = 0,
		erroredSuites = 0,
		_suite = nil,
		_section = nil,
	}

	function self:_location()
		local parts = {}
		if self._suite ~= nil then
			table.insert(parts, self._suite)
		end
		if self._section ~= nil then
			table.insert(parts, self._section)
		end
		return table.concat(parts, " > ")
	end

	function self:_fail(name, details)
		self.failed += 1
		local location = self:_location()
		local line = "  FAIL: " .. (location ~= "" and location .. " > " or "") .. name
		if details ~= nil then
			line ..= "\n        " .. details
		end
		print(line)
	end

	function self:check(name, condition, details)
		if condition then
			self.passed += 1
		else
			self:_fail(name, details)
		end
	end

	function self:expect(name, got, want)
		if got == want then
			self.passed += 1
		else
			self:_fail(name, "expected " .. formatValue(want) .. ", got " .. formatValue(got))
		end
	end

	function self:expectMatch(name, text, fragment)
		if type(text) == "string" and string.find(text, fragment, 1, true) ~= nil then
			self.passed += 1
		else
			self:_fail(name, "expected text containing " .. formatValue(fragment) .. ", got " .. formatValue(text))
		end
	end

	function self:expectError(name, fragment, fn, ...)
		local ok, err = pcall(fn, ...)
		if ok then
			self:_fail(name, "expected an error containing " .. formatValue(fragment) .. ", but the call succeeded")
			return
		end
		local message = tostring(err)
		if string.find(message, fragment, 1, true) ~= nil then
			self.passed += 1
		else
			self:_fail(name, "expected error containing " .. formatValue(fragment) .. ", got " .. formatValue(message))
		end
	end

	function self:suite(name)
		self._suite = name
		self._section = nil
	end

	function self:section(name)
		self._section = name
		print(name)
	end

	function self:suiteError(name, err)
		self.erroredSuites += 1
		self:_fail("suite " .. name .. " errored", tostring(err))
	end

	function self:summary()
		print(("%d passed, %d failed"):format(self.passed, self.failed))

		if self.failed > 0 then
			error("test failures", 2)
		end
	end

	return self
end

return TestHarness
