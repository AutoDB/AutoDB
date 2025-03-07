# AutoDB

#Big change, TODO:

We will move all AutoModel to structs. Then we can auto-handle all updates on the db, and refresh when/if needed. No struct will be cached, since value-type.
On top we built the AutoModelObject which holds these structs. It has identity and can be cached. If you don't need classes, you get the pros of structs, but when you do you get the pros of classes. This way we can also auto-detect changes by keeping the original struct and calling didSet.   


Automatic persistence and database handling for all platforms in Swift, built on SQLite. Fast, automatic migrations and thread safe using actors and async/await. 

## Quick start

Implement the AutoDB protocol for your data classes, making them both Codable and Sendable. Then add the `var id: AutoId` to handle identity. All types must have a default value.

```
final class Artist: AutoDB, @unchecked Sendable {
	var id: AutoId = 0	// all ids are of type UInt64, which makes it easy to handle uniqueness.
	var name: String = ""	// we must have a default value (or nil)
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
Note that these are the same object: `artist === first`

That is all!

## History

AutoDB was written for Objective-C around 2015 and made open source 2019, it was fast and automatic taking out all the pain of persistant storage for all your development needs. I built a lot of apps at that time, and needed something that never failed or had migration issues. I was also bored and was amazed by how great the Obj-C runtime really was (and still is). Swift wasn't capable enough in 2015, but since its release I wanted to re-implement AutoDB in Swift. Because of its type-system you need to re-implement many of the same functions over and over for each type, which made starting tideous and boring.  Thankfully I found [Blackbird](https://github.com/marcoarment/Blackbird) in which most of that grunt-work was already done. So I just shamelessly copied the code and modified it to fit my existing SQL encoder/decoder for Swift-classes. It was all my ADHD needed to get going, and I quite quickly built a usable 


## Big thanks

Big thanks to Marco Armendt and his [Blackbird](https://github.com/marcoarment/Blackbird) from which I've copied a lot of the code. If you want your data to be structs and are ok with property wrappers, it is a good alternative to AutoDB with basically the same mindset.

## Status

This is currently a work in progress. Everything is implemented and working, more test-cases are needed. See [Backlog.md](Documentation/Backlog.md) for things to be built.

## Details

Read the [Documentation.md](Documentation/Documentation.md) for more details.

All platforms are/will be supported by AutoDB, read more in [Android.md](Documentation/Android.md).

## Contact

Feel free to drop me a line at [autoDB@aggressive.se](mailto:autoDB@aggressive.se)

---

## Contributing

Use the library and tell me about it! That contributes the most.

If you find any bugs I will gladly fix those, but I need an test-case, code example or something so that I can reproduce the issue.

## Purpose

Since you are one of the very (lucky) few who will find this, you might ask why the hell would anyone go through all this trouble to build something everyone already has a solution for? Isn't GRDB great? Swift-data is just a line!

Reasons are multiple, but mainly:

1. Swift-data is built on CoreData which is horribly bad and error-prone. Nobody should use it (I truly mean that from the bottom of my heart).
2. [GRDB](https://github.com/groue/GRDB.swift) is great but not automatic, you have to do migrations and you have to massage it to handle relationships and FTS etc.
3. There are a bunch of other great frameworks too, as [Blackbird](https://github.com/marcoarment/Blackbird) but they all have their many flaws and shortcomings. I must be allowed to use Unsigned 64 bit integers for instance. And while property wrappers are nice and all, they should be optional and not a built-in requirement inside a library. Same goes for Macros.

