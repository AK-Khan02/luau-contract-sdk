# API

## Package Entry

Filesystem tests and examples can require the package root:

```lua
local Contracts = require("../src")
```

Inside a packaged Roblox project, require the package ModuleScript that maps to
`src/init.lua`.

## Contract Builder

```lua
local PlayerLifecycle = Contracts.lifecycle("Player")
	:transition("Alive", "WeaponAction", "Alive")

local Contract = Contracts.system("CombatService")
	:ownsTag("GeneratedWeaponTool")
	:ownsFolder("Workspace.CombatEffects")
	:mayRead("Player.Character")
	:mayWrite("Player.Backpack")
	:mustNeverTouch("Workspace.CurrentArena")
	:strictPermissions()
	:actorPolicy("player", function(actor)
		return actor ~= nil
	end)
	:lifecycle("Player", PlayerLifecycle)
	:precondition("CharacterLoaded", function(context)
		return context.character ~= nil
	end)
	:postcondition("PlayerHasWeapon", function(context)
		return context.weaponCount == 1
	end)
	:action("WeaponAction", {
		input = Contracts.object({
			Action = Contracts.oneOf({ "Fire", "Reload" }),
			WeaponId = Contracts.stringId(),
		}),
		output = Contracts.object({
			accepted = Contracts.boolean(),
		}),
		reads = { "Player.Character" },
		writes = { "Player.Backpack" },
		preconditions = { "CharacterLoaded" },
		postconditions = { "PlayerHasWeapon" },
		lifecycle = {
			requires = {
				Player = "Alive",
			},
			emits = {
				Player = "WeaponAction",
			},
		},
		remote = {
			name = "WeaponAction",
			direction = "server",
			actor = "player",
			response = Contracts.object({
				accepted = Contracts.boolean(),
			}),
			lifecycle = {
				session = "player",
			},
			rateLimit = {
				maxRequests = 10,
				windowSeconds = 5,
			},
		},
		policy = {
			actorRequired = true,
		},
	})
```

## Action Contracts

Actions are the primary runtime guard for meaningful game operations. They can
validate input, validate output, enforce scoped effects, stage transactional
effects, check actor policy, run preconditions and postconditions, and apply
lifecycle transitions.

```lua
local session = Contract:lifecycleSession({
	Player = "Alive",
})

local result = Contract:runAction("WeaponAction", {
	actor = player,
	payload = {
		Action = "Fire",
		WeaponId = "Rifle",
	},
	context = {
		character = character,
		weaponCount = 1,
	},
	session = session,
	expectedRevision = session:revision(),
	diagnostics = diagnostics,
}, function(scope)
	local payload = scope:payload()

	scope:read("Player.Character", function(context)
		return context.character
	end)

	return scope:write("Player.Backpack", function()
		return {
			accepted = payload.Action == "Fire",
		}
	end)
end)
```

`runAction` returns a plain table:

- `ok`
- `name`
- `value`
- `context`
- `effects`
- `preconditions`
- `postconditions`
- `lifecycle`
- `commit`
- `rollback`

Action definitions support:

- `input`
- `output`
- `context`
- `reads`
- `writes`
- `touches`
- `creates`
- `destroys`
- `forbids`
- `preconditions`
- `postconditions`
- `lifecycle.requires`
- `lifecycle.emits`
- `remote`
- `policy`
- `tags`

Useful action methods:

- `contract:action(name, definition)`
- `contract:actionOptions(name)`
- `contract:hasAction(name)`
- `contract:actorPolicy(name, check)`
- `contract:validateActionInput(name, payload, diagnostics, context)`
- `contract:validateActionOutput(name, value, diagnostics, context)`
- `contract:validateActionContext(name, context, diagnostics)`
- `contract:runAction(name, options, handler)`
- `contract:lifecycleSession(initialStates, options)`

The action scope passed to the handler exposes:

- `scope:payload()`
- `scope:input()`
- `scope:context()`
- `scope:actor()`
- `scope:read(path, readerOrValue)`
- `scope:write(path, writerOrValue)`
- `scope:create(path, creatorOrValue)`
- `scope:destroy(path, destroyerOrValue)`
- `scope:touch(path, toucherOrValue)`
- `scope:stageEffect(kind, path, commitOrEffect)`
- `scope:stageWrite(path, commitOrEffect)`
- `scope:stageCreate(path, commitOrEffect)`
- `scope:stageDestroy(path, commitOrEffect)`
- `scope:stageTouch(path, commitOrEffect)`
- `scope:effects()`

