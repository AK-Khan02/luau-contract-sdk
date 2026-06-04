--!nocheck

local TestHarness = {}

function TestHarness.new()
	local self = {
		passed = 0,
		failed = 0,
	}

	function self:check(name, condition)
		if condition then
			self.passed += 1
		else
			self.failed += 1
			print("  FAIL: " .. name)
		end
	end

	function self:section(name)
		print(name)
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
