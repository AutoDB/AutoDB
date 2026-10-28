# AutoDB

Automatic persistence and database handling in Swift, built on SQLite. AutoDB focuses on automatic migrations, cache-backed model identity, relations, and async/await-friendly access patterns.

## Quick start

Model persisted columns in a `Table` and wrap them in a `Model` when you want identity, caching, relations, and change coalescing.

```swift
import AutoDB

final class Artist: Model {
	struct Value: Table {
		static let tableName = "Artist"

		var id: AutoId = 0
		var name = ""
		var genre = ""
	}

	let storage: ModelStorage<Value>

	init(_ value: Value) {
		self.storage = ModelStorage(value)
	}
}
```

Tell AutoDB where your tables live, once per module that declares tables:

```swift
extension Table {
	static var autoDBSettings: AutoDBSettings { .regular }
}
```

See [Database settings](Documentation/Documentation.md#database-settings) for other files, the cache and in-memory databases.

Create, save, and fetch:

```swift
let artist = await Artist.create()
artist.value.name = "The Cure"
artist.value.genre = "Post-punk"
try await artist.save()

let fetched = try await Artist.fetchId(artist.id)
```

While the object stays retained, `fetched === artist`.

## Canonical usage patterns

### Simple persistence

- use `Table` directly when you only want value storage
- use `Model` when multiple parts of the app should share one live object identity
- use `save()` when you want deterministic persistence now
- change a `Model` freely and call `saveChanges()` when you want batched writes - every change is tracked by its `ModelStorage`
- use `withValue { }` when several tasks may write the same object at once

### Relations

- use `OneRelation` for parent-style references
- use `ManyRelation` for ordered one-to-many lists
- use `RelationQuery` for query-backed incremental lists on Observation-capable OS versions

### Full-text search

`FTSColumn` provides ranked FTS5-backed search. Put the column on the model, optionally supply `FTSCallbackOwner`, and query through `search(_:)`.

### Debugging

A `Model` keeps its value behind a lock, so the variables view shows it several levels down (`storage → storage → box → value`). Quick Look (or Print Description) on the `storage` row shows the whole value, or print it from the console:

```
(lldb) po self.storage
```

`po self.storage` reads without taking the lock, so it works even when a breakpoint is inside `withValue`. `p self.value` also works, but takes the lock.

## Guarantees and limits

### Migrations

- AutoDB automatically handles additive/removal schema changes and supported compatible type conversions
- AutoDB does not infer renames
- if you rename a property, use the migration callback to move data explicitly

### Cache and model identity

- fetched models of the same concrete type and `id` resolve to one shared live instance while retained
- caches are weak; once nothing retains a model, it may be recreated on the next fetch
- `truncateTable()` is a test/helper path, not an app-level lifecycle primitive

### Save and change tracking

- `save()` persists the object immediately
- `saveChanges()` and `saveAllChanges()` flush the pending dirty-model buckets
- dirty models are retained until they are flushed, so batched saves trade memory for fewer writes

### `RelationQuery`

- `RelationQuery` is part of the 1.0 contract only on Observation-capable OS versions
- paging is deterministic: inserts and deletes refresh the visible window, and page overlap rebuilds from offset `0`
- 1.0 does not include a separate fallback implementation for older OS versions

### FTS

- FTS requires SQLite FTS5 support
- updates and deletes invalidate indexed rows through triggers; missing index rows are repopulated on search
- if you provide `FTSCallbackOwner`, return deterministic text per `id`

## Non-goals for 1.0

- Linux, Android, Windows, or WASI support
- deployment targets below the current package floor
- a non-Observation `RelationQuery`
- built-in sync products or cascading sync behavior

## Documentation

- [Documentation overview](Documentation/Documentation.md)
- [Adoption guide](Documentation/Adoption.md)
- [1.0 changelog](CHANGELOG.md)
- [Post-1.0 backlog](Documentation/Backlog.md)
- [Cross-platform notes](Documentation/Android.md), Android and Linux are coming in 1.1 through the `SQLCipher` trait
- [Encryption](Documentation/Documentation.md#encryption), coming in 1.1 through the same trait

## Contributing

Feel free to contribute, to make it easier to follow style you can install the pre-commit hook to format staged Swift files with swift-format. Enable it once per clone:

```bash
git config core.hooksPath .githooks
```

## License

AutoDB is currently distributed under the MIT license. See [LICENSE](LICENSE).

## History

AutoDB was originally written for Objective-C around 2015 and later reworked in Swift around the same goals: automatic persistence, safe model identity, and migrations that do not become day-to-day project work.

## Credits

Thanks to Marco Arment and [Blackbird](https://github.com/marcoarment/Blackbird), whose work helped bootstrap parts of the current implementation.