## Async Actions

Actions that yield (DataStore writes, MessagingService, HTTP) declare `async`
so the contract guarantees survive the yield:

```lua
:action("GrantItem", {
	input = GrantItemSchema,
	writes = { "PlayerData/Inventory" },
	async = {
		timeoutSeconds = 10, -- default 10; false disables the deadline
		concurrency = "serialize", -- "serialize" | "reject" | "allow"
	},
})
```

Async actions run through an `AsyncGate` keyed by lifecycle session (falling
back to the actor, then the action name):

- `serialize` (default when the remote binds a lifecycle session) queues
  duplicate in-flight calls so commits never interleave.
- `reject` (default otherwise) fails duplicates immediately with a named
  `ActionBusy` diagnostic.
- `allow` opts out for genuinely commutative actions.

Timeouts cancel the call with an `ActionTimeout` diagnostic and a structured
failure; the abandoned handler keeps running but its staged effects are
discarded at the commit boundary with an `ActionCancelled` diagnostic. After a
handler resumes from a yield, the lifecycle session revision is re-checked
before effects apply, so a session that moved during the yield produces
`LifecycleStaleRevision` and a rollback instead of a double commit.

Handlers observe cancellation through the scope:

```lua
runtime:implement("GrantItem", function(scope)
	scope:onCancel(function(reason)
		print("cancelled:", reason)
	end)

	scope:stageWrite("PlayerData/Inventory", {
		commit = grantItem,
		rollback = revokeItem,
	})

	store:UpdateAsync(key, update) -- yields are safe here

	if scope:cancelled() then
		return nil -- staged effects are discarded either way
	end
	return { granted = true }
end)
```

Schedulers drive timeouts and queueing. The Roblox adapter resolves the `task`
library automatically; outside Roblox pass one explicitly:

```lua
local runtime = Contracts.runtime(Contract, {
	scheduler = Contracts.Test.manualScheduler(), -- deterministic, for tests
})

scheduler.advance(10) -- fire pending timeouts in tests
```

`Contracts.Test.remoteHarness` accepts the same `scheduler` option and adds
`implementYielding`, `callAsync`, `resume`, `pendingHandlerCount`, and
`advance` for deterministic async tests.

## Transactional Effect Plans

Immediate scope helpers such as `scope:write(...)` still run the given function
immediately after permission checks. Use staged effects when a mutation should
only commit after output validation, postconditions, and lifecycle transition
checks pass.

```lua
Contract
	:postcondition("PlansInventoryGrant", function(context)
		return context.effects:has({
			kind = "write",
			target = "Player.Inventory",
			itemId = context.result.itemId,
		})
	end)
	:action("GrantItem", {
		input = GrantItemSchema,
		output = GrantItemResultSchema,
		writes = { "Player.Inventory" },
		postconditions = { "PlansInventoryGrant" },
	})

runtime:implement("GrantItem", function(scope)
	local itemId = scope:payload().ItemId

	scope:stageWrite("Player.Inventory", {
		metadata = {
			itemId = itemId,
		},
		commit = function(context)
			context.inventory[itemId] = true
		end,
		rollback = function(context)
			context.inventory[itemId] = nil
		end,
	})

	return {
		granted = true,
		itemId = itemId,
	}
end)
```

`System:runAction` commits staged effects only after:

- input and context validation pass
- actor policy passes
- lifecycle requirements pass
- preconditions pass
- handler returns
- output validation passes
- postconditions pass
- lifecycle transitions can be reduced

If a staged effect commit fails, the SDK records `ActionCommitFailed`, rolls back
previously committed staged effects in reverse order, and returns the rollback
report. If rollback fails, the SDK records `ActionRollbackFailed`; if no rollback
hook exists, it records `ActionRollbackUnavailable`.

Effect reports are serializable and include:

- `kind`
- `target`
- `status`
- `metadata`
- `result`
- `error`

Common statuses are `planned`, `committed`, `rolledBack`, `failed`,
`rollbackFailed`, and `rollbackUnavailable`.

## Runtime

`Runtime` is the recommended execution boundary for application code. It keeps
contract declarations separate from implementation functions, resolves named
lifecycle sessions, runs actions through `System:runAction`, binds remotes
through `RemoteGuard`, and exposes a serializable runtime report.

