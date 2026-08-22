# Upgrade plan: honest Sendable for Models (remove @unchecked)

## Goal

Today every `Model` conformer stores its table value directly and must declare `@unchecked Sendable`,
which turns off the compiler's data-race checking for the whole class. The goal is to move the model's
only mutable state into a synchronized box (`ModelStorage`), so conformers have no mutable stored
properties and can conform to plain `Sendable` — the compiler then verifies everything else.

Model classes stay `Sendable` (the manager's identity cache and changed-object buckets hold references
across the actor boundary, so they have to be), but the conformance becomes *checked* instead of promised.

## Step 1 — opt-in (current release) ✅

Non-breaking. Nothing is deprecated, existing conformers compile and behave exactly as before.

- `ModelStorage<T: Table>`: a Sendable lock-protected box holding the table value. Caches `id`
  (immutable after init) so `Identifiable`/`Hashable` never take the lock. The lock is picked at init,
  best first: `Synchronization.Mutex` when the runtime has it (macOS 15 / iOS 18+, and Linux/Android
  with a Swift 6 toolchain), `os_unfair_lock` on Apple OSes below that floor, `pthread_mutex` on
  Linux/Android without the Synchronization module, `NSLock` as last resort (Windows/WASI).
  Once the platform floor reaches macOS 15 / iOS 18 the fallbacks (and their `@unchecked` boxes)
  can simply be deleted — the public API doesn't change.
- `StoredModel: Model`: opt-in refinement requiring `var storage: ModelStorage<TableType> { get }`.
  Its extension provides `value` (witnessing the `Model` requirement) with automatic change-tracking —
  no `didSet { didSet(oldValue) }` boilerplate — plus an atomic `withValue`.
- `Model.withValue(_:)`: new protocol requirement with a default implementation that bridges via
  `value` (get-modify-set, same guarantees as mutating `value` directly). Being a requirement means
  generic code dispatches to the atomic `StoredModel` version when available. Call sites can migrate
  to `withValue` now and won't need touching again.

Opt-in conformance looks like this — note: no `@unchecked`:

```swift
final class Person: StoredModel {
    struct Value: Table {
        var id: AutoId = 0
        var name: String = ""
    }
    let storage: ModelStorage<Value>
    init(_ value: Value) {
        self.storage = ModelStorage(value)
    }
}
```

**Rollout gate: do not start step 2 until users have adopted this release and all their test suites
pass unchanged.** The old `value`-based path must keep working untouched during this period.

## Step 2 — make storage the requirement (next major version)

Only after the step-1 gate passes.

- Swap the `Model` requirement: `var value: TableType { get set }` out, `var storage: ModelStorage<TableType> { get }` in.
  `value` moves to a protocol-extension computed property, so **call sites do not break** — only conformance
  declarations do.
- `StoredModel` becomes a deprecated typealias for `Model`.
- Remove (or deprecate as a no-op) the `didSet(_ oldValue:)` helper — change-tracking is automatic.
- Migration per model class is three mechanical edits:
  1. `var value: Value { didSet { didSet(oldValue) } }` → `let storage: ModelStorage<Value>`
     (and `self.value = value` → `self.storage = ModelStorage(value)` in init)
  2. delete `, @unchecked Sendable`
  3. fix what the compiler now flags — any remaining mutable or non-Sendable stored properties.
     This forced audit is the point of the exercise: those properties were unchecked data races before.
- Document the before/after in the release notes (regex-able rename).
- Do **not** document a `lazy var storage` bridge for classes that can't migrate — it would silently
  reintroduce unsynchronized state. If it conforms to Model vNext, it is genuinely Sendable.

## Later / optional

- `@AutoModel` macro that expands the storage property and init, shrinking conformance boilerplate to zero.
- Delete the `os_unfair_lock`/`pthread_mutex`/`NSLock` fallback boxes in ModelStorage.swift when the
  platform floor reaches macOS 15 / iOS 18 — removes the last library-internal `@unchecked Sendable`
  in this design.

## Known caveats (both steps)

- `model.value.name = "x"` compiles and change-tracks, but is a get-modify-set (two lock acquisitions
  with a gap). That is not a regression — it has the same race window as the current design — but
  `withValue { $0.name = "x" }` is the recommended idiom when competing writers are possible; push it in docs.
- `ModelStorage.mutate` detects change via `Equatable` on the Table, same cost profile as the existing
  `didSet(oldValue)` comparison.

---

# Upgrade plan: ambient transaction token (remove explicit token threading)

## Goal

~104 functions thread a `token: AutoId?` parameter so the `Semaphore` can recognize re-entrant access
inside transactions/migrations. Replace the *need* for that with a `@TaskLocal` (`SemaphoreToken.current`):
bound by `Database.transaction` for the duration of the closure, it flows through async calls, actor hops
and `Task {}` — and deliberately not into `Task.detached` (detached work waits for the transaction, as before).

## Step 1 — ambient fallback (current release) ✅

Non-breaking. Explicit `token:` parameters stay and always win; the task-local is only the fallback when nil.

- `SemaphoreToken` (`Utilities/SemaphoreToken.swift`): the task-local + `detached { }` helper that binds nil.
- `Database.transaction` resolves `token ?? SemaphoreToken.current ?? generateId()` and binds it with
  `withValue` around the savepoint + action. Nested nil-token transactions reuse the outer token
  (this also fixed the latent deadlock where a migration triggered inside a transaction started a nested
  transaction without forwarding the token).
- Fallback resolution at the gate points only (`Database.query/execute`, `Model.create`, `Table.saveList`,
  `ManyRelation`), resolved once into a local so the deferred `Task { signal(token:) }` releases are
  unaffected by the withValue scope having exited. `Database.close` deliberately has NO fallback —
  a nil-token close inside a transaction must keep waiting for it, not join it and close mid-transaction.
- Delayed/stored/fire-and-forget Tasks (debounce saves, deleteLater, RelationQuery listener + setOwner +
  items getter, ManyRelation.setOwner, FTSColumn.init, sync deletes, sqlite update-hook) scrub any inherited
  token, preserving the old semantics: their queries wait for open transactions instead of joining them.
- Fixed an operator-precedence bug in `Semaphore.wait` (`?? 0 + 1` → `(... ?? 0) + 1`), previously benign.
- Tests: `TaskLocalTokenTests` (nil-token calls inside transactions, nested transactions, migration without
  token, explicit-token precedence, debounce scrubbing, detached non-inheritance).

**Rollout gate: do not start step 2 until downstream users are on this release and their test suites pass
unchanged.** Release-note the one behavior change that cannot be scrubbed library-side: an app's own
`Task {}` spawned inside a transaction closure now inherits the token (previously its nil-token queries
blocked until commit). Apps can restore the old behavior with `SemaphoreToken.detached { }`.

## Step 2 — deprecate the token parameters (next major)

Only after the step-1 gate passes.

- Deprecate every `token:` parameter (Model, Table, TableModel, AutoDBManager, Database) — the task-local
  becomes the only mechanism; internals read `SemaphoreToken.current` at the gates.
- Drop the `token` parameter from the `transaction` closure signature and from the
  `Table.migration(_:_:_:)` protocol requirement (source-breaking for implementors — release notes + fix-it).
- Remove the deprecated parameters entirely in the major after that.
