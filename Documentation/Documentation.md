# AutoDB Swift

The purpose is to have an automatic system for handling persistence. Objects should be able to save and restore themselves and common headaches should be removed, especially migration, uniqueness, and relation handling.

## Release scope

AutoDB 1.0 is an Apple-first Swift Package release.

- Package platforms: macOS 14+, iOS 17+, tvOS 17+, watchOS 10+
- Cross-platform support outside Apple platforms is not part of the 1.0 contract

For first integration steps, start with the [README](../README.md) and the [Adoption Guide](Adoption.md).

## Availability

Current package support is macOS 14+, iOS 17+, tvOS 17+, and watchOS 10+ - the floor where Observation is available, which models and `RelationQuery` rely on.

- The core table/model APIs, migrations, caching, and FTS are part of the stable package surface.
- Cross-platform work outside Apple platforms is still exploratory rather than release-ready. Android and Linux build with the `SQLCipher` trait, see [Cross-platform notes](Android.md).
- Encryption needs the `SQLCipher` trait, see [Encryption](#encryption).

## Quick start

See the [README](../README.md).

# Overview

The system is built on top of SQLite and uses Codable to read and write data to objects.

Data lives in structs implementing `Table`, which are Codable. Classes implementing `Model` wrap a Table value, give it an identity and are Hashable, Identifiable and Sendable. A Model keeps its value in a `ModelStorage`, so it has no mutable state of its own and is checked `Sendable` - no `@unchecked`.

It is required that all classes have an init method with no parameters. This is needed to have default values for all properties.

# API Considerations

It is common when working with database frameworks and managers, you end up with a lot of type-casting and similar annoyances. AutoDB preserves types so that fetching can be done as follows:

	let list = try await DataClass.fetchQuery("WHERE goals > 2")
	// list is of type [DataClass] where all have goals > 2.


## Separation of Tables and Models

A struct implementing the Table protocol becomes a database table, and is using Codable for that. It can be a struct or a class (if you really want to) and is never cached. 
A Model must be a class and holds a Table. It is always cached which avoids the problem with merge-conflicts since you cannot have two objects in different places with the same data. You will always be writing to the one correct object, and if two views have the same data - any changes in one will immediately be visible in the other.

The separation seems unnecessary at first, why not just use a single object?

The reasons are many:
* Auto-detect changes, and coalesce all your objects into one big write. Especially if you change your objects many times, postponing saves are magnitudes faster since unnecessary ones is simply not done. A Model's `ModelStorage` detects every change to its value, no boilerplate needed.
* Control. There are times when you want a copy of your data just so it *won't* be updated by changes elsewhere. E.g. when building undo/redo. Keeping it as structs solves that problem.
* Speed. When you have a million tiny data structures, like positions on a map, you don't want to allocate an object for each one. Structs are much faster and uses less memory.
* Refresh. When external processes change your db-file you need to refresh the data (or other refresh situations like syncing). Held references makes this problematic, while very easy just updating its internal struct. 
* Speed. When writing to DB you just need to send the structs to handle themselves. No locking, retain/release etc, needs to be done. 

Eating the cake and having it too!

### Models and ModelStorage

A Model keeps its value in a `ModelStorage`, stored as a `let`:

```swift
final class Artist: Model {
	struct Value: Table {
		var id: AutoId = 0
		var name = ""
	}
	
	let storage: ModelStorage<Value>
	
	init(_ value: Value) {
		self.storage = ModelStorage(value)
	}
}
```

- `artist.value` reads a snapshot, `artist.value = new` replaces it.
- `artist.withValue { $0.name = "x" }` reads or modifies it atomically. `artist.value.name = "x"` also works and is change-tracked, but it is a get-modify-set: two lock acquisitions with a gap. Use `withValue` when several tasks may write at the same time.
- Every change marks the object for `saveChanges()`, notifies Observation (SwiftUI tracks `artist.value` without `@Observable`) and sends `objectWillChange` when the model is an `ObservableObject`. Writing an equal value is not a change.
- `refreshCache()` notifies observers but does not mark the object for saving - the value came from the database.

Since the storage is the only mutable state, the compiler checks the rest of the class: a `var` stored property is an error. Make relation columns like `FTSColumn` a `let` (they are classes), and keep anything else mutable in the Table value or behind a lock.

### Migrating to ModelStorage

1.0 replaced the `var value` requirement with `storage`. Call sites don't change - `value` and `withValue` are still there - only the model declarations do:

| Before | After |
| --- | --- |
| `final class Artist: Model, @unchecked Sendable` | `final class Artist: Model` |
| `var value: Value { didSet { didSet(oldValue) } }` | `let storage: ModelStorage<Value>` |
| `var value: Value` (without change-tracking) | `let storage: ModelStorage<Value>` - changes are now always tracked |
| `@Published var value: Value` and a `$value` sink | `let storage: ModelStorage<Value>`, `objectWillChange` is sent automatically |
| `self.value = value` in `init` | `self.storage = ModelStorage(value)` |
| `final class Person: StoredModel` | `final class Person: Model` (`StoredModel` is a deprecated alias) |
| `var index = FTSColumn<Value>(...)` on the model | `let index = FTSColumn<Value>(...)` |

Then build and fix what the compiler flags: mutable or non-Sendable stored properties were unchecked data races before. `@Observable` on a model is no longer needed for its value; keep it only for other observable properties.

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

A save takes no lock of its own: every save encodes its rows into its own buffer and the database serializes the statements. Outside a transaction a save waits for an open transaction to end like any other write; inside one it joins the transaction through the ambient token. See [Deadlocks with transactions](#deadlocks-with-transactions) for the lock order this rests on.

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

## Rows from outside the database

Two APIs let code that never sees your models - a sync layer, an importer - work with a table by column name alone:

- `try await SomeTable.columns()` returns the `[Column]` AutoDB created the table from: `name`, `columnType` (`.integer/.real/.text/.blob`), `valueType` (the Swift type, unwrapped for optionals, the enum or OptionSet type for raw-value enums) and `mayBeNull`. Dates are `.real` with `valueType == Date.self`, Bool is `.integer`.
- `try await value.updated(with: row)` decodes a partial `Row` (`[String: SQLValue]`) over an existing value. Columns the row lacks keep the value's own; a `.null` clears an optional; every conversion (Date from seconds, Bool from 0/1, raw-value enums, optionals) is the one the fetch path uses. For a `Model`, decode over `instance.value` and assign the result with `withValue { $0 = decoded }` - the id and whatever `awakeFromInit` set are kept, and no setter runs.

```swift
let row: Row = ["title": .text("From the other device"), "pauseDate": .null]
let decoded = try await feed.value.updated(with: row)
feed.withValue { $0 = decoded }
try await feed.save()
```

# Features

## Database settings

Every `Table` says which database it lives in through `static var autoDBSettings: AutoDBSettings`. AutoDB ships no default, so the compiler makes you choose, and there is nothing to register at app start. Declare it once for the whole module:

```swift
extension Table {
	static var autoDBSettings: AutoDBSettings { .regular }
}
```

The presets:

- `.regular`: `AutoDB/AutoDB.db` in Application Support, backed up.
- `.cache`: `AutoDB/AutoDB.db` in Caches, not backed up, and the system may delete it when space runs low. `.cache(path:)` picks another file name.
- `.memory`: an in-memory database.
- `AutoDBSettings(path:iCloudBackup:inAppFolder:inCacheFolder:autoCloseDelay:)` for anything else. With both folder flags false, `path` is absolute, for example an App Group container.

On macOS the app name is added between the folder and `path`.

The most specific declaration wins:

1. A type's own `autoDBSettings`. For a `Model`, declare it on its `Value`.
2. A refined protocol's default: `protocol CacheTable: Table {}` with `extension CacheTable { static var autoDBSettings: AutoDBSettings { .cache } }`, and its tables conform to `CacheTable`.
3. The module-wide `extension Table`.

Keep the `extension Table` `internal`, and repeat it in every module that declares tables. A `public` one in a shared module makes conformances in importing modules ambiguous.

An internal default cannot serve a `public` table type: Swift requires a public witness for a public protocol's requirement. In a module with public tables, give them a public refined protocol instead, it does not reach tables in modules that import it:

```swift
public protocol FeedsTable: Table {}
public extension FeedsTable {
	static var autoDBSettings: AutoDBSettings { .regular }
}

public final class Feed: Model {
	public struct Value: FeedsTable { ... }
}
```

The module can keep an internal `extension Table` next to it for its internal tables. A single public table can also declare `public static var autoDBSettings` itself.

`autoDBSettings` is read the first time a table is used, so it may compute a path. Tables whose settings resolve to the same place share one connection. If two different settings point to the same file, the first one's options (backup, auto-close delay) are used and AutoDB logs the mismatch once. Two connections to one file are never opened.

`.memory` is shared by every table of a manager that uses it, and it lives as long as that manager. It never auto-closes, and `AutoDBManager.close()` skips it, since closing it would discard its data.

### Migrating from SettingsKey

| Before | After |
| --- | --- |
| `static var autoDBSettings: SettingsKey { .regular }` | `static var autoDBSettings: AutoDBSettings { .regular }` |
| `.cache` | `.cache` |
| `.specific(settings)` | `settings` |
| `AutoDBManager.shared.setAppSettings(s, for: .regular)` at startup | `extension Table { static var autoDBSettings: AutoDBSettings { s } }` |
| `setAppSettings(s, for: .cache)` | a refined protocol, or `s` on each cache table |
| `switchDB([.regular: url])` in tests | `@Suite(.autoDB)`, see [Scopes and testing](#scopes-and-testing) |

## Encryption

Encryption needs the `SQLCipher` trait, which builds AutoDB on [skip's swift-sqlcipher](https://github.com/skiptools/swift-sqlcipher) (SQLite with SQLCipher and FTS5) instead of the system SQLite:

```swift
.package(url: "https://github.com/AutoDB/AutoDB", from: "1.1.0", traits: ["SQLCipher"])
```

Without the trait nothing extra is downloaded and `encrypted(key:)` does not exist, so asking for encryption without it is a compile error rather than a plaintext file.

Encrypted settings carry a closure that fetches the key, so there is nothing to set up before the first table is used. Declare them once, so every table in the file shares one key:

```swift
extension AutoDBSettings {
	static let secure = AutoDBSettings.regular.encrypted { .raw(try Keychain.databaseKey()) }
}

extension Table {
	static var autoDBSettings: AutoDBSettings { .secure }
}
```

- `.raw(Data)` is 32 random bytes and opens fast. `.passphrase(String)` is stretched with PBKDF2 on every open, around 100 ms, and connections reopen after each idle auto-close, so prefer raw keys.
- The closure runs when a database is created and when `open()` follows `closeNow()` or `close(allowReopen: false)`. In between, the database keeps the key so an idle auto-close can reopen without waiting. Fetching it late also means a Keychain read doesn't happen at launch, when the device may still be locked.
- The key is never part of the settings' equality or description. Settings that differ only in their key closure count as equal and share the first one's connection, like any other settings for the same file.
- A wrong key throws `Database.Error.wrongEncryptionKey`.
- An existing unencrypted file is encrypted in place the first time it is opened with encrypted settings: it is exported into `<file>.encrypting` and then renamed over the original, so a crash in between leaves the old file readable.
- `manager.changeEncryptionKey(for: settings, to: newKey)` re-encrypts the file once running transactions finish. Store the new key where the closure reads it first, since the closure must return it from then on.
- `.memory` ignores `encrypted(key:)`.

A key in the Keychain, created on first use:

```swift
enum Keychain {
	static func databaseKey() throws -> Data {
		let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: "AutoDB", kSecReturnData as String: true]
		var item: CFTypeRef?
		if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let key = item as? Data {
			return key
		}
		let key = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
		let add: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: "AutoDB", kSecValueData as String: key, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
		let status = SecItemAdd(add as CFDictionary, nil)
		guard status == errSecSuccess else {
			throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
		}
		return key
	}
}
```

`AfterFirstUnlock` lets background work open the database while the device is locked. `ThisDeviceOnly` keeps the key out of backups: a restored backup of an encrypted file can't be read on a new device. Drop it if the database is backed up (`iCloudBackup: true`) and should survive a restore.

## Scopes and testing

Settings answer *which* database a table uses. An `AutoDBManager` answers *where* that set of databases lives. Each manager owns all of its state: its connections, table setup, object caches, changed and deleted objects, and FTS state. `AutoDBManager.shared` is the app's manager.

`AutoDBManager(root: url)` makes another manager whose files live under `url`:

| Settings | File under the root |
| --- | --- |
| in the app folder, like `.regular` | `root/Application Support/<path>` |
| in the cache folder, like `.cache` | `root/Caches/<path>` |
| an absolute path | `root/<file name>` |
| `.memory` | in memory, private to the manager |

`.regular` and `.cache` stay two files, so relations between them still work under a root.

### Which manager a call uses

- Static calls (`fetchId`, `fetchQuery`, `create`, `query`, `execute`, `truncateTable`, `saveChanges`) use `AutoDBManager.current`. That is the manager bound with `AutoDBManager.withScope(manager) { ... }`, or `.shared` outside a scope.
- A model remembers the manager that created, fetched or registered it. Its `save()`, `delete()`, `isDeleted`, change tracking and relations use that manager, wherever they are called from.

The scope is a task-local, so it reaches `Task { }` and child tasks, but not `Task.detached`, DispatchQueue blocks or NotificationCenter observers. A model saved from any of those still lands in its own files, because the model carries its manager. A static call made from there uses `.shared`. Wrap it in `withScope` when it must stay in the scope.

`withScope` works in apps too, for example for an import into a separate database:

```swift
let importer = AutoDBManager(root: importFolder)
try await AutoDBManager.withScope(importer) {
	let items = try await FeedItem.fetchQuery("WHERE unread = 1")
	...
}
```

### Testing with AutoDBTesting

Add the `AutoDBTesting` product to your test target and put `.autoDB` on each suite:

```swift
import Testing
import AutoDBTesting

@Suite(.autoDB)
struct FeedTests {
	@Test func save() async throws {
		let item = await FeedItem.create()
		try await item.save()
	}
}
```

Every suite gets a manager rooted at `Caches/AutoDBTests/<suite name>/`. Suites that use the same production tables can then run in parallel without seeing each other's rows, with no `switchDB`, `.serialized` or cleanup between them.

- On a suite, every test and nested suite shares one manager. On a single test, that test gets its own.
- `.autoDB("name")` picks the folder name. Names must be unique within a test process.
- The folder is deleted the first time a run uses it, so every run starts empty and the last run's files stay for inspection.
- Inside a suite, tests that share tables still need `.serialized` or their own ids.

### When AutoDB is inside another library

Link AutoDBTesting only when the test target links the `AutoDB` product itself. When AutoDB is compiled into another library, for example a dynamic framework that re-exports it, AutoDBTesting brings a second copy of AutoDB. Its `withScope` binds a task-local the library's copy never reads, and Xcode may also move AutoDB out of the library's binary so the library no longer links.

Declare the trait in the test target instead. `AutoDBManager.testManager(_:)` does the folders, so only the Swift Testing part is left:

```swift
import Testing
import AutoDB	// or the library that re-exports it

struct AutoDBTrait: SuiteTrait, TestTrait, TestScoping {
	var isRecursive: Bool { false }
	
	func scopeProvider(for test: Test, testCase: Test.Case?) -> AutoDBTrait? {
		if test.isSuite || testCase == nil {
			return self
		}
		return nil
	}
	
	func provideScope(for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void) async throws {
		let manager = AutoDBManager.testManager(test.id.nameComponents.joined(separator: "."))
		try await AutoDBManager.withScope(manager) {
			try await function()
		}
	}
}

extension Trait where Self == AutoDBTrait {
	static var autoDB: AutoDBTrait { AutoDBTrait() }
}
```

Make it `public` when it lives in a shared test-support target.

### The leak guard

A test that forgets `.autoDB` would use `.shared`, and an unsandboxed macOS test process resolves `.shared` to your real database. Guard against this once in the test target:

```swift
await AutoDBManager.shared.requireScope()
```

After this, any table that `.shared` has not set up yet throws `AutoError.noScope` instead of opening a file.

### Singletons

A process-wide `static` that holds a model is shared by every scope, and it shows rows from whichever scope loaded it first. Keep database-backed singletons in the manager instead, so each scope gets its own:

```swift
extension SharedModel {
	static var current: SharedModel {
		AutoDBManager.current.storage(for: "SharedModel") { SharedModel() }
	}
}
```

`make` runs outside the lock. When two callers race, the first value stored wins and both get it.

## Connection lifecycle and auto-close

You never need to open or close the database yourself. Every `Database` closes automatically after `AutoDBManager.defaultWaitTime` (3 seconds) of non-use - releasing its file handle, checkpointing the WAL and freeing SQLite's page cache - and reopens transparently on the next access. Reopening costs a few milliseconds at most, so this is invisible in practice.

Change the delay per database (or disable auto-close) via settings or at runtime:

```swift
// per database, through settings:
AutoDBSettings(path: "myApp.db", autoCloseDelay: 60)	// close after a minute of non-use
AutoDBSettings(path: "myApp.db", autoCloseDelay: nil)	// never auto-close

// at runtime, for all databases:
await AutoDBManager.shared.setAutoClose(after: 60)
// or for a single one:
try await MyTable.db().setAutoClose(after: nil)
```

A DB closed with `close()` reopens on the next access, just like after an auto-close - handy when going to the background, since a query that races the return to the foreground simply reopens it. Pass `close(allowReopen: false)`, or use `closeNow()`, to keep it closed (queries throw `databaseIsClosed`) until you call `open()`; such a DB is never auto-reopened, and a later `close()` does not make it reopenable again. Auto-close also never interrupts work: it waits out running transactions and gives them a fresh idle window. In-memory databases never auto-close, since closing one would discard all their data.

Auto-close is aware of scheduled work: `saveChangesLater`, `saveAllChangesLater` and `deleteLater` hold the affected connection open until their flush has run (whatever the configured delays are), so the DB never closes just to reopen for a pending save. If you schedule delayed DB work of your own, you can do the same with `db.keepOpen(for: seconds)` - a floor that postpones auto-close but never delays a manual close.

## Debounce delays

The debounced conveniences `saveChangesLater`, `saveAllChangesLater` and `deleteLater` all wait `AutoDBManager.defaultWaitTime` (3 seconds) by default before doing their work. Tune them at runtime:

```swift
await AutoDBManager.shared.setSaveLaterDelay(1)		// saveChangesLater / saveAllChangesLater
await AutoDBManager.shared.setDeleteLaterDelay(5)	// deleteLater
```

## FastTextSearch

The system supports FTS-columns, which is a powerful way to search for text. Create a FTSColumn like tihs:

```
final class Post: Model, FTSCallbackOwner {
	struct PostTable: Table {
		var id: AutoId = 1
		var title: String = "Untitled"
		var body: String = "Once upon a time..."
		var createdAt: Date = Date()
	}
	
	let storage: ModelStorage<PostTable>
	init(_ value: PostTable) {
		self.storage = ModelStorage(value)
	}
	
	let index = FTSColumn<PostTable>("Index")
	
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
try? await TransClass.transaction { _ in
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

The transaction token is carried automatically for the duration of the closure (as a task-local, `SemaphoreToken.current`), so all AutoDB calls made inside the transaction - directly or indirectly - re-enter the lock without deadlocking. There is no token to forward.

Details worth knowing:

- A nested `transaction` call inside the closure reuses the outer token and only nests the savepoint - rolling back the outer transaction also rolls back the inner one.
- The token flows into `Task { }` spawned inside the closure, but intentionally **not** into `Task.detached` - detached work waits for the transaction to finish, just like before.
- The same applies to migrations: queries inside your `migration(_:_:)` implementation join the migration transaction.
- `create()` binds a token the same way while your `awakeFromInit()` runs, so the hook can save or create the same type - see [awakeFromInit](#awakefrominit) for the caveat about `Task { }`.
- `Database.excludingTransactions { }` runs a closure while no transaction is open and lets none start until it returns, without being a transaction itself (plain queries from other tasks are not held back). It re-enters through the ambient token and binds one for the closure. `create()` uses it; take it yourself before any lock of your own that code inside a transaction may also need.

## Removing explicit tokens from your code

1.0 removed the `token:` parameters and the `{ db, token in }` transaction closures; code that still passes tokens no longer compiles. These regex find/replace pairs (Xcode: Find navigator with "Regular Expression", or any editor with ICU/PCRE regex) clean up the call sites:

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
   - Then remove the `_` parameter: `transaction { db in ... }`, and drop the token parameter from your `migration(_:_:)` implementations.

⚠️ Before you run these, check the exceptions - a plain `token:` text search finds anything the regexes miss (expressions like `token: t ?? other`):

- **Don't remove tokens you generated yourself** for your own `Semaphore` instances - only tokens that originate from AutoDB's `transaction`/`migration` closures.
- **`create(token: someToken)` without an id used the token as the new object's id.** If you rely on that, pass the id explicitly instead: `create(someToken)`.
- **Tokens deliberately handed to *other tasks*** (e.g. passed into `Task.detached` or stored for later) can't join the transaction any more - the task-local does not follow them. Await that work inside the transaction with a plain `Task { }`, or bind the token yourself with `SemaphoreToken.$current.withValue(token) { ... }`.

Then build: the compiler flags any now-unused `token` variables, which is your checklist of what's left.

## Deadlocks with transactions

Transactions are guarded by semaphores; with the ambient token the common deadlocks (forgetting to forward the token) are gone, but a deadlock is still possible if the transaction *waits* for work that itself waits for the transaction (e.g. awaiting a `Task.detached` DB call from inside the closure). See `TransactionTests.deadlockSemaphore()` for how to discover these with the watchdog.

While a transaction is open, every query from another task waits for it. That makes one lock order mandatory for anything that holds a lock *and* queries: **the database's transaction slot first, your lock second.** Holding a lock while a query waits for the transaction hangs the moment the transaction's own task needs that lock - both tasks are then suspended in `await`, every thread is idle, and nothing in a stack sample points at the culprit. AutoDB follows the order itself:

- saves hold no lock at all (each save has its own encoder buffers), so a save outside a transaction simply waits for it;
- `create()` takes the type's creation lock only inside `Database.excludingTransactions`, so a `create(id)` that has to fetch waits for the transaction *before* it locks.

- a table's first-time setup (`db()`, or the first query on it) runs inside `excludingTransactions` too, under a lock of its own per table. A setup outside a transaction waits for the transaction first; a transaction that reaches a fresh table sets it up from inside; and setting one table up never holds another table back. The process-wide setup semaphore only guards opening the database file.

### The synchronous create

The non-async `create(_:)` (on `Model` and `Table`) blocks its thread with a `DispatchSemaphore` until a task has created the object. That task runs on Swift's cooperative thread pool, which has one thread per core. Called from async code, the blocked thread *is* a pool thread: with as many concurrent callers as the pool has threads, every thread waits for a task that no thread is left to run, and the process hangs with no CPU use. A stack sample shows every `com.apple.root.*.cooperative` thread in `semaphore_wait_trap` under `create(_:)`.

Both are therefore `@available(*, noasync)`: calling them from an async function is an error in Swift 6 mode and a warning in Swift 5. The check only sees direct calls - not a sync wrapper around them, a sync closure like `map { }` or a sync function that async code calls. Mark such wrappers `noasync` too, and use `await create()` anywhere that can run on a task. The sync version is only for code that really is synchronous, off the pool (the main thread, a plain `Thread`, a dispatch queue).

## Write to DB in bulk

It is smarter to save many objects in one go, to mark an object to be saved for later call `artist.didChange()`. Later you can then save all those objects by calling `Artist.saveChanges()`. Note that the system will keep a reference to all objects waiting to be saved.
To save all Models with changes call `Artist.saveAllChanges()` or `AutoDBManager.shared.saveAllChanges()`.
Models do this automatically: every change to `value` or through `withValue` marks the object, see [Models and ModelStorage](#models-and-modelstorage).

## Caching

Objects are cached with weak pointers, meaning that they will be deallocated when no one else is using them. During usage they will be returned when fetching from DB instead of recreated every time. 

## awakeFromInit

`awakeFromInit()` is called once at the end of `create()`, after the new object has been cached and its relations wired up. Override it to set defaults, derive values or do any other setup the object needs before it is handed out. The default does nothing and there is nothing to forward - caching and relation owners are handled by `create()` no matter what your override does:

```swift
func awakeFromInit() async {
	// your own setup, nothing else is required
}
```

It only runs for objects made by `create()`. Objects decoded from the database get the synchronous `awakeFromFetch()` instead, after they have been cached and their relations set up.

### Objects you construct yourself

If you build a model some other way than `create()`, call `register()` on it. It does what `create()` does after the lookup: caches the object so fetches return this instance, wires up its relations and then calls `awakeFromInit()`. `register()` is not part of the protocol, so it cannot be overridden and the framework part always runs. A registered object is not marked as new, so its first `save()` goes through `INSERT OR REPLACE` and overwrites any row with the same id instead of failing:

```swift
var value = MyModel.Value()
value.id = someId
let item = MyModel(value)
await item.register()
```

### Saving and creating inside awakeFromInit

`create()` holds the type's creation lock while `awakeFromInit` runs, so two tasks can never create the same object at the same time. The lock is taken inside `Database.excludingTransactions`, so a `create()` outside a transaction first waits for any open transaction and only then locks - the order that keeps it from deadlocking with a create or save of the type inside that transaction. To keep the lock from deadlocking your own code, the token holding it is bound as the ambient `SemaphoreToken.current` for the duration of the hook - inside a transaction that is the transaction token, otherwise a fresh one that lives only for this `create()` call. AutoDB calls made from `awakeFromInit` - `save()`, `create()` of the same type, queries - re-enter the lock instead of waiting on it, exactly like inside a transaction:

```swift
func awakeFromInit() async {
	// both re-enter the lock that create() is holding
	try? await save()
	let sibling = await Self.create()
}
```

**Caveat: `Task { }` inherits the token.** The ambient token follows the same rule as in transactions: it flows into `Task { }` but not into `Task.detached`. A `Task { }` started in `awakeFromInit` that saves or creates this type can therefore run while `create()` still holds the lock, re-enter it and write while `awakeFromInit` is still setting the object up - and if several such tasks re-enter at once, nothing keeps their writes apart. For fire-and-forget work, drop the token so the task waits for `create()` to finish like any other caller:

```swift
func awakeFromInit() async {
	Task {
		// don't join create()'s lock - wait for it like everyone else
		await SemaphoreToken.detached {
			try? await self.save()
		}
	}
	// or use Task.detached, which never inherits task-locals
}
```

AutoDB's own deferred paths already do this: the non-async `save()`, `saveChangesLater()`, `saveChangesDetached()` and `delete()` all run without the token, and `didChange()` only marks the object dirty without touching the database. Those are safe to call from `awakeFromInit` as they are: the rule only matters for tasks you spawn yourself.

## Migration

A common source of errors and hangs is migration. The system knows about current SQL-tables on disc, and handle migration automatically and efficiently by comparing with the data-classes. It handles adding and removing columns, and changing types (to some extent). If you change a String to Int it will work as long as the string can be an Int like "2", but everything else like "some words" will of course not be a meaningful Int - so keep that in mind. For best result, never change your types. Instead, create new columns.
Migration is really fast and even if your tables have millions of rows it will probably not be noticable for the user.

NOTE: AutoDB does not automatically infer renames. If you change a property name it will create the new column and treat the old one as removed, so use the migration callback to copy data from the preserved old table when you need a rename-safe migration.

## Uniqueness

When data has an identity, like for a user or specific items, it needs to be unique. Its easy to make mistakes when keeping track of unique objects in a large app. The system can do this for us automatically and in the same time also cache frequently used objects to make their access and usage faster. Changes in one view will then always be reflected by all other views that are using the same data with lightning speeds since no refetching from disc is needed.

# SwiftUI

You may use your AutoDB data objects directly as viewModels if you wish, but you can also have nested objects in your viewModels. 

### Observation

Models are observable out of the box: `ModelStorage` registers every read of `value` and notifies on every change, so a SwiftUI view that reads `artist.value.name` updates when it changes - no `@Observable` needed. Writing an equal value does not notify.

Observers are notified after the change, outside the storage's lock, since only then is it known whether the value changed. The whole value is one observable property: a view reading `artist.value.name` also updates when `genre` changes.

### ObservableObject

A Model that conforms to `ObservableObject` gets `objectWillChange` sent automatically whenever its value changes:

```swift
import Combine

final class Artist: Model, ObservableObject {
	struct Value: Table { ... }
	let storage: ModelStorage<Value>
	init(_ value: Value) {
		self.storage = ModelStorage(value)
	}
}
```

To nest it in another view model, forward its changes:

```swift
class MainViewModel: ObservableObject {
	private var cancellables = Set<AnyCancellable>()
	@Published var artist: Artist
	
	init(artist: Artist) {
		self.artist = artist
		artist.objectWillChange
			.sink { [weak self] in
				self?.objectWillChange.send()
			}
			.store(in: &cancellables)
	}
}
```

# Codable, CodingKeys and default values

When creating/updating your table, the specified default values are used and will be present in the DB. Do not specify enourmous structs as defaults or image data blobs if performance is important.

CodingKeys will be used to define your tables, and they are the ones to be used when issuing sql-statements. If you are using underscores, they will be automatically removed. E.g. when making your classes @Observable this happens automatically for all your variables. 