```lua
local diagnostics = Contracts.diagnostics()
local runtime = Contracts.runtime(Contract, {
	diagnostics = diagnostics,
	sessions = {
		player = function(request)
			return playerSessions[request.actor.UserId]
		end,
	},
})

runtime:implement("WeaponAction", function(scope, _request)
	local payload = scope:payload()

	return scope:write("Player.Backpack", function()
		return {
			accepted = payload.Action == "Fire",
		}
	end)
end)

local result = runtime:invoke("WeaponAction", {
	actor = player,
	payload = {
		Action = "Fire",
		WeaponId = "Rifle",
	},
	context = {
		character = character,
		weaponCount = 1,
	},
	sessionName = "player",
	expectedRevision = playerSessions[player.UserId]:revision(),
})
```

Runtime action handlers receive `(scope, request)`. The `scope` is the normal
guarded action scope. The request is a normalized plain table with:

- `action`
- `actor`
- `payload`
- `context`
- `diagnostics`
- `session`
- `sessionName`
- `states`
- `expectedRevision`
- `remote`

Useful runtime methods:

- `Contracts.runtime(contract, options)`
- `Runtime.new(contract, options)`
- `runtime:implement(actionName, handler, options)`
- `runtime:invoke(actionName, request)`
- `runtime:session(name, sessionOrResolver)`
- `runtime:bindRemote(remoteName, remoteObject, options)`
- `runtime:bindRemotes(remoteMap, options)`
- `runtime:describe()`
- `runtime:destroy()`

`runtime:implement` rejects unknown actions and duplicate implementations unless
`options.overwrite = true` is passed. `runtime:invoke` fails loudly when an action
has no implementation because that is a setup error, not a player input error.

Named sessions can be provided as a session object or as a resolver function. A
resolver receives the normalized runtime request. For remotes, `request.actor` is
the player and `request.payload` is the remote payload.

Action-bound remotes can be bound without repeating the action handler:

```lua
runtime:bindRemote("WeaponAction", WeaponActionRemote)
```

For remotes declared without an action, pass an explicit handler:

```lua
runtime:bindRemote("Ping", PingRemote, {
	handler = function(player, payload)
		return {
			ok = true,
		}
	end,
})
```

`runtime:describe()` returns only serializable report data:

```lua
local report = runtime:describe()

print(report.system.name)
print(report.implementedActions[1])
print(report.boundRemotes[1])
print(report.destroyed)
```

## Generated Remote Wrappers

The host CLI can generate strict Luau modules from exact contract reports:

```sh
node tools/luau-contract.js generate remotes \
	--exact \
	--contract-module "src/**/*.contract.lua" \
	--out src/shared/ContractsGenerated
```

Each contract with remotes emits:

- `<SystemName>Types.luau`
- `<SystemName>Client.luau`
- `<SystemName>Server.luau`
- `<SystemName>Manifest.luau`

The generated modules start with `--!strict`. Schema descriptions become Luau
type aliases where Luau can express them. Runtime-only constraints such as
string patterns, integer ranges, actor policies, lifecycle revisions, and rate
limits remain enforced by `Runtime` and `RemoteGuard`.

Generated server modules use the existing runtime boundary and can install
handlers while binding:

```lua
local InventoryServer = require(ReplicatedStorage.ContractsGenerated.InventoryServiceServer)

InventoryServer.bind(runtime, {
	EquipItem = EquipItemRemote,
}, {
	EquipItem = function(scope)
		return equipItem(scope:actor(), scope:payload())
	end,
})
```

Generated server modules also support direct guarded binding when a project wants
safe remotes before adopting runtime-owned action handlers:

```lua
InventoryServer.guard(Contracts, InventoryContract, {
	EquipItem = EquipItemRemote,
}, {
	EquipItem = function(player, payload)
		return equipItem(player, payload)
	end,
})
```

Generated client modules expose typed remote call helpers:

```lua
local InventoryClient = require(ReplicatedStorage.ContractsGenerated.InventoryServiceClient)

InventoryClient.EquipItem(EquipItemRemote, {
	ItemId = "Rifle",
	Slot = 1,
})
```

Use `--check` to fail CI when generated files are missing or stale.

Use `verify remotes` to check wrappers, attack tests, generated manifests, and
the generated attack test run in one command:

```sh
node tools/luau-contract.js verify remotes \
	--contract-module "src/**/*.contract.lua" \
	--generated-remotes src/shared/ContractsGenerated \
	--generated-tests tests/generated
```

