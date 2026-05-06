# Adoption Guide

This guide covers the canonical 1.0 integration path for AutoDB.

## 1. Model a `Table` and a `Model`

Use a `Table` struct for the stored columns and a `Model` class when you want cache-backed identity, relations, and batched saves.

```swift
import AutoDB

final class Artist: Model, @unchecked Sendable {
	struct Value: Table {
		static let tableName = "Artist"

		var id: AutoId = 0
		var name = ""
		var genre = ""
	}

	var value: Value {
		didSet { didSet(oldValue) }
	}

	init(_ value: Value) {
		self.value = value
	}
}
```

## 2. Configure database settings

Most apps should set package-wide defaults once during startup.

```swift
let settings = AutoDBSettings(path: "AutoDB/App.sqlite")
AutoDBManager.shared.setAppSettings(settings, for: .regular)
```

If a specific table should live in a different file, override `autoDBSettings` on that `Table`.

## 3. Persist and fetch models

```swift
let artist = await Artist.create()
artist.value.name = "The Cure"
artist.value.genre = "Goth/Pop"
try await artist.save()

let fetched = try await Artist.fetchId(artist.id)
```

While the model remains retained, `fetched === artist`.

## 4. Use relations intentionally

Use `OneRelation` for parent-style references and `ManyRelation` for ordered child lists. Use RelationQuery when the relation can be described in a query, like "all Albums with genre X".

```swift
final class AlbumArt: Model, @unchecked Sendable {
	struct Value: Table {
		static let tableName = "AlbumArt"

		var id: AutoId = 0
		var title = ""
		var artist = OneRelation<Artist>()
	}

	var value: Value {
		didSet { didSet(oldValue) }
	}

	init(_ value: Value) {
		self.value = value
	}
}
```

```swift
let art = await AlbumArt.create()
await art.value.artist.setObject(artist)
try await art.save()

let fetchedArt = try await AlbumArt.fetchId(art.id)
let relatedArtist = try await fetchedArt.value.artist.object
```

`RelationQuery` is available only on Observation-capable OS versions in the 1.0 release.

## 5. Add full-text search when you need ranked search

```swift
final class Post: Model, @unchecked Sendable, FTSCallbackOwner {
	struct Value: Table {
		static let tableName = "Post"

		var id: AutoId = 0
		var title = ""
		var body = ""
	}

	var value: Value {
		didSet { didSet(oldValue) }
	}

	var searchIndex = FTSColumn<Value>("searchIndex")

	init(_ value: Value) {
		self.value = value
	}

	static func textCallback(_ ids: [AutoId]) async -> [AutoId: String] {
		let posts = (try? await Value.fetchIds(ids)) ?? []
		return Dictionary(uniqueKeysWithValues: posts.map { post in
			(post.id, "\(post.title) \(post.body)")
		})
	}
}
```

```swift
let matches = try await post.searchIndex.search("once upon a time")
```

## 6. Know the 1.0 boundaries

Do rely on:

- automatic migration for additive/removal changes and compatible conversions
- cache-backed model identity
- explicit transaction support
- relation fetch/save behavior on the supported Apple OS versions
- FTS search/update/delete behavior when SQLite has FTS5 enabled

Do not rely on:

- automatic rename inference during migration
- support below the package deployment floor
- Linux, Android, Windows, or WASM support in 1.0
- `RelationQuery` on older non-Observation OS versions
- raw SQL writes automatically triggering AutoDB-managed save semantics unless you deliberately use the observer/query hooks directly
