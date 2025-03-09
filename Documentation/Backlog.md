# AutoDB Swift

SQL
	- update hook when having fetch-lists in AutoRelation (as in RelationQuery)
	- remember our types for faster encoding of classes and performing queries. 
	- test all types

Creating index and changing column type does not work as expected!

Fetching
	- design other common SQL-functions like fetch row, value, etc.

Support for Structs, when you don't need/want auto collision handling but rather just want to handle a huge table of data efficiently (but still automatic in other ways).  

- remove ignoreProperties since we are using codable now.

# That is all!

## Thinking

* Don't build cascading deletes and similar! Why?
* but think about syncing. Perhaps its a good idea to have some basic functionality for iCloud/Firebase sync?