## Lifecycle Sessions

`Lifecycle` defines valid states and transitions. `LifecycleSession` owns the
current state for a system instance, tracks a revision, checks stale callers, and
commits action lifecycle transitions only after the action succeeds.

```lua
local MatchLifecycle = Contracts.lifecycle("Match")
	:transition("Lobby", "RoundStarted", "Running")
	:transition("Running", "RoundEnded", "Results")
	:transition("Results", "Reset", "Lobby")

local Match = Contracts.system("MatchService")
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

local session = Match:lifecycleSession({
	Match = "Lobby",
})

local result = Match:runAction("StartRound", {
	session = session,
	expectedRevision = session:revision(),
	diagnostics = diagnostics,
}, function()
	return true
end)
```

After a successful action, the session state becomes `Running` and the revision
increments. Failed handlers, invalid outputs, failed postconditions, invalid
states, and invalid emitted transitions do not mutate the session.

Useful lifecycle session methods:

- `session:state(lifecycleName)`
- `session:states()`
- `session:revision()`
- `session:snapshot()`
- `session:restore(snapshot)`
- `session:canRun(actionName, diagnostics, context, expectedRevision)`
- `session:apply(actionName, diagnostics, context, expectedRevision)`
- `session:describe()`

Sessions can also be created from the package root:

```lua
local session = Contracts.lifecycleSession(Match, {
	Match = "Lobby",
})
```

## Permission Capabilities

`mayRead`, `mayWrite`, and `mustNeverTouch` are enforceable capabilities.
Without strict mode, empty read/write lists allow access by default. With
`strictPermissions()`, empty read/write lists deny by default.

```lua
local Inventory = Contracts.system("InventoryService")
	:strictPermissions()
	:mayRead("Catalog.Items")
	:mayWrite("Player.Inventory")
	:mustNeverTouch("Workspace.Map")
	:action("GrantItem", {
		reads = { "Catalog.Items" },
		writes = { "Player.Inventory.Items" },
		creates = { "Player.Inventory.Items" },
	})

Inventory:checkRead("Catalog.Items.Rifle", diagnostics)
Inventory:checkWrite("Player.Inventory.Items.Rifle", diagnostics)
Inventory:checkEffect({
	kind = "write",
	target = "Player.Inventory.Items.Rifle",
}, diagnostics)

Inventory:checkActionRead("GrantItem", "Catalog.Items.Rifle", diagnostics)
Inventory:checkActionWrite("GrantItem", "Player.Inventory.Items.Rifle", diagnostics)
Inventory:checkActionEffect("GrantItem", {
	kind = "create",
	target = "Player.Inventory.Items.Rifle",
}, diagnostics)
```

Batch checks return all results and a failure list:

```lua
local result = Inventory:checkActionEffects("GrantItem", {
	{
		kind = "read",
		target = "Catalog.Items.Rifle",
	},
	{
		kind = "destroy",
		target = "Workspace.Map.Tile",
	},
}, diagnostics)
```

Permission results include:

- `ok`
- `name`
- `system`
- `action`
- `kind`
- `target`
- `reason`
- `strict`
- `systemBoundaries`
- `actionBoundaries`
- `matchedSystemBoundary`
- `matchedActionBoundary`
- `forbiddenBoundary`

Useful permission methods:

- `contract:strictPermissions(enabled)`
- `contract:checkRead(path, diagnostics, context)`
- `contract:checkWrite(path, diagnostics, context)`
- `contract:checkEffect(effect, diagnostics, context)`
- `contract:checkEffects(effects, diagnostics, context)`
- `contract:checkActionRead(actionName, path, diagnostics, context)`
- `contract:checkActionWrite(actionName, path, diagnostics, context)`
- `contract:checkActionEffect(actionName, effect, diagnostics, context)`
- `contract:checkActionEffects(actionName, effects, diagnostics, context)`

## Remote Contracts

Remote contracts can be declared in the contract-first table form:

```lua
Contract
	:actorPolicy("admin", function(player)
		return Admins[player.UserId] == true
	end)
	:remote("GrantItem", {
		input = Contracts.object({
			ItemId = Contracts.stringId(),
			Amount = Contracts.integer(1, 10),
			Revision = Contracts.integer(),
		}, {
			allowExtra = false,
		}),
		output = Contracts.object({
			granted = Contracts.boolean(),
			itemId = Contracts.stringId(),
		}, {
			allowExtra = false,
		}),
		actor = "admin",
		lifecycle = {
			session = "inventory",
			revision = "Revision",
		},
		rateLimit = {
			maxRequests = 4,
			windowSeconds = 1,
		},
	})
```

