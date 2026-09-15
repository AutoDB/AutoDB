//
//  SaveLockOrderTests.swift
//  AutoDB
//
//  Saves and creates must not hold a per-type lock while they wait for an open transaction: the transaction's own save or create of
//  that type would wait for the lock, and both would hang. saveList holds no lock (every save has its own encoder buffers) and
//  Model.create takes the database's transaction slot before the type's creation lock.
//

import Foundation
import Testing

@testable import AutoDB

struct LockOrderRow: Table {
	static let tableName = "LockOrderRow"
	
	var id: AutoId = 1
	var name = ""
}

final class LockOrderModel: StoredModel {
	struct Value: Table {
		static let tableName = "LockOrderModel"
		var id: AutoId = 0
		var name = ""
	}
	
	let storage: ModelStorage<Value>
	init(_ value: Value) {
		storage = ModelStorage(value)
	}
	
	var name: String {
		get { value.name }
		set { withValue { $0.name = newValue } }
	}
}

/// only this file's setup test touches these, so their first-time setup happens in that test
struct SetupLockOrderInside: Table {
	static let tableName = "SetupLockOrderInside"
	var id: AutoId = 1
}

struct SetupLockOrderOutside: Table {
	static let tableName = "SetupLockOrderOutside"
	var id: AutoId = 1
}

actor LockOrderFlags {
	var transactionStarted = false
	var outsideStarted = false
	
	func markTransactionStarted() { transactionStarted = true }
	func markOutsideStarted() { outsideStarted = true }
}

@Suite("Save lock order", .serialized)
struct SaveLockOrderTests {
	
	/// both tasks must finish - a deadlock shows up as this timeout, not as a hung test run
	private func bothFinish(_ first: Task<Void, Error>, _ second: Task<Void, Error>) async throws {
		try await withThrowingTaskGroup(of: Void.self) { group in
			group.addTask { try await first.value }
			group.addTask { try await second.value }
			group.addTask {
				try await Task.sleep(for: .seconds(10))
				throw WaitError.reason("deadlock: the tasks never finished")
			}
			try await group.next()
			try await group.next()
			group.cancelAll()
		}
	}
	
	@Test func saveOutsideATransactionWaitsForItInsteadOfDeadlocking() async throws {
		let db = try await LockOrderRow.db()
		try await LockOrderRow.truncateTable()
		let flags = LockOrderFlags()
		
		let transaction = Task {
			try await db.transaction { _ in
				await flags.markTransactionStarted()
				// let the outside save start and block on us, then save the same type from inside
				try await waitForCondition(delay: 5, "the outside save should start") { await flags.outsideStarted }
				try await Task.sleep(for: .milliseconds(300))
				var inside = LockOrderRow()
				inside.id = 1
				inside.name = "inside"
				try await inside.save()
			}
		}
		let outside = Task {
			try await waitForCondition(delay: 5, "the transaction should start") { await flags.transactionStarted }
			await flags.markOutsideStarted()
			var row = LockOrderRow()
			row.id = 2
			row.name = "outside"
			try await row.save()
		}
		try await bothFinish(transaction, outside)
		
		let rows = try await LockOrderRow.fetchQuery("ORDER BY id")
		#expect(rows.map { $0.name } == ["inside", "outside"])
	}
	
	/// create(id) outside a transaction fetches under the creation lock; it must wait for the transaction first, or the transaction's create + save of the type hangs
	@Test func createOutsideATransactionWaitsForItInsteadOfDeadlocking() async throws {
		let db = try await LockOrderModel.db()
		try await AutoDBManager.shared.truncateTable(LockOrderModel.Value.self)
		let flags = LockOrderFlags()
		
		let transaction = Task {
			try await db.transaction { _ in
				await flags.markTransactionStarted()
				try await waitForCondition(delay: 5, "the outside create should start") { await flags.outsideStarted }
				try await Task.sleep(for: .milliseconds(300))
				let inside = await LockOrderModel.create(1)
				inside.name = "inside"
				try await inside.save()
			}
		}
		let outside = Task {
			try await waitForCondition(delay: 5, "the transaction should start") { await flags.transactionStarted }
			await flags.markOutsideStarted()
			let created = await LockOrderModel.create(2)
			created.name = "outside"
			try await created.save()
		}
		try await bothFinish(transaction, outside)
		
		let rows: [LockOrderModel] = try await LockOrderModel.fetchQuery("ORDER BY id")
		#expect(rows.map { $0.name } == ["inside", "outside"])
	}
	
	/// every save has its own encoder buffers: parallel saves of one type never mix rows
	@Test func concurrentSavesOfOneTypeKeepTheirRows() async throws {
		_ = try await LockOrderRow.db()
		try await LockOrderRow.truncateTable()
		
		func rows(_ range: Range<Int>, _ prefix: String) -> [LockOrderRow] {
			range.map { index in
				var row = LockOrderRow()
				row.id = AutoId(index)
				row.name = "\(prefix)\(index)"
				return row
			}
		}
		let a = rows(1..<201, "a")
		let b = rows(201..<401, "b")
		let c = rows(401..<601, "c")
		try await withThrowingTaskGroup(of: Void.self) { group in
			group.addTask { try await LockOrderRow.saveList(a) }
			group.addTask { try await LockOrderRow.saveList(b) }
			group.addTask { try await LockOrderRow.saveList(c) }
			try await group.waitForAll()
		}
		
		let stored = try await LockOrderRow.fetchQuery("ORDER BY id")
		#expect(stored.count == 600)
		#expect(stored.allSatisfy { $0.name == "\($0.id < 201 ? "a" : $0.id < 401 ? "b" : "c")\($0.id)" })
	}
	
	/// a table's first-time setup outside a transaction must wait for the transaction before it locks anything - a transaction that reaches another
	/// fresh table meanwhile sets it up from inside, instead of both waiting for each other
	@Test func firstTimeTableSetupOutsideATransactionWaitsForIt() async throws {
		let db = try await LockOrderRow.db()
		let flags = LockOrderFlags()
		
		let transaction = Task {
			try await db.transaction { _ in
				await flags.markTransactionStarted()
				try await waitForCondition(delay: 5, "the outside setup should start") { await flags.outsideStarted }
				try await Task.sleep(for: .milliseconds(300))
				// first-time setup of a table from inside the transaction
				var row = SetupLockOrderInside()
				row.id = 1
				try await row.save()
			}
		}
		let outside = Task {
			try await waitForCondition(delay: 5, "the transaction should start") { await flags.transactionStarted }
			await flags.markOutsideStarted()
			// first-time setup of another table while the transaction is open
			var row = SetupLockOrderOutside()
			row.id = 1
			try await row.save()
		}
		try await bothFinish(transaction, outside)
		
		let inside = try await SetupLockOrderInside.fetchQuery()
		let outsideRows = try await SetupLockOrderOutside.fetchQuery()
		#expect(inside.count == 1)
		#expect(outsideRows.count == 1)
	}
	
	/// saves inside a transaction still re-enter
	@Test func saveInsideATransactionStillWorks() async throws {
		let db = try await LockOrderRow.db()
		try await LockOrderRow.truncateTable()
		try await db.transaction { _ in
			var a = LockOrderRow()
			a.id = 10
			a.name = "a"
			try await a.save()
			var b = LockOrderRow()
			b.id = 11
			b.name = "b"
			try await b.save()
		}
		let rows = try await LockOrderRow.fetchQuery("WHERE id >= 10 ORDER BY id")
		#expect(rows.map { $0.name } == ["a", "b"])
	}
}
