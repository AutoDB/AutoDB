import Testing
@testable import AutoDB
import Foundation

struct ExampleInit: Table {
	static let autoDBSettings = TestDatabase.autoDB
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

@Suite(.serialized)
final class AutoDBTests {
	
	private static let logSetup: Void = AutoLog.setup()
	
	init() {
		_ = Self.logSetup
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
	@Test func testStoring() async throws {
		
		var instance = await BaseClass.create(1)
		instance.anOptInt = 99
		try await instance.save()
		
		let item = try await BaseClass.fetchId(1)
		#expect(item == instance)
		//item.anOptInt = 6
		#expect(item.anOptInt == instance.anOptInt)
	}
	
	@Test func testInit() async throws {
		
		try await ExampleInit.create(12).save()
		let some = try await ExampleInit.fetchId(12)
		#expect(some.something == 2)
	}
	
	@Test func testEqualModelClasses() async throws {
		let lhs = await DataAndDate.create(1)
		let rhs = await DataAndDate.create(1)
		#expect(lhs == rhs)
		
		lhs.dubDub = 2
		rhs.dubDub = 4
		#expect(lhs != rhs)
		
		lhs.dubDub = 4
		#expect(lhs == rhs)
	}
	
	@Test func testDecodable() throws {
		
		let testInt = 4
		let base = DataAndDate()
		base.id = UInt64(testInt)
		base.intPub = testInt
		
		let encoded = try JSONEncoder().encode(base)
		let string = String(data: encoded, encoding: .utf8)!
		print(string)
		let decoded = try JSONDecoder().decode(DataAndDate.self, from: encoded)
		
		#expect(decoded.id == UInt64(testInt), "Id didn't work")
		#expect(decoded.intPub == testInt, "regular int")
	}
	
	@available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, *)
	@Test func testObservedDecodable() async throws {
		
		let base = await ObserveBasic.create(2)
		base.string = "my own little string"
		base.optString = "not null!"
		
		let encoded = try JSONEncoder().encode(base)
		let string = String(data: encoded, encoding: .utf8)!
		print(string)
		let decoded = try JSONDecoder().decode(ObserveBasic.self, from: encoded)
		
		#expect(decoded.string == base.string, "Id didn't work")
	}
	
	// then when saving, we use encoder and get an array of encodable values. Then just encode each blob to data, and let the rest become mappings to Sqlite.
	@available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, *)
	@Test func testEncodingToDB() async throws {
		
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
		#expect(value == base.optString)
		
		row = try await db.query("SELECT optString FROM ObserveBasic WHERE id = 3").first!
		value = row.first!.value.stringValue
		#expect(value == base3.optString)
	}
	
	@available(macOS 15.0, iOS 17.0, tvOS 17.0, watchOS 10.0, *)
	@Test func testDecodeInts() async throws {
		let values: [String: SQLValue] = [
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
		
		#expect(base.integer == .min)
		#expect(base.integer32 == .min)
		#expect(base.integer16 == .max)
		#expect(base.integer8 == .min)
		#expect(base.integeru8 == .max)
		#expect(base.id == .max)
		
		let now = Date()
		//await db.setDebug()
		let id = AutoId.max - 3
		try await db.query("INSERT OR REPLACE INTO IntTester (id, time, integer) VALUES (?, ?, ?)", [id, now.timeIntervalSince1970, Int.min])
		let next = try await IntTester.fetchId(id)
		#expect(next.integer == .min)
		#expect(next.time?.timeIntervalSince1970 == now.timeIntervalSince1970)
		#expect(next.id == id)
	}
	
	@available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, *)
	@Test func testTableGeneration() async throws {
		
		// test that values get copied correctly when changing column types: create an "old" Mod table in the same file before its own setup runs
		let db = try await BaseClass.db()
		_ = try? await db.execute("DROP TABLE Mod")
		try await db.query("CREATE TABLE Mod (`id` INTEGER NOT NULL DEFAULT 0,`removeColumn` INTEGER NOT NULL DEFAULT 0,`bigInt` TEXT NOT NULL DEFAULT 0, `string` INTEGER NOT NULL DEFAULT 0,PRIMARY KEY (`id`));")
		try await db.query("INSERT INTO Mod (id, string, bigInt) VALUES (1, 2, -1)")
		
		try await Mod.db()
		
		let row = try await db.query("SELECT string, bigInt from Mod where id = 1").first!
		
		let stringColumn = row["string"]!
		#expect(stringColumn.intValue == 2)
		#expect(stringColumn.stringValue == "2")
		
		let bigInt = row["bigInt"]!
		#expect(bigInt.intValue == -1)
		#expect(bigInt.stringValue == "-1")
		#expect(bigInt.uint64Value == 18446744073709551615)
		
		let double: Double = -1
		let intConvert = Int64(double)
		#expect(UInt64(bitPattern: intConvert) == UINT64_MAX)
		
		// now fetch a regular object!
		let mod = try await Mod.fetchId(1)
		#expect(mod.string == "2")
	}
	
