# Luau Contract SDK — agent notes

High-signal conventions for working in this repo. See `docs/ENGINEERING.md` and
`docs/API.md` for the full picture.

## Effect API: transactional by default

On an action `scope`, the mutating helpers are **staged/transactional by default**:

- `scope:write|create|destroy|touch(path, valueOr{commit, rollback})` — runs at the
  commit boundary (after output, postcondition, and lifecycle checks) and rolls back
  if a later step fails. The operation is a plain value, a `function(context)` commit,
  or a `{ commit = fn, rollback = fn? }` table. **Use these.**
- `scope:writeEager|createEager|destroyEager|touchEager(path, valueOrWriter)` — the
  non-transactional escape hatch: runs immediately, cannot be rolled back. A failed
  action leaves these applied and records `ActionEagerEffectsNotRolledBack`. Use only
  when a write genuinely cannot be deferred.
- `scope:stageWrite|stageCreate|stageDestroy|stageTouch|stageEffect` are deprecated
  aliases of the matching `write`/`create`/… calls. Prefer the short names.

Do not "fix" `scope:write` to run eagerly — that reintroduces the partial-write
footgun this API exists to prevent. Note `scope:write(path, fn)` stages `fn` and
returns an effect report, so do not `return scope:write(...)` as the action output;
return the output explicitly.

## Concurrency: single-threaded except across yields

Roblox server scripts are single-threaded; execution only switches threads at a
yield. A run of non-yielding steps cannot be interleaved, so it is **not** a data
race — do not flag synchronous read-then-use, increment-then-read, or
build-then-iterate patterns as races. Real concurrency appears only across a yield
(async actions, yielding handlers), and those windows are handled by `AsyncGate`,
the post-yield revision re-check (`LifecycleStaleRevision`), and `cancelOnLeave`.
See `docs/ENGINEERING.md` § Concurrency and Threading Model.

## Release gate

`npm test` is the full gate (stylua format check, Luau tests, host tests, contract
scan, luau-analyze, selene). Run it before declaring work done, and add any new
check to the package scripts that feed `npm test` rather than as an ad hoc command.
