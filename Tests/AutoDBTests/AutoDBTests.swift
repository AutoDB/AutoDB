import XCTest
@testable import AutoDB
import Foundation


struct ExampleInit: Table {
	var id: AutoId = 0
	let something: Int
	init() {
		something = 2
	}
}

class Resource {
	static let resourcePath = "./Tests/Resources"
	
	let name: String
	let type: String
	
	init(name: String, type: String) {
		self.name = name
		self.type = type
	}
	
	var path: String {
		guard let path: String = Bundle(for: Swift.type(of: self)).path(forResource: name, ofType: type) else {
			let filename: String = type.isEmpty ? name : "\(name).\(type)"
			return "\(Resource.resourcePath)/\(filename)"
		}
		return path
	}
}

	/*
	 There are many things you are thinking about some are already solved! Do them one at a time by building tests
	 1. How to generate SQL types from an empty object. (solved)
	 2. How to exclude properties you don't want (for now just a list of names in the settings object, or codable)
	 3. How to do generic fetching (solved?)
	 4. Creating and filling an object from DB. (using codable)
	 5. Storing object to DB. (using codable)
	 6. How to track changes - we can't => instead just have a hasChanges variable and if set call into manager to add you to the list.
	 
	 Rules:
	 Codable is a must
	 We can't use @PropertyWrappers
	 We don't want to piggy-back on any other system like Combine, FMDB, GRDB etc.
	 
	 */

@available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, *)
final class AutoDBTests: XCTestCase {
	
	static override func setUp() {
		AutoLog.setup()
	}
	
