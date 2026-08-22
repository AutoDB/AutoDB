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
