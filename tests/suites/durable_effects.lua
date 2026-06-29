--!nonstrict

local Contracts = require("../../src/Contracts")

-- Inline in-memory DurableStore fake. No DataStoreService: a map of values plus a
-- lock registry, mirroring the real DurableDataStore session-lock semantics so the
-- suite runs as pure Luau outside Studio.
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
		failNextSave = false,
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
	if self.failNextSave then
		self.failNextSave = false
		return { ok = false, name = "DurableCommitFailed", reason = "save rejected" }
	end
	if self.locks[key] ~= lock then
		return { ok = false, name = "SessionLockLost", reason = "lock no longer held for " .. key }
	end
	self.data[key] = deepCopy(value)
	return { ok = true, name = "DurableSaved" }
end

function FakeProfileStore.release(self, key, lock)
	if self.locks[key] == lock then
		self.locks[key] = nil
	end
	return { ok = true, name = "DurableReleased" }
end

-- A second server already holds the lock before we ever load (vector a).
function FakeProfileStore.prelock(self, key, otherOwner)
	self.locks[key] = otherOwner or { id = -1 }
end

-- A second server takes the lock across a yield, after we loaded (vector c).
function FakeProfileStore.stealLock(self, key)
	self.locks[key] = { id = -99 }
end

local ProfileOutput = Contracts.object({
	granted = Contracts.boolean(),
}, {
	allowExtra = false,
})

local function newDurableSystem()
	return Contracts.system("DurablePersistence")
		:strictPermissions()
		:mayWrite("Player.Profile")
		:mayWrite("Player.Cache")
		:postcondition("ProfileDeferredUntilCommit", function(context)
			-- A staged durable write must not have hit the store yet while
			-- postconditions run; the store still shows the OLD value.
			local store = context.store
			return store.data.Player_1 ~= nil and store.data.Player_1.coins == 5
		end)
		:action("Grant", {
			output = ProfileOutput,
			writes = { "Player.Profile" },
		})
		:action("GrantDeferred", {
			output = ProfileOutput,
			writes = { "Player.Profile" },
			postconditions = { "ProfileDeferredUntilCommit" },
		})
		:action("GrantThenStealLock", {
			output = ProfileOutput,
			writes = { "Player.Profile" },
		})
		:action("GrantWithMemoryWrite", {
			output = ProfileOutput,
			writes = { "Player.Profile", "Player.Cache" },
		})
		:action("GrantThenThrow", {
			output = ProfileOutput,
			writes = { "Player.Profile" },
		})
		:action("GrantUndeclared", {
			output = ProfileOutput,
			writes = { "Player.Profile" },
		})
end

