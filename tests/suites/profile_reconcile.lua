--!nonstrict

local Contracts = require("../../src/Contracts")

-- Inline in-memory DurableStore fake -- the durable_effects.lua FakeProfileStore
-- shape, reused here so the reconcile/migrate hook is exercised through the real
-- Contracts.loadProfile path (store:load -> Reconcile.fill -> Reconcile.migrate)
-- without DataStoreService. A `release` that records the freed key lets the
-- lock-leak assertions prove a rejected migration does not strand the lock.
local function deepCopy(value)
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for key, child in pairs(value) do
		copy[key] = deepCopy(child)
	end
	return copy
end

local FakeProfileStore = {}
FakeProfileStore.__index = FakeProfileStore

local function newStore()
	return setmetatable({
		data = {},
		locks = {},
		nextLock = 0,
		releaseCount = 0,
	}, FakeProfileStore)
end

function FakeProfileStore.seed(self, key, value)
	self.data[key] = deepCopy(value)
end

function FakeProfileStore.load(self, key)
	local held = self.locks[key]
	if held ~= nil then
		return {
			ok = false,
			name = "SessionLockUnavailable",
			reason = "another server holds the lock for " .. key,
		}
	end

	self.nextLock += 1
	local lock = { id = self.nextLock }
	self.locks[key] = lock
	return {
		ok = true,
		name = "DurableLoaded",
		value = deepCopy(self.data[key]),
		lock = lock,
	}
end

function FakeProfileStore.owns(self, key, lock)
	return self.locks[key] == lock
end

function FakeProfileStore.save(self, key, value, lock)
	if self.locks[key] ~= lock then
		return { ok = false, name = "SessionLockLost", reason = "lock no longer held for " .. key }
	end
	self.data[key] = deepCopy(value)
	return { ok = true, name = "DurableSaved" }
end

function FakeProfileStore.release(self, key, lock)
	if self.locks[key] == lock then
		self.locks[key] = nil
		self.releaseCount += 1
	end
	return { ok = true, name = "DurableReleased" }
end

