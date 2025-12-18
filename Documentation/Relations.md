# Relations

AutoDB supports the most common types of relations, one-to-one, one-to-many, and query. You model this by creating a relation-property in your Model class (it is possible to use Structs/Tables too but they have drawbacks you will see later).


## OneToMany

The typical example when you have one parent with many children. We want an API that looks like this:

```
var parent: Parent = await Parent.create(1) // or fetchId(1)
// we don't want the engine to auto-fetch any children, rather when the time is right we want to tell it to fetch:
try await parent.children.fetch()
// now you can loop through all children:
for child in parent.children.items {
	// do work
}
// normally, a list will change. E.g. If using SwiftUI keep fetching a


## OneToOne

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
