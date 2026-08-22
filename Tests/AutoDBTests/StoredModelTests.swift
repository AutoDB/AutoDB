//
//  StoredModelTests.swift
//  AutoDB
//
//  Created by Olof Andersson-Thorén on 2026-08-21.
//

import XCTest
@testable import AutoDB

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

final class StoredModelTests: XCTestCase {

	static override func setUp() {
		AutoLog.setup()
	}

	func testSaveAndFetch() async throws {
		try await AutoDBManager.shared.truncateTable(StoredPerson.Value.self)

		let item = await StoredPerson.create(1)
		item.name = "first"
		try await item.save()

		let fetched = try await StoredPerson.fetchId(1)
		XCTAssertTrue(fetched === item)
		XCTAssertEqual(fetched.name, "first")

		// the raw table data must be stored in db
		let value = try await StoredPerson.Value.fetchId(1)
		XCTAssertEqual(value.name, "first")
	}

	func testChangeTrackingViaWithValue() async throws {
		try await AutoDBManager.shared.truncateTable(StoredPerson.Value.self)

		let item = await StoredPerson.create(2)
		item.name = "first"
		try await item.save()

		item.withValue { $0.name = "second" }
		try await AutoDBManager.shared.saveChanges(StoredPerson.self)

		let value = try await StoredPerson.Value.fetchId(2)
		XCTAssertEqual(value.name, "second")

		let pendingCount = await AutoDBManager.shared.lookupObjectsCount(ObjectIdentifier(StoredPerson.self))
		XCTAssertEqual(pendingCount, 0)
	}

	func testChangeTrackingViaValueSetter() async throws {
		try await AutoDBManager.shared.truncateTable(StoredPerson.Value.self)

		let item = await StoredPerson.create(3)
		item.name = "first"
		try await item.save()

		// mutating a field goes through the computed value property and must fire change-tracking
		item.value.name = "second"
		try await AutoDBManager.shared.saveChanges(StoredPerson.self)

		let value = try await StoredPerson.Value.fetchId(3)
		XCTAssertEqual(value.name, "second")
	}

	func testWithValueIsAtomic() async throws {
		try await AutoDBManager.shared.truncateTable(StoredPerson.Value.self)

		let item = await StoredPerson.create(4)
		await withTaskGroup(of: Void.self) { group in
			for _ in 0..<100 {
				group.addTask {
					item.withValue { $0.counter += 1 }
				}
			}
		}
		XCTAssertEqual(item.value.counter, 100)
	}

	func testIdNeverTakesLock() async throws {
		let item = await StoredPerson.create(5)
		XCTAssertEqual(item.id, 5)
		XCTAssertEqual(item.storage.id, item.value.id)
	}
}