The older schema-plus-options form is still supported:

```lua
Contract:remote("WeaponAction", Contracts.object({
	Action = Contracts.oneOf({ "Fire", "Reload" }),
	WeaponId = Contracts.stringId(),
}))
```

When an action declares `remote = { name = "WeaponAction" }`, the system
automatically registers that remote with the action input schema and stores the
action binding in `remoteOptions`.

The compatibility form accepts the same policy metadata:

```lua
Contract
	:actorPolicy("admin", function(player)
		return Admins[player.UserId] == true
	end)
	:remote("GrantItem", GrantItemSchema, {
		action = "GrantItem",
		direction = "server",
		actor = "admin",
		response = GrantItemResultSchema,
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
```

Supported remote policy fields:

- `action`: action name to run through `System:runAction`.
- `direction`: `server`, `client`, or `bidirectional`.
- `actor`: `required`, a named actor policy, a policy table, or a function.
- `input`, `schema`, or `payload`: payload schema.
- `output`, `response`, or `result`: RemoteFunction response schema.
- `lifecycle.session`: named session resolver used by `RemoteGuard`.
- `lifecycle.revision`: payload field path or resolver for stale revision checks.
- `rateLimit.maxRequests`
- `rateLimit.windowSeconds`
- `rateLimit.key`: defaults to actor; also supports `global`, `remote`, and
  `payload.FieldName`.

Useful remote methods:

- `contract:remote(name, schema, options)`
- `contract:remoteOptions(name)`
- `contract:actionForRemote(name)`
- `contract:validateRemote(name, payload, diagnostics, context)`
- `contract:validateRemoteResponse(name, value, diagnostics, context)`
- `contract:checkRemoteActor(name, actor, context, diagnostics)`

## Low-Friction Remote Guard

Use `Contracts.guardRemote(remote, options, handler)` when an existing game is
not ready to introduce a full `System` plus `Runtime` setup. It creates a small
remote contract behind the scenes and delegates to the same `RemoteGuard`
validation path as runtime-bound remotes.

```lua
Contracts.guardRemote(GrantItemRemote, {
	name = "GrantItem",
	input = Contracts.object({
		ItemId = Contracts.stringId(),
		Amount = Contracts.integer(1, 10),
	}, {
		allowExtra = false,
	}),
	output = Contracts.object({
		granted = Contracts.boolean(),
		itemId = Contracts.stringId(),
	}, {
		allowExtra = false,
	}),
	actor = "admin",
	actorPolicies = {
		admin = function(player)
			return Admins[player.UserId] == true
		end,
	},
	rateLimit = {
		maxRequests = 5,
		windowSeconds = 1,
	},
	diagnostics = diagnostics,
}, function(player, payload)
	return grantItem(player, payload.ItemId, payload.Amount)
end)
```

Supported aliases:

- `input`, `schema`, or `payload`
- `output`, `response`, or `result`
- `name` or `remoteName`
- `kind` or `remoteKind`
- `actor` or `actorPolicy`
- `actorPolicies` or `policies`

When `output` or `kind = "function"` is present, the guard binds the remote as a
RemoteFunction-like value through `OnServerInvoke`. Otherwise it expects a
RemoteEvent-like value with `OnServerEvent:Connect`.

## Schemas

Supported schema builders:

- `Contracts.any()`
- `Contracts.boolean()`
- `Contracts.number({ min, max })`
- `Contracts.integer(min, max)`
- `Contracts.string({ minLength, maxLength, pattern, description })`
- `Contracts.stringId()`
- `Contracts.oneOf(values)`
- `Contracts.literal(value)`
- `Contracts.optional(schema)`
- `Contracts.arrayOf(schema)`
- `Contracts.object(shape, { allowExtra })`
- `Contracts.vector3({ unitish, minMagnitude, maxMagnitude })`
- `Contracts.custom(name, validator)`

All validators return `{ ok, reason, value, path }`.

`Contracts.Schema.describe(schema)` returns a serializable schema description.
Custom schemas report as `{ kind = "custom", name = "..." }` without exposing
their validator function.

