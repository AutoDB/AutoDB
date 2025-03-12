# AutoDB Swift

SQL
	- update hook when having fetch-lists in ManyRelation (as in RelationQuery)
	- remember our types for faster encoding of classes and performing queries. 
	- test all types

Creating index and changing column type does not work as expected!

Fetching
	- design other common SQL-functions like fetch row, value, etc.

# Known bugs / TODOs

Find a solution for temp-objects

# Thoughts

When fetchin a Table, we always get a new struct. So even if there is Model for this Table, there could potentially become a second one.

## Thinking

* Don't build cascading deletes and similar! Why?
* but think about syncing. Perhaps its a good idea to have some basic functionality for iCloud/Firebase sync?
