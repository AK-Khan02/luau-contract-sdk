# Luau Contract SDK

A small but powerful Luau SDK for making Roblox game systems safer, easier to
reason about, and easier to inspect.

The SDK helps you define contracts around the parts of game code that usually
become fragile over time:

- remote payloads and responses
- server actions that mutate game state
- read/write/effect permissions
- actor and admin policies
- lifecycle state transitions
- postconditions and diagnostics
- contract reports for Studio tooling and docs

The core package is pure Luau. Roblox-specific behavior lives in thin adapters
under `src/Roblox`.

## Why Use It

Large game systems often start with simple handlers and direct mutation. That
works until the same system has several remotes, admin paths, retries, stale
events, and partially failed updates.

Luau Contract SDK gives those flows one explicit contract:

- What input is valid?
- Who may call this?
- What may this action read or write?
- What state must the system be in?
- What state transition should happen after success?
- What response shape should go back to the caller?
- What diagnostic should be recorded when the contract is violated?

The goal is not to replace your game logic. The goal is to wrap important game
logic in a guard that is declarative, testable, and inspectable.

## Before / With SDK

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

RemoteGuard.connect(InventoryContract, "GrantItem", GrantItem, function(player, payload)
	InventoryService.grant(player, payload.ItemId)
end, {
	diagnostics = diagnostics,
})
```

Invalid payloads are rejected consistently and recorded as diagnostics instead
of being handled differently in every remote.

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

local result = InventoryContract:runAction("GrantItem", {
	actor = player,
	payload = payload,
	context = {
		inventory = player.Inventory,
	},
	diagnostics = diagnostics,
}, function(scope)
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
```

The action now validates input, validates output, tracks effects, enforces the
declared write boundary, and checks the postcondition.

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

The SDK makes permission mistakes visible. In strict mode, undeclared reads and
writes fail instead of silently spreading across systems.

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

MatchContract:runAction("StartRound", {
	session = session,
	expectedRevision = session:revision(),
	diagnostics = diagnostics,
}, function()
	return startRound()
end)
```

Lifecycle sessions protect against stale, duplicate, and out-of-order events.
Transitions only commit after the action succeeds.

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

RemoteGuard.connect(InventoryContract, "GrantItem", GrantItemRemote, handler, {
	sessions = {
		inventory = function(player)
			return inventorySessions[player.UserId]
		end,
	},
	diagnostics = diagnostics,
})
```

Remote policy metadata binds the remote to its action, actor policy, response
schema, lifecycle session, revision check, and rate limit.

### Diagnostics And Reports

Before SDK:

```lua
warn("GrantItem failed")
```

With SDK:

```lua
local diagnostics = Contracts.diagnostics({ capacity = 100 })
local overlay = Contracts.OverlayFeed.new(diagnostics, { maxRows = 8 })

local report = InventoryContract:describe()
local studioReport = Contracts.Studio.StudioReport.fromContracts({
	InventoryContract,
}, {
	diagnosticsReport = diagnostics:report(),
})

print(overlay:text())
```

Diagnostics are structured. Contract reports are serializable. Studio tooling can
consume the same contract model that runtime guards use.

## Core Concepts

- `Schema`: validates payloads, action inputs, outputs, and remote responses.
- `System`: names a game system and declares its ownership, permissions,
  actions, remotes, policies, postconditions, and lifecycles.
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