return function(test)
	local function check(name, condition)
		test:check(name, condition)
	end

	test:section("DurableEffects")

	-- 1. Happy path: load -> writeDurable -> action ok -> store has new value.
	do
		local store = newStore()
		store:seed("Player_1", { coins = 5, inventory = {} })
		local system = newDurableSystem()

		local loaded = Contracts.loadProfile(store, "Player_1")
		check("happy path loads profile", loaded.ok == true and loaded.name == "DurableProfileLoaded")

		local profile = loaded.profile
		local result = system:runAction("Grant", {
			context = { store = store },
		}, function(scope)
			scope:writeDurable("Player.Profile", profile, function(data)
				data.coins = data.coins + 100
				return data
			end)
			return { granted = true }
		end)

		check("happy path action succeeds", result.ok == true)
		check("happy path persists new value", store.data.Player_1.coins == 105)
		check(
			"happy path reports committed write effect",
			result.effects[1].kind == "write" and result.effects[1].status == "committed"
		)
	end

	-- 2. Deferred until commit: a postcondition asserts the store still shows the
	--    OLD value while postconditions run. Proves staged, not eager.
	do
		local store = newStore()
		store:seed("Player_1", { coins = 5 })
		local system = newDurableSystem()
		local profile = Contracts.loadProfile(store, "Player_1").profile

		local result = system:runAction("GrantDeferred", {
			context = { store = store },
		}, function(scope)
			scope:writeDurable("Player.Profile", profile, function(data)
				data.coins = 500
				return data
			end)
			return { granted = true }
		end)

		check("deferred write passes the deferral postcondition", result.ok == true)
		check("deferred write applies only at commit", store.data.Player_1.coins == 500)
	end

	-- 3. Vector (a) two servers: prelock then load -> SessionLockUnavailable;
	--    handler errors with the failure -> action fails, store unchanged.
	do
		local store = newStore()
		store:seed("Player_1", { coins = 5 })
		store:prelock("Player_1", { id = 777 })

		local loaded = Contracts.loadProfile(store, "Player_1")
		check(
			"prelocked load reports SessionLockUnavailable",
			loaded.ok == false and loaded.name == "SessionLockUnavailable"
		)
		check("prelocked load leaves store unchanged", store.data.Player_1.coins == 5)
	end

	-- 4. Vector (c) lock lost across yield: load, stage write, steal lock before
	--    commit; action fails ActionCommitFailed, SessionLockLost recorded,
	--    store NOT written. Fails closed.
	do
		local store = newStore()
		store:seed("Player_1", { coins = 5 })
		local system = newDurableSystem()
		local profile = Contracts.loadProfile(store, "Player_1").profile
		local diagnostics = Contracts.diagnostics()

		local result = system:runAction("GrantThenStealLock", {
			context = { store = store },
			diagnostics = diagnostics,
		}, function(scope)
			scope:writeDurable("Player.Profile", profile, function(data)
				data.coins = 999
				return data
			end)
			-- A second server grabs the lock during the (modelled) yield window
			-- before our staged effect commits.
			store:stealLock("Player_1")
			return { granted = true }
		end)

		check("lock lost fails the action", result.ok == false and result.name == "ActionCommitFailed")
		check("lock lost leaves the store unwritten", store.data.Player_1.coins == 5)
		check("lock lost records SessionLockLost diagnostic", #diagnostics:findByName("SessionLockLost") == 1)
		check("lock lost marks the effect failed", result.effects[1].status == "failed")
	end

	-- 5. Commit failure rolls back a co-staged in-memory write.
	do
		local store = newStore()
		store:seed("Player_1", { coins = 5 })
		store.failNextSave = true
		local system = newDurableSystem()
		local profile = Contracts.loadProfile(store, "Player_1").profile
		local cache = {}
		local diagnostics = Contracts.diagnostics()

		local result = system:runAction("GrantWithMemoryWrite", {
			context = { store = store, cache = cache },
			diagnostics = diagnostics,
		}, function(scope)
			-- In-memory write staged first; it commits, then the durable save
			-- fails and the in-memory write must roll back.
			scope:write("Player.Cache", {
				commit = function(context)
					context.cache.dirty = true
				end,
				rollback = function(context)
					context.cache.dirty = nil
				end,
			})
			scope:writeDurable("Player.Profile", profile, function(data)
				data.coins = 42
				return data
			end)
			return { granted = true }
		end)

		check("save failure fails the action", result.ok == false and result.name == "ActionCommitFailed")
		check("save failure rolls back the co-staged in-memory write", cache.dirty == nil)
		check("save failure leaves the store unwritten", store.data.Player_1.coins == 5)
		check(
			"save failure reports rolledBack and failed statuses",
			result.effects[1].status == "rolledBack" and result.effects[2].status == "failed"
		)
		check(
			"save failure records DurableCommitFailed diagnostic",
			#diagnostics:findByName("DurableCommitFailed") == 1
		)
	end

	-- 6. Durable rollback compensates: a durable write succeeds, then a later
	--    staged effect throws on commit; the store is restored to its previous
	--    value via the durable rollback.
	do
		local store = newStore()
		store:seed("Player_1", { coins = 5 })
		local system = newDurableSystem()
		local profile = Contracts.loadProfile(store, "Player_1").profile

		local result = system:runAction("GrantThenThrow", {
			context = { store = store },
		}, function(scope)
			scope:writeDurable("Player.Profile", profile, function(data)
				data.coins = 250
				return data
			end)
			scope:write("Player.Profile", {
				commit = function()
					error("downstream commit exploded")
				end,
			})
			return { granted = true }
		end)

		check("downstream failure fails the action", result.ok == false and result.name == "ActionCommitFailed")
		check("durable rollback restores the previous stored value", store.data.Player_1.coins == 5)
		check(
			"durable rollback reports rolledBack then failed",
			result.effects[1].status == "rolledBack" and result.effects[2].status == "failed"
		)
		check("durable rollback succeeds", result.rollback.ok == true and result.rollback.rolledBack == 1)
	end

	-- 7. WriteNotAllowed: writeDurable to an undeclared path fails before staging.
	do
		local store = newStore()
		store:seed("Player_1", { coins = 5 })
		local system = newDurableSystem()
		local profile = Contracts.loadProfile(store, "Player_1").profile

		local result = system:runAction("GrantUndeclared", {
			context = { store = store },
		}, function(scope)
			return scope:writeDurable("Player.Bank", profile, function(data)
				data.coins = 1
				return data
			end)
		end)

		check("undeclared durable path fails WriteNotAllowed", result.ok == false and result.name == "WriteNotAllowed")
		check("undeclared durable path leaves store unchanged", store.data.Player_1.coins == 5)
	end

	-- 8. DurableEffect.operation unit-level: commit/rollback directly against the
	--    fake. Lost lock raises a tagged SessionLockLost; healthy lock saves.
	do
		local store = newStore()
		store:seed("Player_1", { coins = 5 })
		local loaded = Contracts.loadProfile(store, "Player_1")
		local profile = loaded.profile

		local op = Contracts.DurableEffect.operation({
			store = store,
			key = profile:key(),
			lock = profile:lock(),
			value = { coins = 77 },
			previous = profile:value(),
		})

		local committed = op.commit({})
		check("operation commit saves the new value", committed.saved.coins == 77 and store.data.Player_1.coins == 77)

		local restored = op.rollback({})
		check(
			"operation rollback re-saves the captured previous value",
			restored.restored.coins == 5 and store.data.Player_1.coins == 5
		)

		-- Lost lock: commit must raise a SessionLockLost-tagged error.
		store:stealLock("Player_1")
		local ok, err = pcall(op.commit, {})
		check(
			"operation commit fails closed when the lock is lost",
			ok == false and Contracts.DurableEffect.diagnosticName(tostring(err)) == "SessionLockLost"
		)
	end
end
