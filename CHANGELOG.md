# Changelog

## 1.0.0 (Draft)

AutoDB 1.0 is intended to be the first stable Apple-first Swift Package release.

### Supported platforms

- Package platforms: macOS 14+, iOS 17+, tvOS 13+
- Tested regularly: macOS and iOS through `swift test`
- `RelationQuery` requires Observation availability: macOS 14+, iOS 17+, tvOS 17+, watchOS 10+

### Stable surface in 1.0

- `Table` and `Model` persistence APIs
- Automatic schema migration for add/remove column changes, supported compatible type conversions, and explicit migration callbacks
- Cache-backed model identity and batched change saving
- Uniqueness constraints and transactions
- `ManyRelation` and `OneRelation`
- FTS-backed search through `FTSColumn`
- `RelationQuery` on supported Observation-capable OS versions

### Database settings (breaking)

- `Table.autoDBSettings` is now an `AutoDBSettings` with no library default. Declare it once per module with `extension Table { static var autoDBSettings: AutoDBSettings { .regular } }`, and override it per type or through a refined protocol.
- `SettingsKey`, `setAppSettings(_:for:)`, `appSettings(for:)` and `appDefaults` are removed: there is no runtime registration left, so nothing has to run before the first table is touched.
- New presets `AutoDBSettings.regular`, `.cache` and `.memory`. `.memory` is now really in memory, before it opened the default file.
- Settings resolving to the same file share one connection, the first one's options win and the mismatch is logged.
- `close()` skips in-memory databases.
- See "Migrating from SettingsKey" in [Documentation/Documentation.md](Documentation/Documentation.md#migrating-from-settingskey).

### Scopes and testing (breaking)

- `AutoDBManager(root:)` makes a manager whose files live under root. All state lives in the manager instance: connections, caches, changed objects, FTS and debounce state.
- `AutoDBManager.withScope(manager) { ... }` binds a manager for a task. Static calls use `AutoDBManager.current`, and models remember the manager they came from.
- New product `AutoDBTesting` with the Swift Testing trait `.autoDB`, which gives each suite its own databases so suites run in parallel. `AutoDBManager.testManager(_:)` makes the same per-suite managers without Swift Testing, for test targets where AutoDB is compiled into another library and AutoDBTesting can't be linked.
- `delete(_:_:)` with a type sets the table up first. With an `ObjectIdentifier`, a table that isn't set up throws `missingSetup` (or `noScope`) instead of waiting forever.
- `requireScope()` makes a manager throw `AutoError.noScope` instead of opening files, `storage(for:default:)` keeps per-manager singletons, and `fileURL(for:)` tells where settings put a file.
- `switchDB` is removed, use `.autoDB` or `withScope`.
- See "Scopes and testing" in [Documentation/Documentation.md](Documentation/Documentation.md#scopes-and-testing).

### Known limitations

- AutoDB does not infer column renames; rename-safe migrations must use the migration callback
- `RelationQuery` is not provided for older non-Observation Apple OS versions in 1.0
- Cross-platform targets outside Apple platforms are not part of the 1.0 support contract
- FTS requires SQLite FTS5 support

### Deferred goals

- Linux, Android, Windows, and WASI support
- Sync-specific product features such as built-in cascading sync systems

### Features that will not be implemented

- Lower deployment targets than the current package floor
- A separate older-OS `RelationQuery` implementation

### Adoption notes

- Start with the patterns in [README.md](README.md) and [Documentation/Adoption.md](Documentation/Adoption.md)
- Use raw SQL only when you intentionally want behavior outside AutoDB's save/observer pipeline
- Treat `swift test` as the release gate for package updates

### Versioning policy after 1.0

- Source-breaking API changes require a new major version
- Platform floor increases require a new major version
- Storage or migration behavior changes that require user code changes require a new major version
- Bug fixes that make runtime behavior match the documented 1.0 contract are treated as patch or minor releases, even if they change previously buggy behavior
