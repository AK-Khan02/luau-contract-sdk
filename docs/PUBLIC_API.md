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
