--!nonstrict

local Contracts = require("../../src/Contracts")

-- Inline in-memory DurableStore fake -- the durable_effects.lua FakeProfileStore
-- shape, extended for the multi-key trade scenarios: per-key save failure
-- (`failSaveForKey`) so we can fail B's save while A's succeeds, which is exactly
-- the atomicity vector a single global `failNextSave` flag cannot express.
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
		failKeys = {},
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
	if self.failKeys[key] then
		self.failKeys[key] = nil
		return { ok = false, name = "DurableCommitFailed", reason = "save rejected for " .. key }
	end
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

-- The next save for this specific key fails (vector: B's save fails after A's
-- already committed, so A must roll back).
function FakeProfileStore.failSaveForKey(self, key)
	self.failKeys[key] = true
end

-- A second server already holds the lock before we ever load (vector a).
function FakeProfileStore.prelock(self, key, otherOwner)
	self.locks[key] = otherOwner or { id = -1 }
end

-- A second server takes the lock across a yield, after we loaded (vector c).
function FakeProfileStore.stealLock(self, key)
	self.locks[key] = { id = -99 }
end

local TradeOutput = Contracts.object({
	traded = Contracts.boolean(),
}, {
	allowExtra = false,
})

local function newTradeSystem()
	return Contracts.system("DurableTrade"):strictPermissions():mayWrite("Player.Profile"):action("Trade", {
		output = TradeOutput,
		writes = { "Player.Profile" },
	})
end

-- A canonical trade body: move `item` out of `from`'s inventory and into `to`'s,
-- each as a staged durable write. EffectPlan commits A then B and compensates in
-- reverse, so under a normal single commit failure the pair is all-or-nothing
-- without DurableTransaction doing any commit work of its own. (A *failed
-- compensation* can still leave it non-atomic -- there is no two-phase commit
-- across DataStore keys; the partial-rollback test below pins that limitation.)
local function stageTrade(scope, from, to, item)
	scope:writeDurable("Player.Profile", from, function(data)
		data.inventory[item] = nil
		return data
	end)
	scope:writeDurable("Player.Profile", to, function(data)
		data.inventory[item] = true
		return data
	end)
end

