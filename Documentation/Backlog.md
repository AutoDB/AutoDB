# Post-1.0 Backlog

The items below are explicitly post-1.0 work. They are not part of the release contract described in [Roadmap.md](Roadmap.md) and [CHANGELOG.md](../CHANGELOG.md).

SQL
	- update hook when having fetch-lists in ManyRelation (as in RelationQuery)
	- remember our types for faster encoding of classes and performing queries. 
	- test all types
	- store Int/String enums as Int/String  

Relations:
	- RelationQuery is still Observation-only; build a separate implementation for older OS versions if that compatibility is needed
	- think through update hooks for query-backed lists when brand new rows should be inserted directly instead of discovered on the next fetch

# TODOs

## Memory pressure on Android/Linux

On Darwin the manager saves all changes when `DispatchSource.makeMemoryPressureSource` fires. That source doesn't exist on Android or Linux, so there low memory never flushes unsaved changes.

- Android: the signal is `ComponentCallbacks2.onTrimMemory` in Java/Kotlin, which Swift can't observe on its own. A likely shape is a public `AutoDBManager.handleMemoryWarning()` that calls `saveAllChanges()`, which the app (or a Skip bridge) calls from `onTrimMemory`.
- Linux: cgroup `memory.pressure` (PSI) could serve, if anyone asks for it.

Use String interpolation to build "WHERE name = \(name)" and support "FROM \(verbatim: table) WHERE name = \(name)"

Have a cleanup-function that can delete unused tables, or should we not care?

Should we adapt foreign-key constrains? 

For Table items, usually a BIG json downloaded from sources devs do not control. Would be nice if those could be auto-splitted into separate tables with foreign-key constrains. Now the related data needs to be json-data-struct or separated manually using a OneRelation. But how? 
- How about a special init when decoding, like SubType.init(superType). We can then decode the whole chain automatically and encode into different tables. But would require separate writes for each instance.

## Thinking

* Don't build cascading deletes and similar! Why?
* but think about syncing. Perhaps its a good idea to have some basic functionality for iCloud/Firebase sync?
	- No! Instead build generic methods people can post to whatever location is most suitable.