return function(test)
	local function check(name, condition)
		test:check(name, condition)
	end

	test:section("ProfileReconcile")

	-- 1. Reconcile fills defaults without clobbering existing values (incl. nested),
	--    through the real Contracts.loadProfile hook.
	do
		local store = newStore()
		store:seed("Player_1", {
			coins = 5,
			settings = { music = false },
		})

		local template = {
			coins = 0,
			gems = 0,
			inventory = {},
			settings = { music = true, sfx = true },
		}

		local loaded = Contracts.loadProfile(store, "Player_1", { template = template })
		check("fill load succeeds", loaded.ok == true and loaded.name == "DurableProfileLoaded")

		local value = loaded.profile:value()
		check("fill keeps existing top-level value", value.coins == 5)
		check("fill adds missing top-level default", value.gems == 0)
		check("fill adds missing table default", type(value.inventory) == "table")
		check("fill keeps existing nested value", value.settings.music == false)
		check("fill adds missing nested default", value.settings.sfx == true)

		-- Defaults copied from the template must not alias the shared template
		-- table, or a later mutation of one profile would leak into another.
		value.inventory.sword = true
		check("fill deep-copies table defaults (no template aliasing)", template.inventory.sword == nil)
	end

	-- 2. Migration runs ordered steps, stamps schemaVersion, and is idempotent when
	--    already current (zero steps).
	do
		local store = newStore()
		store:seed("Player_1", { schemaVersion = 0, coins = 0 })

		local order = {}
		local migrations = {
			function(data)
				table.insert(order, "v1")
				data.coins = (data.coins or 0) + 1
				return data
			end,
			function(data)
				table.insert(order, "v2")
				data.inventory = data.inventory or {}
				return data
			end,
		}

		local loaded = Contracts.loadProfile(store, "Player_1", { migrations = migrations })
		check("migrate load succeeds", loaded.ok == true)

		local value = loaded.profile:value()
		check("migrate runs both ordered steps", order[1] == "v1" and order[2] == "v2" and #order == 2)
		check("migrate applies step effects", value.coins == 1 and type(value.inventory) == "table")
		check("migrate stamps schemaVersion to migration count", value.schemaVersion == 2)

		-- Already current: a record already at the latest schemaVersion runs zero
		-- steps. Seeded on a fresh key/store so this is a clean already-current
		-- load rather than relying on the (uncommitted) value from above.
		local currentStore = newStore()
		currentStore:seed("Player_2", { schemaVersion = 2, coins = 50 })
		local order2 = {}
		local migrations2 = {
			function(data)
				table.insert(order2, "v1")
				return data
			end,
			function(data)
				table.insert(order2, "v2")
				return data
			end,
		}
		local current = Contracts.loadProfile(currentStore, "Player_2", { migrations = migrations2 })
		check("already-current load succeeds", current.ok == true)
		check("already-current load runs zero steps (idempotent)", #order2 == 0)
		check("already-current load keeps schemaVersion", current.profile:value().schemaVersion == 2)
		check("already-current load leaves value untouched", current.profile:value().coins == 50)
	end

	-- 3. Partial version runs only the remaining steps.
	do
		local store = newStore()
		store:seed("Player_1", { schemaVersion = 1, coins = 7 })

		local order = {}
		local migrations = {
			function(data)
				table.insert(order, "v1")
				data.coins = 999
				return data
			end,
			function(data)
				table.insert(order, "v2")
				data.inventory = data.inventory or {}
				return data
			end,
		}

		local loaded = Contracts.loadProfile(store, "Player_1", { migrations = migrations })
		check("partial migrate load succeeds", loaded.ok == true)

		local value = loaded.profile:value()
		check("partial migrate runs only the remaining step", order[1] == "v2" and #order == 1)
		check("partial migrate does not re-run earlier step", value.coins == 7)
		check("partial migrate applies remaining step", type(value.inventory) == "table")
		check("partial migrate stamps schemaVersion to migration count", value.schemaVersion == 2)
	end

	-- 4. ProfileMigrationFailed: a throwing step surfaces a failed Result through
	--    Contracts.loadProfile AND the freshly taken lock is released (no leak),
	--    proven by a subsequent load of the same key succeeding.
	do
		local store = newStore()
		store:seed("Player_1", { schemaVersion = 0, coins = 1 })

		local migrations = {
			function(data)
				data.coins = data.coins + 1
				return data
			end,
			function()
				error("migration boom")
			end,
		}

		local loaded = Contracts.loadProfile(store, "Player_1", { migrations = migrations })
		check("failed migration reports not-ok", loaded.ok == false)
		check("failed migration names ProfileMigrationFailed", loaded.name == "ProfileMigrationFailed")
		check("failed migration records fromVersion", loaded.fromVersion == 0)
		check("failed migration records atStep", loaded.atStep == 2)
		check("failed migration carries a reason", loaded.reason ~= nil)

		-- The lock taken for the failed load must have been released.
		check("failed migration released the lock", store.releaseCount == 1 and store.locks.Player_1 == nil)

		-- Prove no leak: the same key can be loaded again (would block if stranded).
		local reloaded = Contracts.loadProfile(store, "Player_1")
		check("key is loadable again after failed migration (no lock leak)", reloaded.ok == true)
		check("reload leaves store value untouched by failed migration", reloaded.profile:value().coins == 1)
	end

	-- 5. Unit-level Reconcile.fill / Reconcile.migrate on plain tables (no store).
	do
		local Reconcile = Contracts.Reconcile

		-- fill: returns the same data table, fills missing, never clobbers.
		local data = { a = 1, nested = { keep = true } }
		local filled = Reconcile.fill(data, { a = 99, b = 2, nested = { keep = false, added = 3 } })
		check("unit fill returns the data table", filled == data)
		check("unit fill does not clobber existing", filled.a == 1 and filled.nested.keep == true)
		check("unit fill adds missing keys", filled.b == 2 and filled.nested.added == 3)

		-- migrate: ordered run from version 0, stamps count, returns Result.ok(data).
		local steps = {}
		local migrations = {
			function(d)
				table.insert(steps, 1)
				d.one = true
				return d
			end,
			function(d)
				table.insert(steps, 2)
				d.two = true
				return d
			end,
		}
		local subject = { schemaVersion = 0 }
		local migrated = Reconcile.migrate(subject, migrations)
		check("unit migrate returns ok Result", migrated.ok == true)
		check("unit migrate value is the migrated data", migrated.value == subject)
		check("unit migrate ran steps in order", steps[1] == 1 and steps[2] == 2)
		check("unit migrate stamps schemaVersion", migrated.value.schemaVersion == 2)
		check("unit migrate applied step effects", migrated.value.one == true and migrated.value.two == true)

		-- migrate: default version 0 when schemaVersion is absent runs all steps.
		local stepsNoVersion = {}
		local migrated2 = Reconcile.migrate({}, {
			function(d)
				table.insert(stepsNoVersion, 1)
				return d
			end,
		})
		check("unit migrate defaults missing schemaVersion to 0", #stepsNoVersion == 1 and migrated2.ok == true)
		check("unit migrate stamps version with default start", migrated2.value.schemaVersion == 1)

		-- migrate: a throwing step returns a ProfileMigrationFailed Result.
		local failed = Reconcile.migrate({ schemaVersion = 0 }, {
			function()
				error("kaboom")
			end,
		})
		check("unit migrate failure is not-ok", failed.ok == false)
		check("unit migrate failure names ProfileMigrationFailed", failed.name == "ProfileMigrationFailed")
		check("unit migrate failure records fromVersion and atStep", failed.fromVersion == 0 and failed.atStep == 1)

		-- migrate: an already-current record runs zero steps (idempotent).
		local idempotentSteps = {}
		local idempotent = Reconcile.migrate({ schemaVersion = 1 }, {
			function(d)
				table.insert(idempotentSteps, 1)
				return d
			end,
		})
		check("unit migrate idempotent runs zero steps", #idempotentSteps == 0 and idempotent.ok == true)
		check("unit migrate idempotent keeps schemaVersion", idempotent.value.schemaVersion == 1)

		-- migrate: a record from a NEWER server (schemaVersion > #migrations) is
		-- left untouched at its higher version. Guards against downgrading records
		-- across mixed-version rolling deploys (version skew): stamping the version
		-- DOWN would make a future server re-run already-applied migrations and
		-- corrupt the data.
		local skewSteps = {}
		local skewData = { schemaVersion = 5, coins = 1 }
		local skewed = Reconcile.migrate(skewData, {
			function(d)
				table.insert(skewSteps, "A")
				return d
			end,
			function(d)
				table.insert(skewSteps, "B")
				return d
			end,
		})
		check("unit migrate over-versioned runs zero steps", #skewSteps == 0 and skewed.ok == true)
		check("unit migrate over-versioned never downgrades schemaVersion", skewed.value.schemaVersion == 5)
		check("unit migrate over-versioned leaves data untouched", skewed.value.coins == 1)
	end
end
