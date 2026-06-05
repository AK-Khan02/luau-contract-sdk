# Luau Contract SDK

A compact Luau contract runtime for Roblox game systems. It turns remote calls,
server actions, permissions, lifecycle state, diagnostics, and reports into one
executable contract instead of scattered defensive checks.

The SDK is built for game systems where a bad call can mutate player data, grant
items twice, run in the wrong match state, bypass an admin check, or fail without
leaving useful diagnostics.

Use it to define and enforce:

- remote payload and response schemas
- guarded server actions for important mutations
- read/write/effect permissions
- actor and admin policies
- lifecycle state requirements and transitions
- preconditions, postconditions, and named diagnostics
- runtime handlers, lifecycle sessions, and remote binding
- stable reports for overlays, docs, tests, and Studio tooling

The core package is pure Luau. Roblox-specific behavior lives in thin adapters
under `src/Roblox`.

## Why Use It

Roblox code often grows around remotes first: validate a payload here, check an
admin there, mutate a table, return a result, maybe print a warning. That works
while the system is small. It becomes fragile when the same feature has several
entry points, retries, lifecycle timing, rate limits, and stateful side effects.

Luau Contract SDK gives those flows one enforced runtime boundary:

- What input is valid?
- Who may call this?
- What may this action read or write?
- What state must the system be in?
- What state transition should happen after success?
- What response shape should go back to the caller?
- What diagnostic should be recorded when the contract is violated?

The game logic stays yours. The SDK wraps the risky boundary around it so the
rules are declared once, enforced consistently, tested directly, and exposed as
plain report data.

That gives you:

- safer remotes: payloads, responses, actors, lifecycle guards, and rate limits
  are checked before game code trusts the call.
- safer mutations: actions can only read, write, create, destroy, or touch the
  paths they declared.
- safer state machines: stale, duplicate, and out-of-order events fail before
  they advance a lifecycle session.
- better failures: violations are named diagnostics that tools, tests, overlays,
  and reports can consume.
- better architecture: contract definitions, runtime handlers, Roblox adapters,
  and reporting stay separate but connected by one model.

## Before / With SDK

These examples show the same pattern: move scattered defensive code into a
contract, then route execution through `Contracts.runtime(...)`.

### Remote Payload Validation

Before SDK:

```lua
GrantItem.OnServerEvent:Connect(function(player, payload)
	if type(payload) ~= "table" then
		return
	end
	if type(payload.ItemId) ~= "string" or payload.ItemId == "" then
		return
	end
	if string.find(payload.ItemId, "../", 1, true) then
		return
	end

	InventoryService.grant(player, payload.ItemId)
end)
```

With SDK:

```lua
local GrantItemSchema = Contracts.object({
	ItemId = Contracts.stringId(),
}, {
	allowExtra = false,
})

local InventoryContract = Contracts.system("InventoryService")
	:remote("GrantItem", GrantItemSchema)

local runtime = Contracts.runtime(InventoryContract, {
	diagnostics = diagnostics,
})

runtime:bindRemote("GrantItem", GrantItem, {
	handler = function(player, payload)
		InventoryService.grant(player, payload.ItemId)
	end,
})
```

Invalid payloads are rejected consistently and recorded as diagnostics instead
of being handled differently in every remote. The remote handler can focus on the
actual game operation because the boundary already normalized the call.

### Guarded State Mutation

Before SDK:

```lua
GrantItem.OnServerEvent:Connect(function(player, payload)
	local item = Catalog[payload.ItemId]
	if not item then
		return
	end

	player.Inventory[payload.ItemId] = true
	print("granted item")
end)
```

With SDK:

