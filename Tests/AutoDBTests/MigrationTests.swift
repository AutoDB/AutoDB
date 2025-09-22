//
//  MigrationTests.swift
//  AutoDB
//
//  Created by Olof Andersson-Thorén on 2024-12-10.
//

import Testing
import Foundation

@testable import AutoDB

struct MigFirst: Table {
	var id: AutoId = 1
}

struct MigIndex: Table {
	var id: AutoId = 1
	var toInt = 1	// a type converted from String to Int
	var plain = "plain"
	
	static var uniqueIndices: [[String]] { [["toInt"]] }
	static var indices: [[String]] { [["plain"]] }
	
	// create table with an extra column
	static var createTableSQL: String {
  	"""
  	CREATE TABLE IF NOT EXISTS "MigIndex" (
  	 `id` INTEGER NOT NULL DEFAULT 1,
  	 `plain` TEXT NOT NULL DEFAULT 'plain',
  	 `toInt` INTEGER NOT NULL DEFAULT 67,
  	 PRIMARY KEY (`id`));
  	"""
	}
}

struct Mig: Table {
	var id: AutoId = 1
	var toInt = 1	// a type converted from String to Int
	var plain = "plain"

	static var uniqueIndices: [[String]] { [["toInt"]] }
	static var indices: [[String]] { [["plain"]] }
	
	// create table with an extra column
	static var createTableSQL: String {
		"""
		CREATE TABLE IF NOT EXISTS "Mig" (
			`id` INTEGER NOT NULL DEFAULT 1,
			`plain_old` TEXT NOT NULL DEFAULT 'plain',
			`toInt` TEXT NOT NULL DEFAULT "not a number",
			PRIMARY KEY (`id`));
		"""
	}
	
	
	static func migration(_ token: AutoId?, _ db: isolated Database, _ state: MigrationState) async {
		
		if case let .changes(oldTableName, columns) = state {
			do {
				print("migrating from \(oldTableName)")
				// Note that existing data is untouched in the original table until migration is complete, then it is dropped and the new table renamed. This way you can inspect what you have, and migrate with peace of mind.
				for changedColumn in columns {
					if changedColumn.name == "plain_old" {
						print("renaming plain_old to plain")
						// we can't fetch OLD values with out new data structure, we have to use plain SQL-methods, but since we only want the id and the changed columns this is fairly straight forward.
						let oldValues = try await db.query(token: token, "SELECT id, plain_old FROM `\(oldTableName)`")
						for oldValue in oldValues {
							guard let old = oldValue["plain_old"]?.stringValue,
								  let id = oldValue["id"]?.uint64Value else {
								print("failed db!")
								// throw some error
								throw Database.Error.queryError(query: "SELECT id, plain_old FROM `\(oldTableName)`", description: "This can't happen, but somehow plain_old is null")
							}
							// normally you would also do some sort of type-conversion here, otherwise just renaming is unnecessary and moving data from old table to new is automatic (if names are the same).
							try await db.execute(token: token, "UPDATE Mig SET plain = ? WHERE id = ?", [old, id])
							
							// if only renaming, you would rather do something like this instead, keeping data inside SQLite makes things much faster:
							// let query = "UPDATE Mig as tb1 SET plain = (SELECT plain_old FROM `\(oldTableName)` as tb2 WHERE tb1.id = tb2.id) WHERE EXISTS (SELECT plain_old FROM `\(oldTableName)` as tb2 WHERE tb1.id = tb2.id);"
						}
						
						// note that columns with the same name is moved, but we need to do type-conversions (moving from Int to String is automatic, but the other way fails unless the String is "67" or similar).
						// Similarly, enums backed by plain numbers or strings can be auto-converted, Structs are also fine if keys have been removed, only optionals been added and nothing renamed.
						let newValues = try await db.query(token: token, "SELECT id, toInt FROM Mig")
						for newValue in newValues {
							
							guard let id = newValue["id"]?.uint64Value else {
								print("Missing id! This can't happen")
								continue
							}
							if newValue["toInt"]?.intValue == nil, let string = newValue["toInt"]?.stringValue {
								print("no int, old value was: \(string) (we need to convert)")
							}
							
							let old = newValue["toInt"]?.intValue ?? 67
							
							// normally you would also do some sort of type-conversion here, otherwise just renaming is unnecessary and moving data from old table to new is automatic (if names are the same).
							try await db.execute(token: token, "UPDATE Mig SET toInt = ? WHERE id = ?", [old, id])
						}
					}
				}
			}
			catch {
				print("failed converting column: \(error)")
			}
		}
	}
}

@Suite("Migration", .serialized)
class MigrationTests {
	
	@Test func createTable() async throws {
		
		/// First we create an "old" table that will be migrated.
		let db = try await MigFirst.db()
		try? await db.execute("DROP TABLE Mig")
		try await db.execute(Mig.createTableSQL)
		try await db.execute("INSERT INTO Mig (id, plain_old, toInt) VALUES (1, 'some test value', 'no number')")
		let thread = Task {
			let values = try await Mig.fetchQuery("WHERE id = 1")
			print(values.first?.id == 1)
			return values.first
		}
		// the task and this call will be competing for being the first to migrate. If semaphores ain't working columns will be added twice or other errors will be seen.
		_ = try await Mig.db()
		
		let first = try await thread.value
		
		// did it convert old values?
		#expect(first?.plain == "some test value")
		#expect(first?.toInt == 67)
	}
	
	
	// also test changing index!
	// 1. changedIndices does not work: it only addds, does not drop old.
	// let changedIndices = Set(indicesInDB).subtracting(targetIndices)
	//CREATE INDEX `plain_index` ON Mig (plain);
	@Test func dropUnusedIndexes() async throws {
		let db = try await MigFirst.db()
		try? await db.execute("DROP TABLE MigIndex")
		try await db.execute(MigIndex.createTableSQL)
		try await db.execute("INSERT INTO MigIndex (id, plain, toInt) VALUES (1, 'some test value', 2)")
		try await db.execute("CREATE INDEX removeThisIndex ON MigIndex (plain)")
		print("now:")
		let first = try await MigIndex.fetchId(1)
		#expect(first.toInt == 2)
	}
	
	@Test
	func FTSTableStringMapping() async throws {
		
		// when searching in dbs you want to remove diacretics so that "greve" matches "grevé". But you don't want to remove umlauts that defines completely different vowels - which can be hard to know if you are not familiar with the northern languages. Searching for "Öl" should never give hits on a word like "Olympiade" - there is no link between these words. Basically searching for "Bee" and getting hits on "Boo" - replacing a vowel seemingly at random.
		// Insead we normalize and replace all unicode strings into a decent normal mapping of regular letters kept but diacritics stripped.
		let regular = Set("äöåÖÄÅüÜ".precomposedStringWithCanonicalMapping)
		let out = "ëêéöäåøØæÆ".precomposedStringWithCanonicalMapping.map { regular.contains($0) ? $0 : String($0).folding(options: .diacriticInsensitive, locale: nil).first! }
		print(out)
		#expect(String(out) == "eeeöäåøØæÆ")
		
	}
}

