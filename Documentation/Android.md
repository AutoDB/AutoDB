# Linux / Android / Windows 

Cross-platform support outside Apple platforms is a goal for 1.1, not current release-ready functionality. The direction is to avoid hard dependencies on ObjC-only system layers and keep the core database layer portable.

## Building

Android and Linux have no system SQLite to rely on (the Android NDK doesn't expose one), so they need the `SQLCipher` trait, which brings SQLite with SQLCipher and FTS5 from [skip's swift-sqlcipher](https://github.com/skiptools/swift-sqlcipher):

```swift
.package(url: "https://github.com/AutoDB/AutoDB", from: "1.1.0", traits: ["SQLCipher"])
```

Locally: `swift build --swift-sdk <android or linux sdk> --traits SQLCipher`. Without the trait a non-Apple build stops with an `#error` that says so. Apple-only apps don't enable it and download nothing extra.

## Current state

- The library compiles for Linux (static musl SDK). CI builds and runs the tests on Linux and on an Android emulator.
- macOS and iOS are still the platforms with regular test coverage.
- Combine is Apple-only: `ObservableObject` support is left out elsewhere, Observation works everywhere.
- Low-memory saves are Darwin-only. Off Darwin, unsaved changes are not flushed on memory pressure, see the [Backlog](Backlog.md).
- File locations come from `FileManager`'s Application Support and Caches folders, which derive from `HOME`. Skip apps set this up. A plain NDK app may have no usable `HOME`: create your manager with `AutoDBManager(root: filesDir)`.