	func lookupObjectsCount(_ tableName: ObjectIdentifier, _ expectedCount: Int, _ message: String) async {
		
		let count = await AutoDBManager.shared.lookupObjectsCount(tableName)
		#expect(count == expectedCount, Comment(rawValue: message))
	}
	
	@Test func test_fetching_api() async throws {
		
		try await BaseClass.truncateTable()
		
		let first = await BaseClass.create(1)
		let second = await BaseClass.create(2)
		try await [first, second].save()
		
		let list = try await BaseClass.fetchQuery().dictionary()
		
		//The actual point here is that list is of type [BaseClass]? and not AutoModel, or any protocol.
		#expect(list.count == 2, "Fail to fetch all items!")
		let got = list[AutoId(1)]
		#expect(got != nil)
		#expect(got?.anOptInt == nil)  //this should compile
		try await list.values.save()
	}
	
	@Test func testBasicQuery() async throws {
		
		let query = "SELECT 'Apa' as animal, 1 + ? as math"
		let list = try await BaseClass.query(query, [UInt64(2)])
		print(list.count)
		for (key, value) in list.first ?? [:] {
			print("l: \(key): \(value)")
		}
		let row = list.first!
		#expect(row["math"]?.intValue == 3)
		
		let maxInt = UInt64.max
		let signed = Int64(bitPattern: maxInt)
		#expect(UInt64(bitPattern: signed) == maxInt)
		
		let maxIntInt = Int(bitPattern: UInt(maxInt))
		#expect(UInt(bitPattern: maxIntInt) == maxInt)
	}
	
	@available(macOS 15.0, iOS 17.0, tvOS 17.0, watchOS 10.0, *)
	@Test func testObserveWithoutCodingKeys() async throws {
		try await AutoDBManager.shared.truncateTable(Artist.Value.self)
		
		let first = await Artist.create(1)
		first.value.name = "The Cure"
		try await first.save()
		
		let artist = try await Artist.fetchQuery("WHERE name = ?", [first.value.name]).first
		#expect(artist == first)
		#expect(artist === first)
		
	}
	
