--!nocheck

local TestHarness = require("./TestHarness")

local suites = {
	require("./suites/package_schema_lifecycle"),
	require("./suites/diagnostics_system"),
	require("./suites/adapters_examples"),
	require("./suites/scanner_studio"),
}

local test = TestHarness.new()

for _, runSuite in ipairs(suites) do
	runSuite(test)
end

test:summary()