```lua
local GrantItemResult = Contracts.object({
	granted = Contracts.boolean(),
	itemId = Contracts.stringId(),
}, {
	allowExtra = false,
})

local InventoryContract = Contracts.system("InventoryService")
	:strictPermissions()
	:mayRead("Catalog.Items")
	:mayWrite("Player.Inventory")
	:postcondition("InventoryContainsGrantedItem", function(context)
		return context.inventory[context.result.itemId] == true
	end)
	:action("GrantItem", {
		input = GrantItemSchema,
		output = GrantItemResult,
		reads = { "Catalog.Items" },
		writes = { "Player.Inventory" },
		postconditions = { "InventoryContainsGrantedItem" },
	})

local runtime = Contracts.runtime(InventoryContract, {
	diagnostics = diagnostics,
})

runtime:implement("GrantItem", function(scope)
	local itemId = scope:read("Catalog.Items", function(context)
		return context.payload.ItemId
	end)

	return scope:write("Player.Inventory", function(context)
		context.inventory[itemId] = true
		return {
			granted = true,
			itemId = itemId,
		}
	end)
end)

local result = runtime:invoke("GrantItem", {
	actor = player,
	payload = payload,
	context = {
		inventory = player.Inventory,
	},
})
```

The action now validates input, validates output, records effects, enforces the
declared write boundary, and checks the postcondition. Tests can assert the
contract behavior without needing to simulate every Roblox object involved in the
real game.

### Permission Boundaries

Before SDK:

```lua
local function saveReward(player, reward)
	player.Profile.Currency += reward.Coins
	player.Inventory.Items[reward.ItemId] = true
end
```

With SDK:

```lua
local InventoryContract = Contracts.system("InventoryService")
	:strictPermissions()
	:mayWrite("Player.Inventory")
	:mustNeverTouch("Player.Profile")
	:action("GrantItem", {
		writes = { "Player.Inventory.Items" },
	})

local ok = InventoryContract:checkActionEffect("GrantItem", {
	kind = "write",
	target = "Player.Profile.Currency",
}, diagnostics)
```

The SDK makes permission mistakes visible before they become architectural drift.
In strict mode, undeclared reads and writes fail instead of silently spreading
across systems.

### Lifecycle State Enforcement

Before SDK:

```lua
StartRound.OnServerEvent:Connect(function(player)
	if match.State ~= "Lobby" then
		return
	end

	match.State = "Running"
	startRound()
end)
```

With SDK:

```lua
local MatchLifecycle = Contracts.lifecycle("Match")
	:transition("Lobby", "RoundStarted", "Running")
	:transition("Running", "RoundEnded", "Results")
	:transition("Results", "Reset", "Lobby")

local MatchContract = Contracts.system("MatchService")
	:lifecycle("Match", MatchLifecycle)
	:action("StartRound", {
		lifecycle = {
			requires = {
				Match = "Lobby",
			},
			emits = {
				Match = "RoundStarted",
			},
		},
	})

local session = MatchContract:lifecycleSession({
	Match = "Lobby",
})

local runtime = Contracts.runtime(MatchContract, {
	sessions = {
		match = session,
	},
	diagnostics = diagnostics,
})

runtime:implement("StartRound", function()
	return startRound()
end)

runtime:invoke("StartRound", {
	sessionName = "match",
	expectedRevision = session:revision(),
})
```

Lifecycle sessions protect against stale, duplicate, and out-of-order events.
Transitions only commit after the action succeeds, so failed handlers, bad
outputs, and failed postconditions do not advance game state.

### Remote Policies

Before SDK:

```lua
GrantItem.OnServerInvoke = function(player, payload)
	if not Admins[player.UserId] then
		return nil
	end
	if RateLimit.exceeded(player.UserId, "GrantItem") then
		return nil
	end

	local result = grantItem(player, payload.ItemId)
	if type(result) ~= "table" or type(result.granted) ~= "boolean" then
		return nil
	end
	return result
end
```

With SDK, assuming `GrantItem` is declared as an action:

```lua
local InventoryContract = Contracts.system("InventoryService")
	:actorPolicy("admin", function(player)
		return Admins[player.UserId] == true
	end)
	:remote("GrantItem", GrantItemSchema, {
		action = "GrantItem",
		direction = "server",
		actor = "admin",
		response = GrantItemResult,
		lifecycle = {
			session = "inventory",
			revision = "Revision",
		},
		rateLimit = {
			maxRequests = 4,
			windowSeconds = 1,
			key = "payload.ItemId",
		},
	})

local runtime = Contracts.runtime(InventoryContract, {
	sessions = {
		inventory = function(request)
			return inventorySessions[request.actor.UserId]
		end,
	},
	diagnostics = diagnostics,
})

runtime:implement("GrantItem", function(scope)
	return grantItem(scope:actor(), scope:payload().ItemId)
end)

runtime:bindRemote("GrantItem", GrantItemRemote)
```

