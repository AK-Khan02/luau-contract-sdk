# Integration

## Install Shape

The package root is `src/init.lua`. The public API is `src/Contracts.lua`.

Supported local validation:

```sh
luau tests/run.lua
node --test tools/tests/*.test.js
node tools/luau-contract.js scan --fail-on error
luau-analyze src/**/*.lua examples/**/*.lua tests/**/*.lua plugin/*.lua
```

## Rojo

`default.project.json` maps the package into:

```text
ReplicatedStorage.LuauContractSDK
```

Use that mapping for local Studio experiments or as a reference for embedding the
package into an existing Rojo game.

## Wally

`wally.toml` describes the package as:

```text
luau-contract-sdk/core@0.11.0
```

Publishing is intentionally not required for local use. The manifest is marked
`private = true` and uses a neutral local package id. Replace the package name
with the target Wally scope before publishing.

## Runtime Boundary

The core modules are pure Luau and can be tested outside Studio. Roblox adapters
expect Roblox-like values:

- `RemoteGuard` expects a server-directed `RemoteEvent` with
  `OnServerEvent:Connect` or a RemoteFunction-like value when a response schema
  is declared. Action-bound remotes run through `System:runAction`.
- `Runtime` owns application handlers, named lifecycle sessions, remote
  connections, diagnostics, and a stable runtime report.
- `Ownership` expects an Instance-like value with `SetAttribute`, `GetAttribute`,
  and optionally `Destroy`.
- `PostconditionRunner` wraps code that only needs post-action checks.
- `OverlayState` exposes rows and formatted text for a Roblox debug overlay
  without creating UI itself.

## Suggested Consumer Pattern

Keep contracts near the systems they describe:

```text
src/
  replicated/
    Contracts/
      Combat.contract.lua
      Inventory.contract.lua
      Spawn.contract.lua
```

Use the SDK core to define systems and actions. Create one runtime for each
system instance that owns handlers, diagnostics, sessions, and remote bindings.
Use Roblox adapters only at concrete boundaries such as object ownership and
overlay state.

Use lifecycle sessions for stateful flows such as rounds, deploys, matchmaking,
or per-player setup:

```lua
local session = Contract:lifecycleSession({
	Match = "Lobby",
})

local runtime = Contracts.runtime(Contract, {
	diagnostics = diagnostics,
	sessions = {
		match = session,
	},
})

runtime:implement("StartRound", function()
	return startRound()
end)

runtime:invoke("StartRound", {
	sessionName = "match",
	expectedRevision = session:revision(),
})
```

Runtime sessions can be shared objects or request-aware resolvers:

```lua
local runtime = Contracts.runtime(Contract, {
	sessions = {
		player = function(request)
			return playerSessions[request.actor.UserId]
		end,
	},
})
```

Remote declarations can name the session resolver directly, and runtime binding
will pass that name through to the remote guard:

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

local runtime = Contracts.runtime(Contract, {
	sessions = {
		inventory = function(request)
			return inventorySessions[request.actor.UserId]
		end,
	},
})

runtime:implement("GrantItem", function(scope)
	local payload = scope:payload()
	return grantItem(scope:actor(), payload.ItemId)
end)

runtime:bindRemote("GrantItem", remoteFunction)
```

Use `strictPermissions()` once a system has declared its intended read/write
surface. In strict mode, undeclared reads and writes fail:

```lua
local Contract = Contracts.system("InventoryService")
	:strictPermissions()
	:mayRead("Catalog.Items")
	:mayWrite("Player.Inventory")

