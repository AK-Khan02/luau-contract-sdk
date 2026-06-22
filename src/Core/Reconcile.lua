--!strict

-- Reconcile is the schema-reconciliation layer for durable profiles. It is the
-- module the DurableProfile load-time hook resolves via `pcall(require)`: once it
-- exists, `Contracts.loadProfile(store, key, { template, migrations })` fills
-- defaults and runs ordered migrations on the freshly loaded value before the
-- handle is returned.
--
-- Both functions operate on plain Luau tables and never touch a store, so they
-- are fully unit-testable in isolation.
--
--   Reconcile.fill(data, template) -> data
--     Deep-fills keys present in `template` but missing from `data`, recursing
--     into nested tables. Existing values are never clobbered. Returns `data`.
--
--   Reconcile.migrate(data, migrations, options?) -> Result
--     Reads `data.schemaVersion` (default 0) and runs `migrations[v + 1 .. #migrations]`
--     in order, each a `function(data) -> data`. Stamps `data.schemaVersion`
--     forward to `#migrations` on success and returns `Result.ok(data)`. An
--     already-current profile runs zero steps (idempotent); a record already at or
--     beyond `#migrations` (a newer server's record loaded by an older one) is left
--     untouched at its existing higher version, never stamped down. A throwing step
--     returns `Result.fail("ProfileMigrationFailed", reason, { fromVersion, atStep })`.

local Result = require("./Result")
local TableUtil = require("./TableUtil")

local Reconcile = {}

Reconcile.MIGRATION_FAILED = "ProfileMigrationFailed"

-- Recursively fill missing keys/defaults from `template` into `data`. A default
-- copied out of the template is deep-copied so `data` never aliases the shared
-- template tables (a later mutation of one profile must not leak into another).
local function fillInto(data: any, template: any)
	if type(data) ~= "table" or type(template) ~= "table" then
		return
	end

	for key, templateValue in pairs(template) do
		local current = data[key]
		if current == nil then
			data[key] = TableUtil.deepCopy(templateValue)
		elseif type(current) == "table" and type(templateValue) == "table" then
			-- Both sides are tables: recurse so nested defaults are filled
			-- without clobbering nested values the profile already has.
			fillInto(current, templateValue)
		end
	end
end

function Reconcile.fill(data: any, template: any): any
	fillInto(data, template)
	return data
end

function Reconcile.migrate(data: any, migrations: any, _options: any?): any
	local steps: { any } = migrations or {}
	local stepCount = #steps

	local startVersion = 0
	if type(data) == "table" and type(data.schemaVersion) == "number" then
		startVersion = data.schemaVersion
	end

	local migrated = data
	for index = startVersion + 1, stepCount do
		local step = steps[index]
		if type(step) ~= "function" then
			return Result.fail("ProfileMigrationFailed", "migration step " .. index .. " is not a function", {
				fromVersion = startVersion,
				atStep = index,
			})
		end

		local ok, result = pcall(step, migrated)
		if not ok then
			return Result.fail("ProfileMigrationFailed", result, {
				fromVersion = startVersion,
				atStep = index,
			})
		end
		migrated = result
	end

	if type(migrated) == "table" then
		-- Only ever stamp the version FORWARD. A record already at or beyond
		-- `#migrations` (e.g. migrated by a newer server, then loaded by an older
		-- server with fewer migrations) ran zero steps above and must keep its
		-- existing higher version -- stamping it down would make a future server
		-- re-run already-applied migrations and corrupt the data (version skew).
		migrated.schemaVersion = math.max(startVersion, stepCount)
	end

	return Result.ok(migrated)
end

return Reconcile