	@available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, *)
	@Test func testWithCodingKeys() async throws {
		try await AutoDBManager.shared.truncateTable(CodeWithKeys.self)
		
		var first: CodeWithKeys? = await CodeWithKeys.create(1)
		first?.name = "The Cure"
		first?.otherNest = Nested(name: "some name")
		try await first?.save()
		first = nil
		
		let artist = try await CodeWithKeys.fetchQuery("WHERE somethingElse = ?", ["The Cure"]).first
		#expect(artist != nil)
		#expect(artist?.nest != nil)
		
		// works with both default types and setting your own
		#expect(artist?.nest == Nested(name: "kurt"))
		#expect(artist?.otherNest == Nested(name: "some name"))
	}
	
	/// two tables have separate actors, test that we can read and write at the same time without crashing.
	/// Notice that two actors doing writes are slower than one actor.
	@available(macOS 15.0, iOS 17.0, tvOS 17.0, watchOS 10.0, *)
	@Test func testMultipleReadWrites() async throws {
		//let main =
		try await IntTester.db()
		//await main.setDebug()
		let other = try await ObserveBasic.db()
		//await other.setDebug()
		
		try await IntTester.truncateTable()
		try await ObserveBasic.truncateTable()
		
		let firstIterations = 2000
		let maxIterations = 4000
		let firstIteration = Task {
			for index in 1..<firstIterations {
				let item = await IntTester.create(AutoId(index))
				item.integer = index
				do {
					try await item.save()
				} catch {
					print(error.localizedDescription)
					Issue.record("Error here!")
				}
			}
			print("first chunk is saved")
		}
		
		// unrelated saves that locks the DB-file
		let observeBasicChunk = Task {
			for index in 1..<maxIterations {
				let item = await ObserveBasic.create(AutoId(index))
				item.optString = "\(index)"
				do {
					try await item.save()
				} catch {
					print(error.localizedDescription)
					Issue.record("Error here!")
				}
			}
			print("ObserveBasic chunk is saved")
		}
		
		Task {
			for index in firstIterations..<maxIterations {
				_ = try? await other.query("INSERT INTO IntTester (id, integer) VALUES(?, ?)", [index, index])
				//print("saved \(index)")
			}
			print("second chunk is saved")
		}
		
		let lastIteration = Task {
			for index in 1..<maxIterations {
				
				var item: IntTester? = nil
				while item == nil || item!.integer == 0 {
					item = try? await IntTester.fetchId(AutoId(index))
					if item == nil {
						try? await Task.sleep(for: .microseconds(10))
					}
				}
				//print("A got \(index)")
				#expect(item?.integer == index)
			}
		}
		
		let waiter = Task {
			for index in 1..<maxIterations {
				var item: Int? = nil
				while item == nil || item! == 0 {
					item = try? await other.query("SELECT integer FROM IntTester WHERE id = ?", [index]).first?.values.first?.intValue
					if item == nil {
						try? await Task.sleep(for: .microseconds(10))
					}
				}
				//print("B got \(index)")
				let result = item == index
				#expect(result, "\(index) was \(item!)")
			}
		}
		
		await waiter.value
		await observeBasicChunk.value
		await firstIteration.value
		await lastIteration.value
	}
	
	@Test func testCreateWithExistingId() async throws {
		try await AutoDBManager.shared.truncateTable(UniqueString.Value.self)
		
		let item = await UniqueString.create(1)
		item.string = "Test"
		try await item.save()
		
		let fetched = try await UniqueString.fetchId(1)
		#expect(fetched.string == "Test")
		
		let newItem = await UniqueString.create(1)
		newItem.string = "New Test"
		try await newItem.save()
		
		let updated = try await UniqueString.fetchId(1)
		#expect(updated.string == "New Test")
		
		#expect(updated === fetched)  // they should be the same object
		
		let duplicateItem = await UniqueString.create()
		duplicateItem.string = "New Test"
		let duplicateId = duplicateItem.id
		
		do {
			try await duplicateItem.save()
			Issue.record("Expected an error when saving a duplicate id")
		} catch AutoError.uniqueConstraintFailed(let ids) {
			print("Caught uniqueConstraintFailed error with ids: \(ids)")
			#expect(ids.contains(1) || ids.contains(duplicateId), "Expected id \(duplicateId) to be in the unique constraint error")
		}
	}
	
	@Test func testDuplicateDoesNotBlockLaterSaves() async throws {
		try await AutoDBManager.shared.truncateTable(UniqueString.Value.self)
		
		let existing = await UniqueString.create()
		existing.string = "taken"
		try await existing.save()
		
		// UniqueString has no didSet tracking: register the changes like a tracked model does
		let duplicate = await UniqueString.create()
		duplicate.string = "taken"
		await duplicate.didChange()
		do {
			try await duplicate.save()
			Issue.record("Expected an error when saving a duplicate")
		} catch AutoError.uniqueConstraintFailed(let ids) {
			#expect(ids == [duplicate.id])
		}
		
		// the duplicate is no longer a pending change: saving everything succeeds and saves what was created after it
		let other = await UniqueString.create()
		other.string = "free"
		await other.didChange()
		try await AutoDBManager.shared.saveAllChanges()
		let saved = try await UniqueString.fetchId(other.id)
		#expect(saved.string == "free")
		
		// still created: saved unchanged it is an INSERT that fails again, never a REPLACE of the row it collided with
		do {
			try await duplicate.save()
			Issue.record("Expected an error when saving a duplicate")
		} catch AutoError.uniqueConstraintFailed {}
		let kept = try await UniqueString.fetchId(existing.id)
		#expect(kept.string == "taken")
	}
	
	@Test func testTypedModelBucketsSavePendingChanges() async throws {
		try await AutoDBManager.shared.truncateTable(TrackedModel.Value.self)
		
		let item = await TrackedModel.create(1)
		item.name = "first"
		try await item.save()
		
		item.name = "second"
		try await AutoDBManager.shared.saveChanges(TrackedModel.self)
		
		let fetched = try await TrackedModel.fetchId(1)
		let pendingCount = await AutoDBManager.shared.lookupObjectsCount(ObjectIdentifier(TrackedModel.self))
		#expect(fetched === item)
		#expect(fetched.name == "second")
		#expect(pendingCount == 0)
	}
	
	@Test func testSaveAllChangesPersistsDroppedModelReferences() async throws {
		try await AutoDBManager.shared.truncateTable(TrackedModel.Value.self)
		
		let weakModel = WeakBox<TrackedModel>()
		let modelID: AutoId = 2
		
		do {
			var model: TrackedModel? = await TrackedModel.create(modelID)
			model?.name = "created"
			try await model?.save()
			
			model?.name = "pending"
			weakModel.value = model
			model = nil
		}
		
		#expect(weakModel.value != nil)
		try await AutoDBManager.shared.saveAllChanges()
		try await waitForCondition {
			weakModel.value == nil
		}
		
		let fetched = try await TrackedModel.fetchId(modelID)
		#expect(fetched.name == "pending")
	}
}
