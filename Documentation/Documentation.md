# AutoDB Swift

The purpose is to have an automatic system for handling persistence. Objects should be able to save and restore themselves and common headaches should be removed, especially migration, uniqueness, and relation handling.

## Release scope

AutoDB 1.0 is an Apple-first Swift Package release.

- Package platforms: macOS 14+, iOS 17+, tvOS 13+
- `RelationQuery` availability: macOS 14+, iOS 17+, tvOS 17+, watchOS 10+
- Cross-platform support outside Apple platforms is not part of the 1.0 contract

For first integration steps, start with the [README](../README.md) and the [Adoption Guide](Adoption.md).

## Availability

Current package support is macOS 14+, iOS 17+, and tvOS 13+.

- The core table/model APIs, migrations, caching, and FTS are part of the stable package surface.
- `RelationQuery` currently relies on Observation, so it is only available on macOS 14+, iOS 17+, tvOS 17+, and watchOS 10+.
- Cross-platform work outside Apple platforms is still exploratory rather than release-ready.

## Quick start

See the [README](../README.md).

# Overview

The system is built on top of SQLite and uses Codable to read and write data to objects.

All classes need to implement the AutoDB protocol. This in turn implements Codable, Hashable, Identifiable and Sendable. Since classes can't be Sendable (in practice) they have to be marked @unchecked Sendable. 

It is required that all classes have an init method with no parameters. This is needed to have default values for all properties.

# API Considerations

Normally when working with database frameworks and managers, you end up with a lot of type-casting and similar annoyances. AutoDB preserves types so that fetching can be done as follows:

	let list = try await DataClass.fetchQuery("WHERE goals > 2")
	// list is of type [DataClass] where all have goals > 2.


## Separation of Tables and Models

A struct implementing the Table protocol becomes a database table, and is using Codable for that. It can be a struct or a class (if you really want to) and is never cached. 
A Model must be a class and holds a Table. It is always cached which avoids the problem with merge-conflicts since you cannot have two objects in different places with the same data. You will always be writing to the one correct object, and if two views have the same data - any changes in one will immediately be visible in the other.

The separation seems unnecessary at first, why not just use a single object?

The reasons are many:
* Auto-detect changes, and coalesce all your objects into one big write. Especially if you change your objects many times, postponing saves are magnitudes faster since unnecessary ones is simply not done. An object can detect this itself in the ´didSet´ method. Writing those for every property however, quickly becomes tedious (and it is not automatic).
* Control. There are times when you want a copy of your data just so it *won't* be updated by changes elsewhere. E.g. when building undo/redo. Keeping it as structs solves that problem.
* Speed. When you have a million tiny data structures, like positions on a map, you don't want to allocate an object for each one. Structs are much faster and uses less memory.
* Refresh. When external processes change your db-file you need to refresh the data (or other refresh situations like syncing). Held references makes this problematic, while very easy just updating its internal struct. 
* Speed. When writing to DB you just need to send the structs to handle themselves. No locking, retain/release etc, needs to be done. 

Eating the cake and having it too!

## 1.0 guarantees and limits

### Migrations

AutoDB compares the stored SQL schema with the current `Table` definition and automatically applies supported additive/removal changes and compatible conversions. It does not infer renames. If you rename a property, treat that as a migration you own and use the migration callback to copy data from the old column or temporary table before the old schema is dropped.

Guaranteed in 1.0:

- adding columns while preserving existing rows
- removing columns by rebuilding and copying the surviving columns
- widening from non-optional to optional
- tightening from optional to non-optional when the stored rows already satisfy the new non-null requirement
- primitive conversions already covered by the test suite: numeric `TEXT -> INTEGER`, `INTEGER -> TEXT`, and compatible integer-width changes
- preserving `URL`, `Date`, `Data`, primitive-backed enums, and Codable `BLOB` payloads through rebuild-style migrations when the column names remain the same
- index add/remove/change handling covered by the migration suite