## Stable System Reports

`contract:describe()` returns a plain serializable report for docs, tests, and
Studio tooling.

```lua
local report = Contract:describe()

print(report.formatVersion)
print(report.remotes.GrantItem.action)
print(report.remotes.GrantItem.response.kind)
print(report.actions.GrantItem.lifecycle.requires.Inventory)
```

The report contains:

- `formatVersion`
- `name`
- `ownership`
- `permissions`
- `actions`
- `remotes`
- `preconditions`
- `postconditions`
- `lifecycles`
- `actorPolicies`

Schemas, lifecycle definitions, remote policies, actor policy references, and
rate limits are described as plain tables. Runtime functions are represented by
metadata such as `{ kind = "function" }` rather than being embedded in the
report.

## Diagnostics

```lua
local diagnostics = Contracts.diagnostics({ capacity = 100 })

contract:validateRemote("DeployRequest", payload, diagnostics)
contract:checkPostconditions(context, diagnostics)

local latest = diagnostics:last()
local remoteFailures = diagnostics:find({
	category = "remote",
	system = "MatchService",
	limit = 5,
})
local report = diagnostics:report({ recentLimit = 8 })
```

Diagnostics are intentionally plain tables so overlays, logs, tests, and future
Studio plugins can consume the same shape.

Records include:

- `id`
- `time`
- `level`
- `category`
- `code`
- `system`
- `name`
- `message`
- `context`

Reports include counts by level, system, name, and category.

## Live Studio Diagnostics

One server-side line streams runtime diagnostics into the Studio plugin while
play-testing:

```lua
Contracts.publishDiagnostics(runtime:diagnostics(), {
	level = "warn", -- minimum level to stream (default "warn")
})
```

The publisher no-ops outside Studio (pass `force = true` to override), batches
entries on Heartbeat, redacts player objects in contexts down to
`{ userId, name }`, and writes versioned JSON batches as `StringValue`
instances under `ReplicatedStorage.__LuauContractDiagnostics`. The plugin's
Live Diagnostics panel picks them up automatically with pause and clear
controls.

The pure encoding/batching layer is `Contracts.Studio.DiagnosticsBridge` and
the Roblox writer is `Contracts.Roblox.StudioBridgePublisher`; both accept
`maxBatchEntries`, `flushIntervalSeconds`, `maxContextDepth`, and `clock`
overrides.

## Overlay Feed

```lua
local diagnostics = Contracts.diagnostics()
local overlay = Contracts.OverlayFeed.new(diagnostics, { maxRows = 8 })

diagnostics:record({
	level = "error",
	category = "postcondition",
	system = "CombatService",
	name = "OneWeaponToolAfterSpawn",
	message = "expected one weapon tool",
})

local rows = overlay:rows()
local text = overlay:text()
```

`OverlayFeed` is pure Luau. It does not create UI. It exposes rows and text that
a Roblox debug overlay, log sink, or future Studio plugin can render.

## Static Scanner

```lua
local report = Contracts.StaticScanner.scanSource(sourceText, {
	path = "src/server/Modules/CombatService.lua",
})

for _, finding in ipairs(report.findings) do
	print(Contracts.StaticScanner.formatFinding(finding))
end
```

Findings include:

- `ruleId`
- `severity`
- `category`
- `path`
- `line`
- `column`
- `message`
- `snippet`

Scanner rules:

- `raw-remote-handler`
- `raw-remote-fire`
- `broad-cleanup`
- `workspace-clear-all`
- `unowned-destroy`
- `async-without-token`

Use `-- contracts-scan: ignore <ruleId>` on a line to suppress an intentional
finding. The scanner is heuristic and operates on source text; host tooling is
responsible for reading files and passing contents into `scanSource`.

## Remote Attack Tests

The CLI can generate deterministic remote attack suites from exact contracts:

```sh
node tools/luau-contract.js generate tests \
	--exact \
	--contract-module "src/**/*.contract.lua" \
	--out tests/generated

luau tests/generated/run.luau
```

Generated suites use `Contracts.Test.remoteHarness(...)`, a pure Luau harness
that creates fake remotes, binds them through `Runtime:bindRemote`, tracks
handler calls, and exposes diagnostics.

