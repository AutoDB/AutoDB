# AutoDB Swift

The purpose is to have a automatic system for handling persistance. Objects should be able to save and restore themselves and common headaches should be removed, like migration and uniqueness. A common platform for syncing that can be reused across apps can easier be built if there are common grounds.

## Quick start

See the [README](/README.md).

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

# Transactions

Transactions are supported, wrap your code in a closure where no calls may throw errors. If it does, DB-state is rolled back to its initial state. Like this:

```
try? await TransClass.transaction { _, token in
	let first = await TransClass.create(token: token, 1)
	first.integer = 2
	try await first.save(token: token)
	
	#expect(first.integer == 2)
	
	// any error will cause rollback
	throw CancellationError()
}

// TransClass has no objects here, and none with integer == 2
// All other calls to db will await until this point where the transaction is done.
```

Note that the use of "token" is required until Swift 6.3, but will be removed in a future update. At least until 6.3 has been out for a while and time to implement this has conjoured itself into existence. 

## Deadlocks with transactions

Transactions can deadlock since they are guarded by semaphores. See `TransactionTests.deadlockSemaphore()` for detailed info and how to discover these. 

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

NOTE: AutoDB cannot (yet) rename properties, if you change the name of a variable it will delete the old column and create a new one - potentially causing data loss.

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