Contract:checkRead("Catalog.Items.Rifle", diagnostics)
Contract:checkWrite("Player.Inventory.Items.Rifle", diagnostics)
```

Action-specific permission checks narrow the system-level capability:

```lua
Contract:checkActionEffect("GrantItem", {
	kind = "write",
	target = "Player.Inventory.Items.Rifle",
}, diagnostics)
```

Use staged effects for mutations that should not happen until output validation,
postconditions, and lifecycle transition checks have passed:

```lua
runtime:implement("GrantItem", function(scope)
	local itemId = scope:payload().ItemId

	scope:stageWrite("Player.Inventory", function(context)
		context.inventory[itemId] = true
	end)

	return {
		granted = true,
		itemId = itemId,
	}
end)
```

## Diagnostics Hook

Use one diagnostics instance per game session, server, or subsystem depending on
how noisy the game is:

```lua
local diagnostics = Contracts.diagnostics({ capacity = 200 })
local overlayState = Contracts.Roblox.OverlayState.bind(diagnostics, {
	maxRows = 8,
})
```

Server code can record and query violations, while a debug overlay can render
`overlayState.rows()` or `overlayState.text()`.

## Static Checks

The static scanner is available at `Contracts.StaticScanner`.

It scans source text and returns structured findings:

```lua
local report = Contracts.StaticScanner.scanSource(sourceText, {
	path = "src/server/Modules/MapService.lua",
})
```

The scanner does not read files itself. Standalone Luau runtimes can differ on
whether file IO is available, so CI or host tooling should read source files and
pass text into `scanSource`.

## CLI / CI Host

Use the bundled host command when a project needs filesystem discovery, report
files, CI annotations, or policy exit codes:

```sh
node tools/luau-contract.js scan
```

The host command performs project discovery in Node, then generates a temporary
Luau runner that calls `Contracts.Host.ScanRunner`. The temporary runner is
deleted after the scan. Add `.luau-contract-runner-*.lua` to ignore rules in
consumer repositories if you vendor the tool.

Supported outputs:

```sh
node tools/luau-contract.js scan --format text
node tools/luau-contract.js scan --format json --out reports/contracts.json
node tools/luau-contract.js scan --format sarif --out reports/contracts.sarif
node tools/luau-contract.js scan --format markdown --out docs/contracts.md
```

Multiple formats can be written together with `--out-dir`:

```sh
node tools/luau-contract.js scan \
	--format text,json,sarif,markdown \
	--out-dir reports/contracts
```

CI policy options:

```sh
node tools/luau-contract.js scan --fail-on error
node tools/luau-contract.js scan --fail-on warn --max-warnings 0
node tools/luau-contract.js scan --baseline reports/contracts-baseline.json
node tools/luau-contract.js scan --update-baseline reports/contracts-baseline.json
```

Exit codes:

- `0`: scan completed and policy passed.
- `1`: scan completed and policy failed.
- `2`: configuration, filesystem, subprocess, or internal tool error.

Exact contract mode is opt-in:

```sh
node tools/luau-contract.js scan \
	--exact \
	--contract-module "src/contracts/**/*.contract.lua" \
	--format markdown \
	--out docs/contracts.md
```

Static mode scans source text only and is safe for arbitrary gameplay files.
Exact mode requires configured contract modules and calls `contract:describe()`,
so use it for pure contract declaration files rather than scripts with setup
side effects.

A project can store defaults in `luau-contracts.json`:

```json
{
  "include": ["src/**/*.lua", "src/**/*.luau"],
  "exclude": ["Packages/**", "DevPackages/**"],
  "failOn": "error",
  "contractModules": ["src/contracts/**/*.contract.lua"],
  "report": {
    "formats": ["text", "sarif"],
    "outDir": "reports/contracts"
  }
}
```

GitHub Actions example:

```yaml
name: Contracts

on:
  pull_request:

jobs:
  scan:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: 22
      - name: Install Luau
        run: echo "Install luau with your project's toolchain"
      - name: Run contract scan
        run: node tools/luau-contract.js scan --format sarif --out reports/contracts.sarif --fail-on error
      - name: Upload SARIF
        uses: github/codeql-action/upload-sarif@v3
        if: always()
        with:
          sarif_file: reports/contracts.sarif
```

## Studio Plugin Source

The plugin source lives at:

```text
plugin/LuauContractStudioPlugin.lua
plugin/LuauContractPluginModel.lua
```

It expects the SDK ModuleScript tree next to the plugin script as either:

```text
LuauContractSDK
```

or:

```text
src
```

The plugin scans `Script`, `LocalScript`, and `ModuleScript` sources in the open
place, extracts `Contracts.system(...)` declarations, runs static checks, and
renders the result in a Studio dock widget.

The plugin source is not marketplace packaging. It is a source/template for a
local plugin or a future packaged Studio plugin.