```lua
local harness = Contracts.Test.remoteHarness(Contract, {
	defaultResponses = {
		GrantItem = {
			granted = true,
			itemId = "ValidId",
		},
	},
})

harness:implement("GrantItem")
harness:bind("GrantItem")
harness:call("GrantItem", player, {
	ItemId = 123,
})

print(harness:handlerCalls("GrantItem"))
print(harness:lastDiagnostic().name)
```

Generated cases cover payload shape violations for declared schemas, including
missing fields, wrong types, extra fields, pathological long strings, deep
tables, large arrays, and non-finite numbers. They also cover missing or
configured unauthorized actors, stale lifecycle revisions, rate-limit spam, and
bad handler return shapes when those policies are present.

For actions declared `async`, suites also generate in-flight duplicate calls
(asserting handlers never interleave and `reject` policies record
`ActionBusy`), handler timeouts (asserting `ActionTimeout` plus the
commit-blocking `ActionCancelled`), and stale-revision-after-yield cases for
remotes with lifecycle sessions (asserting `LifecycleStaleRevision`).

Use `--attack-config` to provide invalid actor fixtures for named actor policies:

```json
{
  "actors": {
    "admin": {
      "invalid": {
        "Name": "Guest",
        "UserId": 2,
        "IsAdmin": false
      }
    }
  }
}
```

## Studio Report

```lua
local report = Contracts.Studio.StudioReport.fromScripts({
	{
		path = "ReplicatedStorage.Contracts.Combat",
		className = "ModuleScript",
		source = sourceText,
	},
}, {
	diagnosticsReport = diagnostics:report(),
})
```

The report contains:

- `summary`
- `systems`
- `contracts`
- `diagnostics`
- `scanner.findings`
- `scanner.summary`

This is the pure model used by the Studio plugin source.

When live contract modules are already available, use:

```lua
local report = Contracts.Studio.StudioReport.fromContracts({
	Contract,
})
```

## Host Tools

`Contracts.Host` contains pure Luau modules used by the CLI/CI host adapter.
They do not read or write files.

```lua
local report = Contracts.Host.ScanRunner.run({
	scripts = {
		{
			path = "ServerScriptService.MatchService",
			className = "Script",
			source = sourceText,
		},
	},
	policy = {
		failOn = "error",
		baselineKeys = {},
	},
})

print(report.policy.ok)
print(Contracts.Host.JsonEncode.encode(report))
```

Host modules:

- `Host.ScanRunner`: builds a Studio report from script metadata, attaches static
  scanner rule metadata, includes exact contract reports supplied by the host,
  and evaluates policy.
- `Host.ReportPolicy`: evaluates fail thresholds, max warning counts, exact load
  errors, and baseline-suppressed findings.
- `Host.JsonEncode`: encodes serializable report tables for the generated Luau
  runner used by the CLI.

The executable host command is `tools/luau-contract.js`. It owns filesystem
project discovery, config loading, subprocess execution, report writing,
generated wrapper and attack-test file output, and CI exit codes.

## Roblox Adapters

Adapters are available from the package root:

```lua
local GuardRemote = Contracts.Roblox.GuardRemote
local RemoteGuard = Contracts.Roblox.RemoteGuard
local Ownership = Contracts.Roblox.Ownership
local PostconditionRunner = Contracts.Roblox.PostconditionRunner
local OverlayState = Contracts.Roblox.OverlayState
```

The core package remains Roblox-free. Adapters are the only layer that expects
RemoteEvent-like or Instance-like values.

`RemoteGuard.connect` detects action-bound remotes and routes them through
`System:runAction`. It connects RemoteEvent-like values with
`OnServerEvent:Connect`, and uses a RemoteFunction-style `OnServerInvoke`
handler when a response schema is declared. Handlers for action-bound remotes
receive `(player, payload, scope)`.

Action-bound remotes can use a shared lifecycle session:

```lua
RemoteGuard.connect(Match, "StartRoundRemote", remote, handler, {
	session = matchSession,
})
```

For per-player or per-match state, use `sessionFor`:

```lua
RemoteGuard.connect(Match, "DeployRemote", remote, handler, {
	sessionFor = function(player, payload)
		return sessions[player.UserId]
	end,
	revision = function(player, payload)
		return payload.Revision
	end,
})
```

If the remote declaration names `lifecycle.session`, provide a resolver in
`sessions`:

```lua
RemoteGuard.connect(Match, "DeployRemote", remoteFunction, handler, {
	sessions = {
		match = function(player, payload)
			return matchSessions[payload.MatchId]
		end,
	},
})
```
