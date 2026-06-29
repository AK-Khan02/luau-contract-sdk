# Public API Classification

The package entrypoint is `src/init.lua`, which returns `src/Contracts.lua`.
Existing top-level exports remain available for compatibility. New consumers
should prefer `Contracts.Public` for stable APIs and treat
`Contracts.Experimental` and `Contracts.Internal` as narrower contracts. The
classification tables and `Contracts.publicApi` metadata are read-only at
runtime.

The classification is also available at runtime:

```lua
print(Contracts.publicApi.version)
print(Contracts.publicApi.status.stable)
```

## Stable

Stable APIs are intended for normal game, test, and tooling code. They may gain
optional fields or methods, but existing names and call shapes should remain
compatible within the major version.

Stable convenience constructors and helpers:

- `Contracts.diagnostics(config)`
- `Contracts.lifecycle(name)`
- `Contracts.lifecycleSession(systemContract, initialStates, options)`
- `Contracts.runtime(systemContract, options)`
- `Contracts.system(name)`
- `Contracts.guardRemote(remote, options, handler)`
- `Contracts.cancelOnLeave(runtime, playersService)`
- `Contracts.publishDiagnostics(diagnostics, options)`
- `Contracts.publishRelay(diagnostics, options)`

Stable schema builders:

- `Contracts.any()`
- `Contracts.arrayOf(schema, options)`
- `Contracts.boolean()`
- `Contracts.custom(name, validator)`
- `Contracts.integer(min, max)`
- `Contracts.literal(value)`
- `Contracts.number(options)`
- `Contracts.object(shape, options)`
- `Contracts.oneOf(values)`
- `Contracts.optional(schema)`
- `Contracts.string(options)`
- `Contracts.stringId()`
- `Contracts.vector3(options)`
- `Contracts.validate(schema, value, context)`

Stable classification entrypoints:

- `Contracts.Public`
- `Contracts.Experimental`
- `Contracts.Internal`
- `Contracts.publicApi`

Stable module entrypoints:

- `Contracts.Schema`
- `Contracts.Diagnostics`
- `Contracts.DiagnosticReport`
- `Contracts.Lifecycle`
- `Contracts.LifecycleSession`
- `Contracts.Runtime`
- `Contracts.System`
- `Contracts.version`

For module entrypoints, the module identity and documented constructors/helpers
are stable. Private fields and undocumented helper methods remain outside the
compatibility contract.

The stable constructors, helpers, and stable module entrypoints are grouped
under `Contracts.Public`. For example, `Contracts.Public.system ==
Contracts.system` and `Contracts.Public.Schema == Contracts.Schema`.

## Experimental

Experimental APIs are available for early integration, generated tooling, Studio
workflows, and advanced adapters. They are not hidden and are not scheduled for
removal, but their detailed table shapes and helper methods may change with
release notes before they are promoted to stable.

- `Contracts.EffectPlan`
- `Contracts.Host`
- `Contracts.OverlayFeed`
- `Contracts.Roblox`
- `Contracts.StaticScanner`
- `Contracts.Studio`
- `Contracts.Test`
- `Contracts.DurableEffect`
- `Contracts.DurableProfile`
- `Contracts.DurableTransaction`
- `Contracts.Reconcile`

Experimental convenience constructors:

- `Contracts.loadProfile(store, key, options)` (alias of `DurableProfile.load`)
- `Contracts.durableTransaction(store)` (alias of `DurableTransaction.new`) — a
  load coordinator for multi-profile transactions (trades); writes go through
  `scope:writeDurable`, so the saga (ordered commit, reverse compensation) comes
  from the effect plan. It is all-or-nothing under a normal commit failure, but a
  trade spans two DataStore keys with no two-phase commit: a failed *compensation*
  can leave it non-atomic. See
  [API: Partial failure](API.md#partial-failure-no-two-phase-commit).

The durable persistence modules take an injected `DurableStore` (load / save /
release / owns) as their seam. `Contracts.Roblox.ProfileSessionStore.new(profileStore)`
is the recommended adapter — it delegates to your existing ProfileService/ProfileStore
session — and `Contracts.Roblox.DurableDataStore.new(dataStore)` is the
zero-dependency adapter over a raw DataStore; tests supply an in-memory fake. `Contracts.Reconcile` is the pure schema-reconciliation
layer (`fill(data, template)` deep-fills defaults; `migrate(data, migrations)` runs
ordered schema migrations); it activates through the `template` / `migrations`
options on `Contracts.loadProfile`. See
[API: Durable Persistence](API.md#durable-persistence) and
[API: Reconcile and Migration](API.md#reconcile-and-migration).

The same entries are grouped under `Contracts.Experimental`.

## Internal

Internal exports remain present because existing users may already require them
from the package root. They are implementation modules, not a supported
extension surface. New code should avoid depending on their constructors,
methods, or table shape unless it is contributing to the SDK itself.

- `Contracts.AsyncGate`
- `Contracts.Invariant`
- `Contracts.Package`
- `Contracts.RateLimiter`

The same entries are grouped under `Contracts.Internal`.

## Compatibility Rules

- No existing top-level export is removed by this classification.
- Top-level names are compatibility aliases. Stable names are also exposed from
  `Contracts.Public`; experimental and internal names are grouped separately.
- `Contracts.Public`, `Contracts.Experimental`, `Contracts.Internal`, and
  `Contracts.publicApi` are stable metadata entrypoints and are not duplicated
  inside `Contracts.Public`.
- Promotion from experimental to stable should add the name to
  `Contracts.Public` and `Contracts.publicApi.stable` while keeping the legacy
  top-level alias.
- Demotion or removal of a stable API requires a major-version migration path.
