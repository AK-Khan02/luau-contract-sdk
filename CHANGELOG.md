# Changelog

## 0.5.0

- Added Studio report model.
- Added Roblox Studio plugin source with toolbar button and dock widget.
- Added strict Luau types to core modules.
- Split tests into focused suites behind a small runner.
- Added registered scanner rule pipeline.
- Added testable Studio plugin model helpers.
- Added system extraction from contract source files.
- Added Studio report tests for systems, diagnostics, and scanner findings.
- Updated API/integration docs.

## 0.4.0

- Added static scanner for risky Roblox source patterns.
- Added scanner rules for raw remotes, broad cleanup, workspace clearing,
  unowned destroys, and async callbacks without stale-token guards.
- Added structured scanner findings and report formatting.
- Added scanner fixtures and tests.
- Updated API/integration docs.

## 0.3.0

- Added diagnostic record model with ids, categories, codes, and context.
- Added diagnostic search and report summaries.
- Added diagnostic subscriber hooks.
- Added pure overlay feed rows/text for debug overlays.
- Added Roblox overlay state adapter.
- Updated API/integration docs.

## 0.2.0

- Added package metadata and root package entry.
- Exported Roblox adapters through `Contracts.Roblox`.
- Added Wally and Rojo package descriptors.
- Added generic checkpoint and inventory example contracts.
- Added API and integration docs.

## 0.1.0

- Added core contract engine.
- Added schema validation, lifecycle reducers, diagnostics, invariants, and rate
  limiting.
- Added Roblox adapters for guarded remotes, ownership, and postcondition
  running.
- Added spawn/loadout reference contract.
