//
//  StoredModelTests.swift
//  AutoDB
//
//  Created by Olof Andersson-Thorén on 2026-08-21.
//

import Testing
@testable import AutoDB
import AutoDBTesting

// A StoredModel keeps its value in a ModelStorage, needs no didSet boilerplate and conforms to Sendable without @unchecked.
final class StoredPerson: StoredModel {
	struct Value: Table {
		static let tableName = "StoredPerson"
		var id: AutoId = 0
		var name: String = ""
		var counter: Int = 0
	}
	
	let storage: ModelStorage<Value>
	init(_ value: Value) {
		self.storage = ModelStorage(value)
	}
	
	var name: String {
		get { value.name }
		set { withValue { $0.name = newValue } }
	}
}

@Suite(.autoDB, .serialized)
struct StoredModelTests {
	
	private static let logSetup: Void = AutoLog.setup()
	
	init() {
		_ = Self.logSetup
	}
	
	@Test func testSaveAndFetch() async throws {
		try await AutoDBManager.current.truncateTable(StoredPerson.Value.self)
		
		let item = await StoredPerson.create(1)
		item.name = "first"
		try await item.save()
		
		let fetched = try await StoredPerson.fetchId(1)
		#expect(fetched === item)
		#expect(fetched.name == "first")
		
		// the raw table data must be stored in db
		let value = try await StoredPerson.Value.fetchId(1)
		#expect(value.name == "first")
	}
	
	// the debugger's po / Quick Look must show the value, even while the lock is held
	@Test func testDebugDescriptionInsideLock() {
		let storage = ModelStorage(StoredPerson.Value(id: 1, name: "debug"))
		let description = storage.mutate { _ in storage.debugDescription }.result
		#expect(description.contains("name: \"debug\""))
	}
	
	@Test func testChangeTrackingViaWithValue() async throws {
		try await AutoDBManager.current.truncateTable(StoredPerson.Value.self)
		
		let item = await StoredPerson.create(2)
		item.name = "first"
		try await item.save()
		
		item.withValue { $0.name = "second" }
		try await AutoDBManager.current.saveChanges(StoredPerson.self)
		
		let value = try await StoredPerson.Value.fetchId(2)
		#expect(value.name == "second")
		
		let pendingCount = await AutoDBManager.current.lookupObjectsCount(ObjectIdentifier(StoredPerson.self))
		#expect(pendingCount == 0)
	}
	
	@Test func testChangeTrackingViaValueSetter() async throws {
		try await AutoDBManager.current.truncateTable(StoredPerson.Value.self)
		
		let item = await StoredPerson.create(3)
		item.name = "first"
		try await item.save()
		
		// mutating a field goes through the computed value property and must fire change-tracking
		item.value.name = "second"
		try await AutoDBManager.current.saveChanges(StoredPerson.self)
		
		let value = try await StoredPerson.Value.fetchId(3)
		#expect(value.name == "second")
	}
	
	@Test func testWithValueIsAtomic() async throws {
		try await AutoDBManager.current.truncateTable(StoredPerson.Value.self)
		
		let item = await StoredPerson.create(4)
		await withTaskGroup(of: Void.self) { group in
			for _ in 0..<100 {
				group.addTask {
					item.withValue { $0.counter += 1 }
				}
			}
		}
		#expect(item.value.counter == 100)
	}
	
	@Test func testIdNeverTakesLock() async throws {
		let item = await StoredPerson.create(5)
		#expect(item.id == 5)
		#expect(item.storage.id == item.value.id)
	}
}
