# AutoDB

Automatic persistence and database handling for Swift, built on SQLite to cross-compile. Fast, automatic migrations and thread safe.

## More to be announced...

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