	static let resourcePath: String = {
		let path = "./Tests/Resources"
		let manager = FileManager.default
		if manager.fileExists(atPath: path) == false {
			do {
				try manager.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: nil)
			} catch {
				print("Could not create resources folder: \(error.localizedDescription)")
			}
		}
		return path
	}()
	
	// generic fetching, an object should be created, inserted into the DBManager and be fetched as long as it exists there.
	func testStoring() async throws {
		
		var instance = await BaseClass.create(1)
		instance.anOptInt = 99
		try await instance.save()
		
		let item = try await BaseClass.fetchId(1)
		XCTAssertEqual(item, instance)
		//item.anOptInt = 6
		XCTAssertEqual(item.anOptInt, instance.anOptInt)
	}
	
	func testInit() async throws {
		
		try await ExampleInit.create(12).save()
		let some = try await ExampleInit.fetchId(12)
		XCTAssertEqual(some.something, 2)
	}
	
	func testEqualModelClasses() async throws {
		let lhs = await DataAndDate.create(1)
		let rhs = await DataAndDate.create(1)
		XCTAssertEqual(lhs, rhs)
		
		lhs.dubDub = 2
		rhs.dubDub = 4
		XCTAssertNotEqual(lhs, rhs)
		
		lhs.dubDub = 4
		XCTAssertEqual(lhs, rhs)
	}
	
	func testDecodable() throws {
		
		//let expect = XCTestExpectation(description: "expect")
		let testInt = 4
		let base = DataAndDate()
		base.id = UInt64(testInt)
		base.intPub = testInt
		
		let encoded = try JSONEncoder().encode(base)
		let string = String(data: encoded, encoding: .utf8)!
		print(string)
		let decoded = try JSONDecoder().decode(DataAndDate.self, from: encoded)
		
		XCTAssertEqual(decoded.id, UInt64(testInt), "Id didn't work")
		XCTAssertEqual(decoded.intPub, testInt, "regular int")
	}
	
	func testObservedDecodable() async throws {
		
		let base = await ObserveBasic.create(2)
		base.string = "my own little string"
		base.optString = "not null!"
		
		let encoded = try JSONEncoder().encode(base)
		let string = String(data: encoded, encoding: .utf8)!
		print(string)
		let decoded = try JSONDecoder().decode(ObserveBasic.self, from: encoded)
		
		XCTAssertEqual(decoded.string, base.string, "Id didn't work")
	}
	
	// then when saving, we use encoder and get an array of encodable values. Then just encode each blob to data, and let the rest become mappings to Sqlite.
	func testEncodingToDB() async throws {
		
		let db = try await ObserveBasic.db()
		try await ObserveBasic.truncateTable()
		
		let base = await ObserveBasic.create(2)
		base.optString = "base 2"
		let base3 = await ObserveBasic.create(3)
		base3.optString = "base 3"
		
		// this is basically the save function
		let encoder = await SQLRowEncoder(ObserveBasic.self)
		try base.encode(to: encoder)
		try base3.encode(to: encoder)
		try await encoder.commit(update: false)
		
		var row = try await db.query("SELECT optString FROM ObserveBasic WHERE id = 2").first!
		var value = row.first!.value.stringValue
		XCTAssertEqual(value, base.optString)
		
		row = try await db.query("SELECT optString FROM ObserveBasic WHERE id = 3").first!
		value = row.first!.value.stringValue
		XCTAssertEqual(value, base3.optString)
	}
	
	@available(macOS 15.0, *)
	func testDecodeInts() async throws {
		let values:[String : SQLValue] = [
			"id": try SQLValue.fromAny(UInt64.max),
			"integer": try SQLValue.fromAny(Int.min),
			"integer32": try SQLValue.fromAny(Int32.min),
			"integer16": try SQLValue.fromAny(UInt16.max),
			"integer8": try SQLValue.fromAny(Int8.min),
			"integeru8": try SQLValue.fromAny(UInt8.max),
		]
		
		let db = try await IntTester.db()
		let table = await AutoDBManager.shared.tableInfo(IntTester.self)
		
		let decoder = SQLRowDecoder(IntTester.self, table, values)
		let base = try IntTester(from: decoder)
		
		XCTAssertEqual(base.integer, .min)
		XCTAssertEqual(base.integer32, .min)
		XCTAssertEqual(base.integer16, .max)
		XCTAssertEqual(base.integer8, .min)
		XCTAssertEqual(base.integeru8, .max)
		XCTAssertEqual(base.id, .max)
		
		let now = Date()
		//await db.setDebug()
		let id = AutoId.max - 3
		try await db.query("INSERT OR REPLACE INTO IntTester (id, time, integer) VALUES (?, ?, ?)", [id, now.timeIntervalSince1970, Int.min])
		let next = try await IntTester.fetchId(id)
		XCTAssertEqual(next.integer, .min)
		XCTAssertEqual(next.time?.timeIntervalSince1970, now.timeIntervalSince1970)
		XCTAssertEqual(next.id, id)
	}
	
	@available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, *)
	func testTableGeneration() async throws {
		
		// test that values get copied correctly when changing column types
		let db = try await AutoDBManager.shared.initDB(AutoDBSettings())
		try await AutoDBManager.shared.truncateTable(Mod.self)
		try await db.query("CREATE TABLE IF NOT EXISTS Mod (`id` INTEGER NOT NULL DEFAULT 0,`removeColumn` INTEGER NOT NULL DEFAULT 0,`bigInt` TEXT NOT NULL DEFAULT 0, `string` INTEGER NOT NULL DEFAULT 0,PRIMARY KEY (`id`));")
		try await db.query("INSERT INTO Mod (id, string, bigInt) VALUES (1, 2, -1)")
		
		try await Mod.db()
		
		let row = try await db.query("SELECT string, bigInt from Mod where id = 1").first!
		
		let stringColumn = row["string"]!
		XCTAssertEqual(stringColumn.intValue, 2)
		XCTAssertEqual(stringColumn.stringValue, "2")
		
		let bigInt = row["bigInt"]!
		XCTAssertEqual(bigInt.intValue, -1)
		XCTAssertEqual(bigInt.stringValue, "-1")
		XCTAssertEqual(bigInt.uint64Value, 18446744073709551615)
		
		let double: Double = -1
		let intConvert = Int64(double)
		XCTAssertEqual(UInt64(bitPattern: intConvert), UINT64_MAX)
		
		// now fetch a regular object!
		let mod = try await Mod.fetchId(1)
		XCTAssertEqual(mod.string, "2")
	}
	
	func lookupObjectsCount(_ typeName: ObjectIdentifier, _ expectedCount: Int, _ message: String) async {
		
		let count = await AutoDBManager.shared.lookupObjectsCount(typeName)
		XCTAssertEqual(count, expectedCount, message)
	}
	
	func test_fetching_api() async throws {
		
		let db = try await BaseClass.db()
		try await db.query("DELETE FROM BaseClass")
		
		let first = await BaseClass.create(1)
		let second = await BaseClass.create(2)
		try await [first, second].save()
		
		let list = try await BaseClass.fetchQuery().dictionary()
		
		//The actual point here is that list is of type [BaseClass]? and not AutoModel, or any protocol.
		XCTAssertEqual(list.count, 2, "Fail to fetch all items!")
		let got = list[AutoId(1)]
		XCTAssertNotNil(got)
		XCTAssertNil(got?.anOptInt)	//this should compile
		try await list.values.save()
	}
	
	func testBasicQuery() async throws {
		
		let query = "SELECT 'Apa' as animal, 1 + ? as math"
		let list = try await BaseClass.query(query, [UInt64(2)])
		print(list.count)
		for (key, value) in list.first ?? [:] {
			print("l: \(key): \(value)")
		}
		let row = list.first!
		XCTAssertEqual(row["math"]?.intValue, 3)
		
		let maxInt = UInt64.max
		let signed = Int64(bitPattern: maxInt)
		XCTAssert(UInt64(bitPattern: signed) == maxInt)
		
		let maxIntInt = Int(bitPattern: UInt(maxInt))
		XCTAssert(UInt(bitPattern: maxIntInt) == maxInt)
	}
	
	@available(macOS 15.0, *)
	func testObserveWithoutCodingKeys() async throws {
		try await AutoDBManager.shared.truncateTable(Artist.Value.self)
		
		let first = await Artist.create(1)
		first.value.name = "The Cure"
		try await first.save()
		
		let artist = try await Artist.fetchQuery("WHERE name = ?", [first.value.name]).first
		XCTAssertEqual(artist, first)
		XCTAssertTrue(artist === first)
		
	}
	
	func testWithCodingKeys() async throws {
		try await AutoDBManager.shared.truncateTable(CodeWithKeys.self)
		
		var first:CodeWithKeys? = await CodeWithKeys.create(1)
		first?.name = "The Cure"
		first?.otherNest = Nested(name: "some name")
		try await first?.save()
		first = nil
		
		let artist = try await CodeWithKeys.fetchQuery("WHERE somethingElse = ?", ["The Cure"]).first
		XCTAssertNotNil(artist)
		XCTAssertNotNil(artist?.nest)
		
		// works with both default types and setting your own
		XCTAssertEqual(artist?.nest, Nested(name: "kurt"))
		XCTAssertEqual(artist?.otherNest, Nested(name: "some name"))
	}
	
	// We can't have relations from structs, 
	func testRelations() async throws {
		try await AutoDBManager.shared.truncateTable(Parent.Value.self)
		try await AutoDBManager.shared.truncateTable(Child.self)
		
		var item: Parent? = await Parent.create(1)
		try await item?.value.children.fetch()
		
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.prettyPrinted]
		
		if let item, item.value.children.items.isEmpty {
			item.value.name = "Olof"
			
			var gunnar = await Child.create()
			gunnar.name = "Gunnar"
			var bertil = await Child.create()
			bertil.name = "Bertil"
			await item.value.children.append([gunnar, bertil])
			
			// we must save these separately
			try await item.value.children.items.save()
			try await item.save()
		} else {
			XCTAssertTrue(item != nil)
			XCTAssertTrue(item?.value.children.items.isEmpty == false)
			XCTAssertEqual(item?.value.children.items.first?.name, "Gunnar")
			XCTAssertEqual(item?.value.children.items.last?.name, "Bertil")
		}
		item = nil
		await Task.yield()
		
		let children = try await Child.fetchQuery()
		XCTAssertEqual(children.count, 2)
		
		let parent = try await Parent.fetchQuery("WHERE name = ?", ["Olof"]).first!
		XCTAssertNotNil(parent.value.children)
		
		let data = try encoder.encode(parent.value.children)
		print(String(data: data, encoding: .utf8)!)
		
		try await parent.value.children.fetch()
		
		XCTAssertEqual(parent.value.children.items.first?.name, "Gunnar")
		XCTAssertEqual(parent.value.children.items.last?.name, "Bertil")
		
		XCTAssertNotNil(parent.value.children.owner)
	}
	 
	func testOneRelationMultipleDBs() async throws {
		let mainDB = try await ObserveBasic.db()
		try await mainDB.query("DROP TABLE IF EXISTS AlbumArt")
		try await mainDB.query("DROP TABLE IF EXISTS Album")
		
		let cacheDB = try await AlbumArt.db()
		try await AlbumArt.query("DELETE FROM AlbumArt")
		await Album.queryNT("DELETE FROM Album")
		
		var faith = await Album.create()
		faith.name = "Faith"
		try await faith.save()
		
		let id: AutoId = 4
		var art: AlbumArt? = await AlbumArt.create(id)
		//let id = art!.id
		await art?.value.album.setObject(faith)
		try await art?.save()
		print("art: \(art!.value.album.id)")
		art = nil
		await Task.yield()
		
		let artObj = try await AlbumArt.fetchId(id)
		print("artObj: \(artObj.id) \(artObj.value.album.id)")
		
		if try await artObj.value.album.object != faith {
			throw AutoError.missingRelation
		}
		
		XCTAssertTrue(artObj.value.album._object == faith)
		XCTAssertFalse(mainDB === cacheDB)
		
		// make sure we have two files with different tables:
		let q = "SELECT name FROM sqlite_master WHERE type='table';"
		let result = try await mainDB.query(q)
		for rows in result {
			XCTAssertFalse(rows.values.contains { $0.stringValue == "AlbumArt" })
		}
		let cacheRes = try await cacheDB.query(q).compactMap({ $0.values.first })
		XCTAssertTrue(cacheRes.contains { $0.stringValue == "AlbumArt" })
	}
	
	/// two tables have separate actors, test that we can read and write at the same time without crashing.
	/// Notice that two actors doing writes are slower than one actor.
	@available(macOS 15.0, *)
	func testMultipleReadWrites() async throws {
		//let main =
		try await IntTester.db()
		//await main.setDebug()
		let other = try await ObserveBasic.db()
		//await other.setDebug()
		
		try await other.query("DELETE FROM IntTester")
		try await other.query("DELETE FROM ObserveBasic")
		
		let waiter = expectation(description: "multi")
		let firstIteration = expectation(description: "firstIteration")
		let observeBasicChunk = expectation(description: "observeBasicChunk")
		let lastIteration = expectation(description: "lastIteration")
		let firstIterations = 2000
		let maxIterations = 4000
		Task {
			for index in 1..<firstIterations {
				let item = await IntTester.create(AutoId(index))
				item.integer = index
				do {
					try await item.save()
				} catch {
					print(error.localizedDescription)
					XCTFail("Error here!")
				}
			}
			print("first chunk is saved")
			firstIteration.fulfill()
		}
		
		// unrelated saves that locks the DB-file
		Task {
			for index in 1..<maxIterations {
				let item = await ObserveBasic.create(AutoId(index))
				item.optString = "\(index)"
				do {
					try await item.save()
				} catch {
					print(error.localizedDescription)
					XCTFail("Error here!")
				}
			}
			print("ObserveBasic chunk is saved")
			observeBasicChunk.fulfill()
		}
		
		Task {
			for index in firstIterations..<maxIterations {
				try await other.query("INSERT INTO IntTester (id, integer) VALUES(?, ?)", [index, index])
				//print("saved \(index)")
			}
			print("second chunk is saved")
		}
		
		Task {
			for index in 1..<maxIterations {
				
				var item: IntTester? = nil
				while item == nil || item!.integer == 0 {
					item = try? await IntTester.fetchId(AutoId(index))
					if item == nil {
						try await Task.sleep(for: .microseconds(10))
					}
				}
				//print("A got \(index)")
				XCTAssertTrue(item?.integer == index)
			}
			lastIteration.fulfill()
		}
		
		Task {
			for index in 1..<maxIterations {
				var item: Int? = nil
				while item == nil || item! == 0 {
					item = try? await other.query("SELECT integer FROM IntTester WHERE id = ?", [index]).first?.values.first?.intValue
					if item == nil {
						try await Task.sleep(for: .microseconds(10))
					}
				}
				//print("B got \(index)")
				let result = item == index
				XCTAssertTrue(result, "\(index) was \(item!)")
			}
			waiter.fulfill()
		}
		
		await fulfillment(of: [waiter, observeBasicChunk, firstIteration, lastIteration])
	}
	
	func testCreateWithExistingId() async throws {
		try await AutoDBManager.shared.truncateTable(UniqueString.Value.self)
		
		let item = await UniqueString.create(1)
		item.string = "Test"
		try await item.save()
		
		let fetched = try await UniqueString.fetchId(1)
		XCTAssertEqual(fetched.string, "Test")
		
		let newItem = await UniqueString.create(1)
		newItem.string = "New Test"
		try await newItem.save()
		
		let updated = try await UniqueString.fetchId(1)
		XCTAssertEqual(updated.string, "New Test")
		
		XCTAssertTrue(updated === fetched) // they should be the same object
		
		let duplicateItem = await UniqueString.create()
		duplicateItem.string = "New Test"
		
		do {
			try await duplicateItem.save()
			XCTFail("Expected an error when saving a duplicate id")
		} catch AutoError.uniqueConstraintFailed(let ids) {
			print("Caught uniqueConstraintFailed error with ids: \(ids)")
			XCTAssertTrue(ids.contains(1), "Expected id 1 to be in the unique constraint error")
		}
	}
}


