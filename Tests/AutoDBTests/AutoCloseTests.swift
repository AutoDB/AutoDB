//
//  AutoCloseTests.swift
//  AutoDB
//
//  Tests for the idle auto-close feature: the DB closes itself after a period
//  of non-use and reopens transparently on the next access - but a manually
//  closed DB stays closed.
//

import Testing
import Foundation

@testable import AutoDB

class AutoCloseTests: @unchecked Sendable {

	/// A file-backed throw-away DB with one table - auto-close on an in-memory DB is (deliberately) a no-op, so these tests need real files.
	private func makeFileDB() async throws -> Database {
		let path = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("AutoCloseTests-\(UUID().uuidString).db")
			.path
		let db = try Database(path)
		try await db.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, val TEXT)")
		return db
	}

	@Test func autoCloseAndTransparentReopen() async throws {
		let db = try await makeFileDB()
		try await db.execute("INSERT INTO t (id, val) VALUES (?, ?)", [1, "hello"])
		// same parameterized query before and after the close, so the reopen must rebuild the statement cache
		let before = try await db.query("SELECT val FROM t WHERE id = ?", [1])
		#expect(before.first?["val"]?.stringValue == "hello")

		await db.setAutoClose(after: 0.1)
		try await waitForCondition("db should auto-close when idle") { await db.isClosed }

		// the next access reopens transparently and the data is still there
		let after = try await db.query("SELECT val FROM t WHERE id = ?", [1])
		#expect(after.first?["val"]?.stringValue == "hello")
		let closed = await db.isClosed
		#expect(closed == false)
	}

	@Test func manualCloseStaysClosed() async throws {
		let db = try await makeFileDB()
		await db.close(waitSec: 1)
		try await waitForCondition("db should close manually") { await db.isClosed }

		await #expect(throws: Database.Error.self) {
			try await db.query("SELECT * FROM t")
		}
		// and it can be opened again by hand
		try await db.open()
		let rows = try await db.query("SELECT * FROM t")
		#expect(rows.isEmpty)
	}

	@Test func manualCloseAfterAutoCloseStaysClosed() async throws {
		let db = try await makeFileDB()
		await db.setAutoClose(after: 0.1)
		try await waitForCondition("db should auto-close when idle") { await db.isClosed }

		// a manual close on an already auto-closed DB escalates it - no transparent reopen anymore
		await db.closeNow()
		await #expect(throws: Database.Error.self) {
			try await db.query("SELECT * FROM t")
		}
	}

	@Test func autoCloseDefersDuringTransaction() async throws {
		let db = try await makeFileDB()
		await db.setAutoClose(after: 0.1)

		try await db.transaction { db in
			// stay idle inside the transaction for longer than the delay
			try await Task.sleep(nanoseconds: .seconds(0.3))
			try await db.execute("INSERT INTO t (id, val) VALUES (?, ?)", [1, "inside"])
			try await Task.sleep(nanoseconds: .seconds(0.3))
			// still open - the watcher must not close a running transaction
			#expect(db.isClosed == false)
		}

		// but once the transaction is over, idle time counts again
		try await waitForCondition("db should auto-close after the transaction") { await db.isClosed }
		let rows = try await db.query("SELECT val FROM t WHERE id = ?", [1])
		#expect(rows.first?["val"]?.stringValue == "inside")
	}

	@Test func observersSurviveReopen() async throws {
		let db = try await makeFileDB()
		let observer = await db.rowChangeObserver("t")
		let gotChange = Locked(false)
		let listener = Task {
			for await _ in observer {
				gotChange.withLock { $0 = true }
				break
			}
		}

		await db.setAutoClose(after: 0.1)
		try await waitForCondition("db should auto-close when idle") { await db.isClosed }

		// the write reopens the DB, and the update_hook on the new handle must still reach the old observer
		try await db.execute("INSERT INTO t (id, val) VALUES (?, ?)", [1, "hello"])
		try await waitForCondition("row change should reach the observer after reopen") { gotChange.withLock { $0 } }
		listener.cancel()
	}

	@Test func keepOpenPostponesAutoClose() async throws {
		let db = try await makeFileDB()
		await db.setAutoClose(after: 0.15)
		// scheduled delayed work (like saveChangesLater) holds the connection open past the idle delay
		await db.keepOpen(for: 0.8)

		try await Task.sleep(nanoseconds: .seconds(0.45))
		let closed = await db.isClosed
		#expect(closed == false)

		// once the floor has passed and it is still idle, it closes as usual
		try await waitForCondition("db should auto-close after the keepOpen floor passes") { await db.isClosed }
	}

	@Test func disablingAutoCloseKeepsItOpen() async throws {
		let db = try await makeFileDB()
		await db.setAutoClose(after: 0.1)
		await db.setAutoClose(after: nil)
		try await Task.sleep(nanoseconds: .seconds(0.4))
		let closed = await db.isClosed
		#expect(closed == false)
	}

	@Test func inMemoryNeverAutoCloses() async throws {
		let db = try Database(nil)
		try await db.execute("CREATE TABLE t (id INTEGER PRIMARY KEY)")
		await db.setAutoClose(after: 0.05)
		try await Task.sleep(nanoseconds: .seconds(0.3))
		let closed = await db.isClosed
		#expect(closed == false)
		// and the data is untouched
		try await db.execute("INSERT INTO t (id) VALUES (?)", [7])
		let rows = try await db.query("SELECT id FROM t")
		#expect(rows.count == 1)
	}

	@Test func activityRefreshesTheTimer() async throws {
		let db = try await makeFileDB()
		await db.setAutoClose(after: 0.3)
		// query every 0.1s - well within the delay, so it must never close in between
		var previous = DispatchTime.now()
		for index in 0..<8 {
			try await Task.sleep(nanoseconds: .seconds(0.1))
			let closed = await db.isClosed
			let elapsed = Double(DispatchTime.now().uptimeNanoseconds - previous.uptimeNanoseconds) / 1_000_000_000
			if elapsed < 0.3 {
				// only meaningful when the gap actually stayed within the idle delay - under heavy load the sleep can stretch past it, and then closing is correct
				#expect(closed == false)
			}
			try await db.execute("INSERT INTO t (id, val) VALUES (?, ?)", [index, "row"])
			previous = DispatchTime.now()
		}
		try await waitForCondition("db should auto-close once the activity stops") { await db.isClosed }
	}

	@Test func stressConcurrentQueriesWithTinyDelay() async throws {
		let db = try await makeFileDB()
		await db.setAutoClose(after: 0.01)
		try await withThrowingTaskGroup(of: Void.self) { group in
			for index in 0..<100 {
				group.addTask {
					try? await Task.sleep(nanoseconds: .seconds(0.001 * Double(index % 20)))
					// every access must succeed - either the DB is open, or it reopens transparently
					try await db.execute("INSERT INTO t (id, val) VALUES (?, ?)", [index, "stress"])
				}
			}
			try await group.waitForAll()
		}
		let rows = try await db.query("SELECT COUNT(*) AS c FROM t")
		#expect(rows.first?["c"]?.intValue == 100)
	}
}
