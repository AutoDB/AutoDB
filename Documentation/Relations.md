# Relations

Let's model a relationship. Imagine a list of AlbumArts and you want their respective Albums. Note that they could both be plain Table structs as well.

```
final class AlbumArt: Model, @unchecked Sendable {
	
	struct Value: Table {
		
		static let tableName = "AlbumArt"
		var id: AutoId = 0
		var data: Data? = nil
		
		// what album does this belong to?
		var album = OneRelation<Album>()
		
		static var autoDBSettings: SettingsKey {
			.cache
		}
	}
	
	var value: Value
	init(_ value: Value) {
		self.value = value
	}
	//shorthand
	var album: OneRelation<Album> { value.album }
}
```

```
final class Album: Model, @unchecked Sendable {
	
	struct Value: Table {
		
		var id: AutoId = 0
		var name = ""
		var artist = ""
		
		static let tableName = "Album"
	}
	
	var value: Value
	init(_ value: Value) {
		self.value = value
	}
	//shorthand
	var name: String { value.name }
}
```

You simply want to ask for the album: `art.album.name` but you also don't want it to make fetches without control, so we introduce the `OneRelation<TableModel>` class. Think of it as a property wrapper without hiding any functionality inside a property wrapper.

```

// fetch the related object, will throw if no object has been set:
let album = try await art.album.object
// check if the object is already fetched
art.album._object == nil
// create a relation to a new object, if the owner (art in this case) is of a Model type, then it will automatically be marked as modified.
await art.album.setObject(someAlbum)
// art has now changes and needs to be saved
AlbumArt.saveChangesLater()
// to speed up fetching, do all items in a list at once:
let arts = try await AlbumArt.fetchQuery()
try await arts.fetchAll(\.album)
