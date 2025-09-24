# AutoDB Swift

SQL
	- update hook when having fetch-lists in ManyRelation (as in RelationQuery)
	- remember our types for faster encoding of classes and performing queries. 
	- test all types
	- store Int/String enums as Int/String  

Creating index and changing column type does not work as expected!

# Known bugs / TODOs

Find a solution for temp-objects:
	Use Structs and don't save them.
	
Have a cleanup-function that can delete unused tables, or should we not care?

For Table items, usually a BIG json downloaded from sources devs do not control. Would be nice if those could be auto-splitted into separate tables with foreign-key constrains. Now the related data needs to be json-data-struct or separated manually using a OneRelation.

But how? 
- How about a special init when decoding, like SubType.init(superType). We can then decode the whole chain automatically and encode into different tables. But would require separate writes for each instance.

## Thinking

* Don't build cascading deletes and similar! Why?
* but think about syncing. Perhaps its a good idea to have some basic functionality for iCloud/Firebase sync?
	- No! Instead build generic methods people can post to whatever location is most suitable.
