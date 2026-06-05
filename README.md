# Luau Contract SDK

A Luau contract SDK for rblx game systems.

The SDK is intentionally generic. The core package does not know about weapons,
maps, pets, obbies, tycoons, or any other genre.

## What It Includes

- System contract definitions: `ownsTag`, `ownsFolder`, `mayRead`, `mayWrite`,
  `mustNeverTouch`, `strictPermissions`, `precondition`, `postcondition`,
  `lifecycle`, and `action`.
- Action contracts with input/output schemas, scoped effects, preconditions,
  postconditions, actor policies, lifecycle guards, and action-bound remotes.
- Enforced permission capabilities for system-level and action-level reads,
  writes, creates, destroys, and touches.
- Pure payload schemas for remote validation.
- Lifecycle reducers for explicit state transitions.
- Stable invariant and postcondition failure names.
- Diagnostics ring buffer for recent contract violations.
- Searchable diagnostic records with IDs, categories, codes, systems, names, and
  context.
- Diagnostic reports with counts by level, system, category, and invariant name.
- Subscriber hooks and overlay feed rows for debug overlays and future Studio
  tooling.
- Static scanner for risky Roblox source patterns: raw remote handlers, raw
  remote firing, broad cleanup, workspace clearing, unowned destroys, and async
  callbacks without stale-token checks.
- Studio report model for contract systems, diagnostics, and scanner findings.
- Roblox Studio plugin source with a dock widget for systems and static findings.
- A small rate limiter used by guarded remotes.
- Minimal Roblox adapters for action-bound remote guarding, ownership
  attributes, and postcondition-running around legacy server actions.
- Roblox overlay state adapter for feeding debug UI.
- Generic checkpoint, inventory, and spawn/loadout example contracts.
- Root package entry at `src/init.lua`.
- Package metadata in `src/Package.lua`, `wally.toml`, and `default.project.json`.
- API and integration docs under `docs/`.

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
    DiagnosticReport.lua
    Diagnostics.lua
    Invariant.lua
    Lifecycle.lua
    OverlayFeed.lua
    RateLimiter.lua
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

## Basic Usage

```lua
local Contracts = require(Contracts)
-- Filesystem tests/examples can use:
-- local Contracts = require("../src")

local PlayerLifecycle = Contracts.lifecycle("Player")
	:transition("Menu", "Deploy", "DeployRequested")
	:transition("DeployRequested", "SpawnStarted", "Spawning")
	:transition("Spawning", "Spawned", "Alive")
	:transition("Alive", "WeaponAction", "Alive")

local CombatContract = Contracts.system("CombatService")
	:ownsTag("GeneratedWeaponTool")
	:mayRead("Player.Character")
	:mayWrite("Player.Backpack")
	:mustNeverTouch("Workspace.CurrentArena")
	:strictPermissions()
	:lifecycle("Player", PlayerLifecycle)
	:precondition("CharacterLoaded", function(context)
		return context.character ~= nil
	end)
	:postcondition("PlayerHasOneWeapon", function(context)
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
		postconditions = { "PlayerHasOneWeapon" },
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
		},
		policy = {
			actorRequired = true,
		},
	})
```

Actions run through one guarded path:

```lua
local result = CombatContract:runAction("WeaponAction", {
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
}, function(scope)
	local payload = scope:payload()

	return scope:write("Player.Backpack", function()
		return {
			accepted = payload.Action == "Fire" or payload.Action == "Reload",
		}
	end)
end)
```

Permissions can also be checked directly:

```lua
CombatContract:checkRead("Player.Character", diagnostics)
CombatContract:checkWrite("Player.Backpack.Rifle", diagnostics)
CombatContract:checkActionEffect("WeaponAction", {
	kind = "write",
	target = "Player.Backpack.Rifle",
}, diagnostics)
```

Roblox adapters are available from the same package:

```lua
local RemoteGuard = Contracts.Roblox.RemoteGuard
local Ownership = Contracts.Roblox.Ownership
local PostconditionRunner = Contracts.Roblox.PostconditionRunner
local OverlayState = Contracts.Roblox.OverlayState
```

Diagnostics can also feed overlays without a UI dependency:

```lua
local diagnostics = Contracts.diagnostics({ capacity = 100 })
local overlay = Contracts.OverlayFeed.new(diagnostics, { maxRows = 8 })

diagnostics:record({
	level = "error",
	category = "postcondition",
	system = "CombatService",
	name = "OneWeaponToolAfterSpawn",
	message = "expected exactly one generated weapon tool",
})

print(overlay:text())
```

Static checks operate on source text:

```lua
local report = Contracts.StaticScanner.scanSource(sourceText, {
	path = "src/server/Modules/CombatService.lua",
})

print(Contracts.StaticScanner.formatReport(report))
```

The scanner is heuristic. It is meant for CI and review pressure, not as a
full Luau parser.

Studio reports combine contract extraction, scanner findings, and optional
diagnostics:

```lua
local report = Contracts.Studio.StudioReport.fromScripts(scriptSources, {
	diagnosticsReport = diagnostics:report(),
})
```

The plugin source in `plugin/LuauContractStudioPlugin.lua` renders that report
inside a dock widget in Roblox Studio.

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

## Honest Boundary

The SDK enforces contracts where game code uses it. It can run guarded actions,
validate guarded remotes, enforce scoped effects and permission capabilities, run
preconditions and postconditions, record named failures, rate-limit guarded
remote handlers, mark/check owned Roblox Instances through adapters, and expose
stable diagnostic data to overlays, reports, or the Studio plugin source.

It cannot prevent every raw `Destroy()`, every unguarded `OnServerEvent`, or every
broad cleanup written outside the SDK. The static scanner can flag likely risks in
source, but game teams still need to route risky code through SDK guards.

## License

MIT. See `LICENSE`.
