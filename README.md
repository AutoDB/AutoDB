# AutoDB

Automatic persistence and database handling in Swift, built on SQLite. AutoDB focuses on automatic migrations, cache-backed model identity, and async/await-friendly access patterns.

* Automatic conflict resulution: never have merge-conflicts by never having the same data in two places in the app that are not the same.
* Caching: don't fetch from DB data you already have fetched
* Uniqueness: when changing data in one place while showing it in several other views should immediately reflect those changes everywhere.
* Development speed: adding and removing values should just work, database should be updated automatically (automatic migrations).
* Speed: when working with large data sets the framework should help making it easy to coalesce changes into one disc-write. Removing unnecessary fetches also makes things a lot faster. Top it all off by doing everything with actors in background threads to utilize those extra cores in the most efficient way.
* More speed: Swift structs is a powerful feature that can make your app much faster, all data is handled by those while the more high-level features needs classes. This allows for having the pros of both, having the cake and eating it too!     

## Quick start

Implement the AutoDB.Model protocol for your classes holding data, and make them Sendable. Then add a containing struct with the data. It must have the `var id: AutoId` to handle identity. All its values must have a default value.
Note that the containing struct must have a unique name in the app.

```
final class Artist: Model, @unchecked Sendable {
	
	struct Value: Table {
		
		// define a type name, will be the table name in the database. This makes us free to call our types whaterver we want. You must do this if migrating from an existing database.
		public static var tableName: String { "Artist" }
		
		var id: AutoId = 0		 // all ids are of type UInt64, which makes it easy to handle uniqueness.
		var name: String = ""	 // we must have a default value
		var genre: String? = nil // another property, also with a default value
		... (all other properties)
	}
	
	var value: Value {
		didSet { didSet(oldValue) }	// automatic change tracking
	}
	init(_ value: Value) {
		self.value = value
	}
}
```

Create new objects:
``` 
let first = Artist.create() // use await if in async context
// Specify id if you don't want the system to assign one 
// let first = Artist.create(1)

first.name = "The Cure"
try first.save()
```

Fetch existing objects:
```
let artist = try await Artist.fetchQuery("WHERE name = ?", first.name).first
```
Note that these are the same object: `artist === first`

If automatic conflict resulution, caching and uniqueness is not desired, you can of-course use only the Table types (which can be structs). The Model must be a class for those features to work or make sense.

To have global settings for groups of instances, e.g to specify appGroup container:

```
let dbSettings = AutoDBSettings(path: "pathToDatabase.sqlite", iCloudBackup: true, inAppFolder: false)
AutoDBManager.shared.setAppSettingsSync(dbSettings, for: .regular)  
```

That is all! (basically, more discussion in the [Documentation](Documentation/Documentation.md)

## History

AutoDB was written for Objective-C around 2015 and made open source 2019, it was fast and automatic taking out all the pain of persistant storage for all your development needs. I built a lot of apps at that time, and needed something that never failed or had migration issues. I was also bored and was amazed by how great the Obj-C runtime really was (and still is). Swift wasn't capable enough in 2015, but since its release I wanted to re-implement AutoDB in Swift. Because of its type-system you need to re-implement many of the same functions over and over for each type, which made starting tideous and boring. Thankfully I found [Blackbird](https://github.com/marcoarment/Blackbird) in which most of that grunt-work was already done. So I just shamelessly copied the code and modified it to fit my existing SQL encoder/decoder for Swift-classes. It was all my ADHD needed to get going, and I quite quickly built a usable prototype.  


## Big thanks

Big thanks to Marco Armendt and his [Blackbird](https://github.com/marcoarment/Blackbird) from which I've copied a lot of the code.

## Status

AutoDB is still evolving, but the current package is test-backed and intended for real use on the platforms listed below. See [Backlog.md](Documentation/Backlog.md) for the remaining gaps and future work.

## Current support

- Package platforms: macOS 14+, iOS 17+, tvOS 13+
- Tested regularly: macOS and iOS
- `RelationQuery` currently depends on Observation availability, which means macOS 14+, iOS 17+, tvOS 17+, watchOS 10+ for that specific API surface
- Cross-platform targets outside Apple platforms remain planned work, not current release-ready support

## Details

Read the [Documentation.md](Documentation/Documentation.md) for more details.

For planned cross-platform work beyond the current Apple-focused package support, read [Android.md](Documentation/Android.md).

## Contact

Feel free to drop me a line at [autoDB@aggressive.se](mailto:autoDB@aggressive.se)


## Purpose

Since you are one of the very (lucky) few who will find this, you might ask why the hell would anyone go through all this trouble to build something everyone already has a solution for? Isn't GRDB great? Swift-data is just a line!

Reasons are multiple, but mainly:

1. Swift-data is built on CoreData which is horribly bad and error-prone. Nobody should use it for any use case you might think you have (I truly mean that from the bottom of my heart).
2. [GRDB](https://github.com/groue/GRDB.swift) is great but not automatic, you have to do migrations and you have to massage it to handle relationships and FTS etc.
3. There are a bunch of other great frameworks too, as the mentioned [Blackbird](https://github.com/marcoarment/Blackbird) but they all have their many flaws and shortcomings. I must be allowed to use Unsigned 64 bit integers for instance. And while macros and property wrappers are nice and all, they should be optional and not a built-in requirement inside a library.
4. 