return function(test)
	local function check(name, condition)
		test:check(name, condition)
	end

	test:section("DurableTransactions")

	local A_KEY = "Player_A"
	local B_KEY = "Player_B"
	local ITEM = "Sword_1"

	-- 1. Canonical trade success: item moves from A to B, present in exactly one
	--    inventory. Vector (d) closed.
	do
		local store = newStore()
		store:seed(A_KEY, { inventory = { [ITEM] = true } })
		store:seed(B_KEY, { inventory = {} })
		local system = newTradeSystem()

		local txn = Contracts.durableTransaction(store)
		local a = txn:load(A_KEY)
		local b = txn:load(B_KEY)
		check("trade loads both profiles", txn:ok() == true and a.ok == true and b.ok == true)
		check("trade tracks both acquired profiles", #txn:profiles() == 2)

		local result = system:runAction("Trade", {
			context = { store = store },
		}, function(scope)
			if not txn:ok() then
				error(txn:firstFailure())
			end
			stageTrade(scope, a.profile, b.profile, ITEM)
			return { traded = true }
		end)

		check("trade succeeds", result.ok == true)
		check("trade removes the item from A", store.data[A_KEY].inventory[ITEM] == nil)
		check("trade adds the item to B", store.data[B_KEY].inventory[ITEM] == true)
		check(
			"trade leaves the item in exactly one inventory",
			(store.data[A_KEY].inventory[ITEM] == nil) and (store.data[B_KEY].inventory[ITEM] == true)
		)
		check(
			"trade reports two committed durable writes",
			result.effects[1].status == "committed" and result.effects[2].status == "committed"
		)
	end

	-- 2. Atomicity -- second save fails: failSaveForKey(B) -> A's durable write is
	--    rolled back (item still in A, never in B).
	do
		local store = newStore()
		store:seed(A_KEY, { inventory = { [ITEM] = true } })
		store:seed(B_KEY, { inventory = {} })
		store:failSaveForKey(B_KEY)
		local system = newTradeSystem()
		local diagnostics = Contracts.diagnostics()

		local txn = Contracts.durableTransaction(store)
		local a = txn:load(A_KEY)
		local b = txn:load(B_KEY)

		local result = system:runAction("Trade", {
			context = { store = store },
			diagnostics = diagnostics,
		}, function(scope)
			if not txn:ok() then
				error(txn:firstFailure())
			end
			stageTrade(scope, a.profile, b.profile, ITEM)
			return { traded = true }
		end)

		check("atomic trade fails on B's save", result.ok == false and result.name == "ActionCommitFailed")
		check("atomic trade rolls back A's durable write", store.data[A_KEY].inventory[ITEM] == true)
		check("atomic trade never writes the item to B", store.data[B_KEY].inventory[ITEM] == nil)
		check(
			"atomic trade reports A rolledBack and B failed",
			result.effects[1].status == "rolledBack" and result.effects[2].status == "failed"
		)
		check(
			"atomic trade records DurableCommitFailed diagnostic",
			#diagnostics:findByName("DurableCommitFailed") == 1
		)
	end

	-- 3. Abort -- one lock unavailable: prelock(B, "ServerB"); txn:load(B) fails ->
	--    txn:ok() == false; abort; A's lock is released after txn:release(); neither
	--    inventory mutated.
	do
		local store = newStore()
		store:seed(A_KEY, { inventory = { [ITEM] = true } })
		store:seed(B_KEY, { inventory = {} })
		store:prelock(B_KEY, { id = 777 })
		local diagnostics = Contracts.diagnostics()

		local txn = Contracts.durableTransaction(store)
		local a = txn:load(A_KEY)
		local b = txn:load(B_KEY)

		check("abort: A loads", a.ok == true)
		check("abort: B is refused (lock unavailable)", b.ok == false and b.name == "SessionLockUnavailable")
		check("abort: transaction is not ok", txn:ok() == false)
		check(
			"abort: firstFailure is the SessionLockUnavailable result",
			txn:firstFailure() ~= nil and txn:firstFailure().name == "SessionLockUnavailable"
		)
		check("abort: A's lock is held before release", store:owns(A_KEY, a.profile:lock()) == true)

		local aLock = a.profile:lock()
		local released = txn:release(diagnostics)
		check("abort: release reports success", released.ok == true and released.released == 1)
		check("abort: A's lock is freed after release", store:owns(A_KEY, aLock) == false)
		check("abort: A's inventory is untouched", store.data[A_KEY].inventory[ITEM] == true)
		check("abort: B's inventory is untouched", store.data[B_KEY].inventory[ITEM] == nil)

		-- 5. DurableTransactionAborted rollup recorded on the abort path.
		check(
			"abort: records the DurableTransactionAborted rollup",
			#diagnostics:findByName("DurableTransactionAborted") == 1
		)
	end

	-- 4. Lock lost mid-trade: steal B's lock after staging -> ActionCommitFailed +
	--    SessionLockLost, A rolled back.
	do
		local store = newStore()
		store:seed(A_KEY, { inventory = { [ITEM] = true } })
		store:seed(B_KEY, { inventory = {} })
		local system = newTradeSystem()
		local diagnostics = Contracts.diagnostics()

		local txn = Contracts.durableTransaction(store)
		local a = txn:load(A_KEY)
		local b = txn:load(B_KEY)

		local result = system:runAction("Trade", {
			context = { store = store },
			diagnostics = diagnostics,
		}, function(scope)
			if not txn:ok() then
				error(txn:firstFailure())
			end
			stageTrade(scope, a.profile, b.profile, ITEM)
			-- A second server grabs B's lock during the (modelled) yield window
			-- before our staged effects commit. A commits first, then B's commit
			-- detects the lost lock and fails closed, rolling A back.
			store:stealLock(B_KEY)
			return { traded = true }
		end)

		check("lock lost mid-trade fails the action", result.ok == false and result.name == "ActionCommitFailed")
		check("lock lost mid-trade rolls back A", store.data[A_KEY].inventory[ITEM] == true)
		check("lock lost mid-trade never writes B", store.data[B_KEY].inventory[ITEM] == nil)
		check(
			"lock lost mid-trade reports A rolledBack and B failed",
			result.effects[1].status == "rolledBack" and result.effects[2].status == "failed"
		)
		check("lock lost mid-trade records SessionLockLost diagnostic", #diagnostics:findByName("SessionLockLost") == 1)
	end

	-- Bonus: a successful transaction releases cleanly with no abort rollup, and
	-- release is idempotent.
	do
		local store = newStore()
		store:seed(A_KEY, { inventory = {} })
		store:seed(B_KEY, { inventory = {} })
		local diagnostics = Contracts.diagnostics()

		local txn = Contracts.durableTransaction(store)
		local a = txn:load(A_KEY)
		local b = txn:load(B_KEY)

		local aLock = a.profile:lock()
		local bLock = b.profile:lock()
		local released = txn:release(diagnostics)
		check("clean release frees both locks", released.ok == true and released.released == 2)
		check("clean release frees A", store:owns(A_KEY, aLock) == false)
		check("clean release frees B", store:owns(B_KEY, bLock) == false)
		check("clean release records no abort rollup", #diagnostics:findByName("DurableTransactionAborted") == 0)

		local again = txn:release(diagnostics)
		check("release is idempotent", again.ok == true and again.released == 0)
	end

	-- Aborted transaction: calling release twice must record the
	-- DurableTransactionAborted rollup AT MOST ONCE (regression for the
	-- double-record bug). The first release frees the acquired lock and records the
	-- rollup; the second is a no-op and must NOT record a second rollup.
	do
		local store = newStore()
		store:seed(A_KEY, { inventory = { [ITEM] = true } })
		store:seed(B_KEY, { inventory = {} })
		store:prelock(B_KEY, { id = 777 })
		local diagnostics = Contracts.diagnostics()

		local txn = Contracts.durableTransaction(store)
		txn:load(A_KEY)
		txn:load(B_KEY) -- fails: B is prelocked

		txn:release(diagnostics)
		txn:release(diagnostics)
		check(
			"double release records the abort rollup only once",
			#diagnostics:findByName("DurableTransactionAborted") == 1
		)
	end

	-- ACCEPTED LIMITATION (NOT desired behavior): a trade spans two independent
	-- DataStore keys and there is no two-phase commit. If a *compensating rollback*
	-- itself fails, the trade is left NON-ATOMIC. This test pins the rare duplication
	-- path deterministically: both durable saves commit (item removed from A, added
	-- to B), then a later in-memory effect steals B's lock and throws on commit,
	-- forcing EffectPlan's reverse rollback. B's compensation fails closed (lock
	-- lost -> SessionLockLost -> ActionRollbackFailed) while A's compensation
	-- succeeds, so the item ends up in BOTH inventories. We assert that torn state
	-- to document the no-2PC limitation; the docs tell operators to treat the
	-- ActionRollbackFailed diagnostic on a durable effect as a reconciliation signal.
	do
		local store = newStore()
		store:seed(A_KEY, { inventory = { [ITEM] = true } })
		store:seed(B_KEY, { inventory = {} })
		local system = newTradeSystem()
		local diagnostics = Contracts.diagnostics()

		local txn = Contracts.durableTransaction(store)
		local a = txn:load(A_KEY)
		local b = txn:load(B_KEY)

		local result = system:runAction("Trade", {
			context = { store = store },
			diagnostics = diagnostics,
		}, function(scope)
			if not txn:ok() then
				error(txn:firstFailure())
			end
			-- A removes the item, B adds it -- both durable writes commit.
			stageTrade(scope, a.profile, b.profile, ITEM)
			-- A later staged in-memory effect commits AFTER both durable saves, then
			-- throws -- triggering reverse rollback. Its commit first steals B's lock
			-- so that, when EffectPlan walks back, B's durable compensation can no
			-- longer save (fails closed) while A's compensation still succeeds.
			scope:write("Player.Profile", {
				commit = function()
					store:stealLock(B_KEY)
					error("downstream commit exploded after both saves committed")
				end,
			})
			return { traded = true }
		end)

		check("torn trade fails the action", result.ok == false and result.name == "ActionCommitFailed")
		check("torn trade: A's removal was rolled back (item back in A)", store.data[A_KEY].inventory[ITEM] == true)
		check(
			"torn trade: B's add could NOT be rolled back (item still in B)",
			store.data[B_KEY].inventory[ITEM] == true
		)
		check(
			"torn trade is NON-ATOMIC: item duplicated into both inventories (accepted no-2PC limitation)",
			store.data[A_KEY].inventory[ITEM] == true and store.data[B_KEY].inventory[ITEM] == true
		)
		check(
			"torn trade records ActionRollbackFailed (the reconciliation signal)",
			#diagnostics:findByName("ActionRollbackFailed") >= 1
		)
		check(
			"torn trade records SessionLockLost from the failed compensation",
			#diagnostics:findByName("SessionLockLost") >= 1
		)
	end
end