Tolerated but not guaranteed:

- tightening from optional to non-optional when stored rows still contain `NULL`
- nonnumeric `TEXT -> INTEGER` conversions

Those two cases currently complete, but the resulting values follow SQLite/default-value behavior rather than a semantic conversion you should rely on. E.g if the column is defined as `NOT NULL DEFAULT 'empty'` it will return `empty` for stored nil values. 

Unsupported without a manual migration callback:

- rename inference
- lossy or domain-specific type conversions where you need to inspect and transform old values intentionally

### Cache-backed identity

`Model` instances are cached by concrete model type and `id`. While a model remains retained, fetching it again returns the same live instance. The cache is weak, so once nobody retains the model it may be recreated on the next fetch. This identity guarantee does not apply to plain `Table` values, which are intentionally uncached value snapshots.

### Save semantics

`save()` persists immediately. `didChange()` marks a model as dirty for a later `saveChanges()` or `saveAllChanges()` flush. Dirty buckets retain models until they are persisted, so batched writes reduce disk churn by temporarily keeping those models alive.

### `RelationQuery`

`RelationQuery` is stable in 1.0 only on Observation-capable OS versions. Its public contract is incremental fetching with deterministic paging state: inserts and deletes refresh the visible window, and overlapping later pages rebuild from offset `0` so `items`, `offset`, and `hasMore` stay consistent. There is no older-OS fallback implementation in 1.0.

### FTS

`FTSColumn` relies on SQLite FTS5. Update and delete triggers invalidate stale index rows, and searches repopulate missing rows on demand. If you provide a custom `FTSCallbackOwner`, its callback should deterministically map each `id` to the text that should be indexed.

### Primitive storage and enums

AutoDB stores SQL-native primitives using SQLite primitive column types rather than encoding them as `BLOB`.

Guaranteed SQL-native storage in 1.0:

- `String`, `URL`
- `Bool`, signed integers, unsigned integers
- `Double`, `Float`, `Date`
- `Data`, `AutoId128`
- optionals of the supported primitive families above

For enums:

- non-optional raw-value enums with SQL-compatible raw values are stored using their raw primitive storage
- if you need an optional enum column to remain SQL-native and queryable by raw value, use `SQLStringEnum`, `SQLIntegerEnum`, or `SQLUIntegerEnum`
- Codable payloads that are not SQL-native remain `BLOB` columns backed by encoded data

## Plain SQL queries

Many DB-engines force you to use their own query language, but AutoDB allows you to write plain SQL queries. This is useful for performance and opens upp the full power of SQL. It may seem as a good idea at first to build your own query language, but in the long run it only complicates things. SQL is also a universal language that you will benefit from knowing everywhere you go (and very easy to learn).

# Features

## FastTextSearch

The system supports FTS-columns, which is a powerful way to search for text. Create a FTSColumn like tihs:

```
final class Post: Model, @unchecked Sendable, FTSCallbackOwner {
	struct PostTable: Table {
		var id: AutoId = 1
		var title: String = "Untitled"
		var body: String = "Once upon a time..."
		var createdAt: Date = Date()
	}
	
	var value: PostTable
	init(_ value: PostTable) {
		self.value = value
	}
	
	var index = FTSColumn<PostTable>("Index")
	
	// note that the callback is optional if the name of the FTSColumn is the same as the column you want to index (and you only want to index one column), eg. "body".
	static func textCallback(_ ids: [AutoId]) async -> [AutoId: String] {
		var result: [AutoId: String] = [:]
		let list = (try? await PostTable.fetchIds(ids)) ?? []
		for item in list {
			result[item.id] = item.title + " " + item.body
		}
		return result
	}
}
```

As you can see you must specify your own Table as the generic type for the FTSColumn. This is because the type-system needs to know which table to index. The column will become a virtual table so it needs a name to be a unique string. 

Now you can search like this, and all matching objects with that phrase will be returned:

```
let matches = try await FTSColumn<PostTable>.search("I love My" column: "Index")
```

A shorthand if you have fetched the object already:
```
let matches = try await anExampleObject.index.search("I love My")
```
It will only use the anExampleObject to fill in the generic info the type system needs.

If contained inside a Model it will return the Table-struct:
```
var post: Post = await Post.create()
[...]
let fairyTalePosts: [PostTable] = try await post.ownerIndex.search("once upon a time")
```

The 1.0 contract for FTS is:

- `FTSColumn` is part of the public supported API
- SQLite FTS5 support is required
- update and delete triggers keep the index invalidated correctly
- missing rows are repopulated on demand during search
- if you rename the indexed column or callback behavior, treat that as a migration concern just like any other schema-visible change

# Transactions

Transactions are supported, wrap your code in a closure where no calls may throw errors. If it does, DB-state is rolled back to its initial state. Like this:

```
try? await TransClass.transaction { _, _ in
	let first = await TransClass.create(1)
	first.integer = 2
	try await first.save()
	
	#expect(first.integer == 2)
	
	// any error will cause rollback
	throw CancellationError()
}

// TransClass has no objects here, and none with integer == 2
// All other calls to db will await until this point where the transaction is done.
```

The transaction token is carried automatically for the duration of the closure (as a task-local, `SemaphoreToken.current`), so all AutoDB calls made inside the transaction - directly or indirectly - re-enter the lock without deadlocking. You no longer need to forward the `token` closure parameter; passing it explicitly remains supported and always takes precedence, so existing code keeps working unchanged.

Details worth knowing:

- A nested `transaction` call inside the closure reuses the outer token and only nests the savepoint - rolling back the outer transaction also rolls back the inner one.
- The token flows into `Task { }` spawned inside the closure, but intentionally **not** into `Task.detached` - detached work waits for the transaction to finish, just like before.
- The same applies to migrations: queries inside your `migration(_:_:_:)` implementation no longer need to forward the token.

## Removing explicit tokens from your code

The `token:` parameters are deprecated: explicit tokens still work exactly as before (and win over the ambient one), but every call site that passes one now gets a compiler warning, and the parameters are removed in the next major version. The `migration(_:_:)` protocol requirement has already dropped its token parameter. These regex find/replace pairs (Xcode: Find navigator with "Regular Expression", or any editor with ICU/PCRE regex) clean up the call sites:

1. **Token argument followed by other arguments** - `fetchId(token: token, 1)` → `fetchId(1)`, `db.query(token: token, "SELECT ...")` → `db.query("SELECT ...")`:
   - Find: `token:\s*[\w.]+,\s*`
   - Replace: *(empty)*

2. **Token as the only argument** - `save(token: token)` → `save()`, `delete(token: token)` → `delete()`:
   - Find: `\(token:\s*[\w.]+\)`
   - Replace: `()`

3. **Leftover empty parens before the trailing closure** (from step 2 hitting `transaction(token: token) { ... }` - scoped to `transaction`, a bare `\(\)\s*\{` would also mangle every `func foo() {`):
   - Find: `transaction\(\)\s*\{`
   - Replace: `transaction {`

4. **Unused closure/function parameters** - after 1-3 the `token` parameter of `transaction { db, token in ... }` closures and your `migration(_ token:...)` implementations is unused; silence the warning with:
   - Find: `\{\s*(\w+),\s*token\s+in`
   - Replace: `{ $1, _ in`
   - (The `migration` protocol signature itself must keep its token parameter until the next major version - just stop forwarding it.)

⚠️ Before you run these, check the exceptions - a plain `token:` text search finds anything the regexes miss (expressions like `token: t ?? other`):