Runtime binding routes the remote through the action contract, actor policy,
response schema, lifecycle session, revision check, and rate limit. The handler
stays small because the remote policy owns the boundary rules.

### Diagnostics And Reports

Before SDK:

```lua
warn("GrantItem failed")
```

With SDK:

```lua
local diagnostics = Contracts.diagnostics({ capacity = 100 })
local overlay = Contracts.OverlayFeed.new(diagnostics, { maxRows = 8 })
local runtimeReport = runtime:describe()

local report = InventoryContract:describe()
local studioReport = Contracts.Studio.StudioReport.fromContracts({
	InventoryContract,
}, {
	diagnosticsReport = diagnostics:report(),
})

print(overlay:text())
print(runtimeReport.system.name)
```

Diagnostics are structured. Contract and runtime reports are serializable. Studio
tooling, overlays, tests, and docs can consume the same model that runtime guards
use.

## Core Concepts

- `Schema`: validates payloads, action inputs, outputs, and remote responses.
- `System`: names a game system and declares its ownership, permissions,
  actions, remotes, policies, postconditions, and lifecycles.
- `Runtime`: owns action implementations, named lifecycle sessions, remote
  connections, diagnostics, and runtime reports.
- `Action`: wraps meaningful work in one guarded path.
- `ActionScope`: records and enforces reads, writes, creates, destroys, and
  touches during an action.
- `Lifecycle`: defines allowed states and transitions.
- `LifecycleSession`: stores current lifecycle state, revision, snapshots, and
  guarded transition commits.
- `RemoteGuard`: Roblox adapter that validates guarded remote calls.
- `Diagnostics`: ring buffer for structured contract violations.
- `StudioReport`: plain model for scanner findings, diagnostics, and contract
  reports.

## Package Shape

```text
default.project.json
wally.toml
src/
  init.lua
  Package.lua
  Contracts.lua
  Core/
    ActionScope.lua
    ContractReport.lua
    DiagnosticReport.lua
    Diagnostics.lua
    Invariant.lua
    Lifecycle.lua
    LifecycleSession.lua
    OverlayFeed.lua
    RateLimiter.lua
    RemotePolicy.lua
    Runtime.lua
    Schema.lua
    StaticScanner.lua
    System.lua
  Studio/
    init.lua
    StudioReport.lua
  Roblox/
    init.lua
    Ownership.lua
    OverlayState.lua
    PostconditionRunner.lua
    RemoteGuard.lua
examples/
  checkpoint.contract.lua
  inventory.contract.lua
  spawn_loadout.contract.lua
tests/
  run.lua
  TestHarness.lua
  suites/
plugin/
  LuauContractStudioPlugin.lua
  LuauContractPluginModel.lua
```

## Validation

Run the pure test suite and analyzer:

```sh
luau tests/run.lua
luau-analyze src/**/*.lua examples/**/*.lua tests/**/*.lua plugin/*.lua
```

The core package is Roblox-free and the core modules run in strict Luau mode, so
these tests run outside Studio. The files under `src/Roblox` are thin adapters
that should be exercised inside a Roblox place or with fake RemoteEvent-like
objects.

## Documentation

- [API](docs/API.md)
- [Integration](docs/INTEGRATION.md)

## Usage Notes

The SDK enforces contracts on code paths that use its guards. Route important
remotes, actions, state transitions, and mutations through the SDK to get
validation, diagnostics, rate limits, permission checks, and stable reports.

The static scanner can also flag risky source patterns such as raw remote
handlers, raw remote firing, broad cleanup, and unowned destroys.

## License

Proprietary. All rights reserved. See `LICENSE`.
