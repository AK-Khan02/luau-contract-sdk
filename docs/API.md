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
validate input, validate output, enforce scoped effects, check actor policy, run
preconditions and postconditions, and apply lifecycle transitions.

```lua
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
	states = {
		Player = "Alive",
	},
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
- `contract:validateActionInput(name, payload, diagnostics, context)`
- `contract:validateActionOutput(name, value, diagnostics, context)`
- `contract:validateActionContext(name, context, diagnostics)`
- `contract:checkRead(actionName, path, diagnostics, context)`
- `contract:checkWrite(actionName, path, diagnostics, context)`
- `contract:checkEffect(actionName, effect, diagnostics, context)`
- `contract:runAction(name, options, handler)`

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
- `scope:effects()`

## Remote Contracts

Legacy remote validation can still be declared directly:

```lua
Contract:remote("WeaponAction", Contracts.object({
	Action = Contracts.oneOf({ "Fire", "Reload" }),
	WeaponId = Contracts.stringId(),
}))
```

When an action declares `remote = { name = "WeaponAction" }`, the system
automatically registers that remote with the action input schema and stores the
action binding in `remoteOptions`.

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
- `diagnostics`
- `scanner.findings`
- `scanner.summary`

This is the pure model used by the Studio plugin source.

## Roblox Adapters

Adapters are available from the package root:

```lua
local RemoteGuard = Contracts.Roblox.RemoteGuard
local Ownership = Contracts.Roblox.Ownership
local PostconditionRunner = Contracts.Roblox.PostconditionRunner
local OverlayState = Contracts.Roblox.OverlayState
```

The core package remains Roblox-free. Adapters are the only layer that expects
RemoteEvent-like or Instance-like values.

`RemoteGuard.connect` detects action-bound remotes and routes them through
`System:runAction`. Handlers for action-bound remotes receive
`(player, payload, scope)`.