- **Don't remove tokens you generated yourself** for your own `Semaphore` instances - only tokens that originate from AutoDB's `transaction`/`migration` closures.
- **`create(token: someToken)` without an id uses the token as the new object's id** (legacy behavior). If you rely on that, pass the id explicitly instead: `create(someToken)`.
- **Tokens deliberately handed to *other tasks*** (e.g. passed into `Task.detached` or stored for later) keep working only as explicit tokens - the task-local does not follow them. If you pass a token into detached work so it can join the transaction, keep it explicit.

Then build: the compiler flags any now-unused `token` variables, which is your checklist of what's left.

## Deadlocks with transactions

Transactions are guarded by semaphores; with the ambient token the common deadlocks (forgetting to forward the token) are gone, but a deadlock is still possible if the transaction *waits* for work that itself waits for the transaction (e.g. awaiting a `Task.detached` DB call from inside the closure). See `TransactionTests.deadlockSemaphore()` for how to discover these with the watchdog. 

## Write to DB in bulk

It is smarter to save many objects in one go, to mark an object to be saved for later call `artist.didChange()`. Later you can then save all those objects by calling `Artist.saveChanges()`. Note that the system will keep a reference to all objects waiting to be saved.
To save all Models with changes call `Artist.saveAllChanges()` or `AutoDBManager.shared.saveAllChanges()`.
This can be done automatically by using the `didSet` method on a Model's properties, like this:

```swift
var value: PostTable {
	didSet { 
		didSet(oldValue) 
	}
}
```

## Caching

Objects are cached with weak pointers, meaning that they will be deallocated when no one else is using them. During usage they will be returned when fetching from DB instead of recreated every time. 

## Migration

A common source of errors and hangs is migration. The system knows about current SQL-tables on disc, and handle migration automatically and efficiently by comparing with the data-classes. It handles adding and removing columns, and changing types (to some extent). If you change a String to Int it will work as long as the string can be an Int like "2", but everything else like "some words" will of course not be a meaningful Int - so keep that in mind. For best result, never change your types. Instead, create new columns.
Migration is really fast and even if your tables have millions of rows it will probably not be noticable for the user.

NOTE: AutoDB does not automatically infer renames. If you change a property name it will create the new column and treat the old one as removed, so use the migration callback to copy data from the preserved old table when you need a rename-safe migration.

## Uniqueness

When data has an identity, like for a user or specific items, it needs to be unique. Its easy to make mistakes when keeping track of unique objects in a large app. The system can do this for us automatically and in the same time also cache frequently used objects to make their access and usage faster. Changes in one view will then always be reflected by all other views that are using the same data with lightning speeds since no refetching from disc is needed.

# SwiftUI

You may use your AutoDB data objects directly as viewModels if you wish, but you can also have nested objects in your viewModels. 

### @Observable framework

Just annotate your AutoDB classes with @Observable.

```
@Observable final class Artist: AutoDB, @unchecked Sendable {
	var id: AutoId = 0
	var name: String = ""
	...
}
```

This path requires Observation availability, which currently means macOS 14+, iOS 17+, tvOS 17+, or watchOS 10+.

### ObservableObject

Here you need to subscribe to the nested object's changes, like this:

```
	import Combine
	final class NestedViewModel: AutoDB, ObservableObject, @unchecked Sendable {
		var id: AutoId = 0
	}
	
	class MainViewModel: ObservableObject {
		private var cancellables = Set<AnyCancellable>()
		@Published var nestedModel: NestedViewModel
		
		init(nestedModel: NestedViewModel) {
			self.nestedModel = nestedModel
			nestedModel.objectWillChange
				.sink {
					self.objectWillChange.send()
				}
				.store(in: &cancellables)
		}
	}
```

# Codable, CodingKeys and default values

When creating/updating your table, the specified default values are used and will be present in the DB. Do not specify enourmous structs as defaults or image data blobs if performance is important.

CodingKeys will be used to define your tables, and they are the ones to be used when issuing sql-statements. If you are using underscores, they will be automatically removed. E.g. when making your classes @Observable this happens automatically for all your variables. 
