# AutoDB Swift

The purpose is to have a automatic system for handling persistance. Objects should be able to save and restore themselves and common headaches should be removed, like migration and uniqueness. A common platform for syncing that can be reused across apps can easier be built if there are common grounds.

## Quick start

Implement the AutoDB protocol for all your data classes, and make sure they are both Codable and Sendable. They must have the `var id: AutoId` to handle identity.

```
final class Artist: AutoDB, @unchecked Sendable {
	var id: AutoId = 0	// all ids are of type UInt64, which makes it easy to handle uniqueness.
	var name: String = ""	// we must have default values or nil
}
```

Create new objects:
``` 
let first = await Artist.create()
// Specify id if you don't want the system to assign one 
// let first = await Artist.create(1)

first.name = "The Cure"
try await first.save()
```

Fetch existing objects:
```
let artist = try await Artist.fetchQuery("WHERE name = ?", first.name).first
```
Note that these are the same object, `artist === first`

That is all!

# FastTextSearch

The system supports FTS-columns, which is a powerful way to search for text. Create a FTSColumn like tihs:

```
final class AnExample: AutoModel, @unchecked Sendable {
	var id: AutoId = 1
	var theText = ""
	var fts = FTSColumn<AnExample>("theText")
}
```

As you can see you must specify your own class as the generic type. This is because the type-system needs to know which class to index. Then the name of the column must be specified as a string. 

Now you can search like this, and all matching objects with that phrase will be returned:

```
let matches = try await FTSColumn<AnExample>.search("I love My" column: "theText")
```

A shorthand if you have an object is available:
```
let matches = try await anExampleObject.fts.search("I love My")
```
It will not use the anExampleObject for anything but to fill in the generic info the type system needs.

# Transactions

Transactions are supported, wrap your code in a closure where no calls may throw errors. If it does, DB-state is rolled back to its initial state. Like this:

```
try? await TransClass.db() { db in
	let first = await TransClass.create(1)
	first.integer = 2
	try await first.save()
	
	#expect(first.integer == 2)
	
	throw CancellationError()
}

// TransClass has no objects here, and none with integer == 2
```

## Write to DB in bulk

It is smarter to save many objects in one go, to mark an object to be saved for later call `artist.didChange()`. Later you can then save all those objects by calling `Artist.saveChanges()`. Note that the system will keep a reference to all objects waiting to be saved.

## Caching

Objects are cached with weak pointers, meaning that they will be deallocated when no one else is using them. During usage they will be returned when fetching from DB instead of recreated every time. 

## Migration

A common source of errors and hangs is migration. The system knows about current SQL-tables on disc, and handle migration automatically and efficiently by comparing with the data-classes. It handles adding and removing columns, and changing types (to some extent). If you change a String to Int it will work as long as the string can be an Int like "2", but "string" will of course not be a meaningful Int - so keep that in mind. For best result, never change your types. Instead, create new columns.
Migration is really fast and even if your tables have millions of rows it will probably not be noticable for the user.

NOTE: AutoDB cannot (yet) rename properties, if you change the name of a variable it will delete the old column and create a new one - potentially causing data loss.

## Uniqueness

When data has an identity, like for a user or specific items, it needs to be unique. Its easy to make mistakes when keeping track of unique objects in a large app. The system can do this for us automatically and in the same time also cache frequently used objects to make their access and usage faster. Changes in one view will then always be reflected by all other views that are using the same data with lightning speeds since no refetching from disc is needed.

# Overview

The system is built on top of SQLite and uses Codable to read and write data to objects.

All classes need to implement the AutoDB protocol. This in turn implements Codable, Hashable, Identifiable and Sendable. Since classes can't be Sendable (in practice) they have to be marked @unchecked Sendable. 

It is required that all classes have an init method with no parameters. This is needed to have default values for all properties.

# API Considerations

Normally when working with database frameworks and managers, you end up with a lot of type-casting and similar annoyances. AutoDB preserves types so that fetching can be done as follows:

	let list = try await DataClass.fetchQuery("WHERE goals > 2")
	// list is of type [DataClass] where all have goals > 2 (or is empty).

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
