# Roadmap

## 1.0 scope

The 1.0 release target is:

- Swift Package only
- Apple-first support
- the current package deployment floor
- no cross-platform support promise
- no older non-Observation `RelationQuery` implementation

## Support matrix

| Surface | Support |
| --- | --- |
| Package platforms | macOS 14+, iOS 17+, tvOS 17+, watchOS 10+ |
| Tested regularly | macOS and iOS |
| `RelationQuery` | macOS 14+, iOS 17+, tvOS 17+, watchOS 10+ |
| Cross-platform targets | Out of scope for 1.0 |

## Stable in 1.0

- `Table` and `Model`
- automatic migrations
- cache-backed model identity
- uniqueness constraints
- batched saving
- transactions
- `ManyRelation` and `OneRelation`
- `FTSColumn`
- `RelationQuery` on supported Observation-capable OS versions

## 1.1 scope

Both come from one SwiftPM trait, `SQLCipher`, off by default. It builds AutoDB on [skip's swift-sqlcipher](https://github.com/skiptools/swift-sqlcipher) instead of the system SQLite, and Apple-only users who leave it off download nothing extra.

- Encryption with SQLCipher: `AutoDBSettings.encrypted(key:)` with a closure that fetches the key, automatic in-place encryption of existing files, and key changes. See [Encryption](Documentation.md#encryption).
- Android and Linux support: these need the trait, since there is no system SQLite to rely on. See [Cross-platform notes](Android.md).

| Surface | 1.1 support |
| --- | --- |
| Encryption | With the `SQLCipher` trait, on every platform |
| Linux | With the `SQLCipher` trait, tested in CI |
| Android | With the `SQLCipher` trait, tested in CI on an emulator |
| Windows, WASI | Not planned |