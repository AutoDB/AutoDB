//
//  TransactionTests.swift
//  AutoDB
//
//  Created by Olof Andersson-Thorén on 2025-01-15.
//

import Testing
import Foundation

@testable import AutoDB

final class TransClass: Table, @unchecked Sendable {
	var id: AutoId = 1
	var integer = 1
}

class TransactionTests: @unchecked Sendable {
	
	@Test func testTransaction() async throws {
		let started = Locked(false)
		let finished = Locked(false)
		let competingTask = Locked<Task<Void, Error>?>(nil)
		try await TransClass.truncateTable()
		
		do {
			try await TransClass.transaction { db in
				let first = await TransClass.create(1)
				first.integer = 2
				try await first.save()
				#expect(first.integer == 2)
				
				let task = Task.detached {
					defer { finished.withLock { $0 = true } }
					started.withLock { $0 = true }
					try await db.transaction { db in
						// The first transaction has rolled back before the competing transaction can enter.
						let rows = try await db.query("SELECT id FROM TransClass WHERE id = ?", [1])
						#expect(rows.isEmpty)
					}
				}
				competingTask.withLock { $0 = task }
				
				// Force the previously deadlocking order, but wait only for startup while holding the transaction lock.
				try await waitForCondition(delay: 5, "the competing transaction should start") { started.withLock { $0 } }
				#expect(finished.withLock { $0 } == false)
				throw TestError.transaction
			}
		} catch TestError.transaction {
			// Rollback is intentional; all other errors must fail the test.
		}
		
		try await waitForCondition(delay: 5, "the competing transaction should finish after rollback") { finished.withLock { $0 } }
		let task = try #require(competingTask.withLock { $0 })
		try await task.value
		let rows = try await TransClass.fetchQuery("WHERE id = ?", [1])
		#expect(rows.isEmpty)
	}
	
	// this is an example of how actors and threads are different:
	//@Test
	func failingWithNSLock() async throws {
		
		let act = TestActor()
		for index in 0..<100 {
			print("run \(index)")
			try await act.increment()
		}
	}
	
	// This is an example of how the watchdog works, it can kill the app if there is a deadlock - but can only know that based on time. So be certain you have no tasks running longer than this!
	// Note: a nested transaction no longer deadlocks by itself (it reuses the ambient SemaphoreToken task-local, see TaskLocalTokenTests),
	// so to demonstrate a real deadlock we must *wait* for detached work - which doesn't inherit the token and therefore waits for us.
	//@Test
	func deadlockSemaphore() async throws {
		let db = try await TransClass.db()
		await db.semaphoreWatchdog(1)
		do {
			try await db.transaction { db in
				print("will deadlock now:")
				let detached = Task.detached {
					let db = try await TransClass.db()
					try await db.transaction { db in
						print("this will never happen")
					}
				}
				// awaiting detached work that itself waits for our transaction -> deadlock
				try await detached.value
			}
		} catch {
			print("caught error: \(error)")
			
		}
	}
}

enum TestError: Error {
	case transaction
}

actor TestActor {
	var counter: Int = 0
	let lock = BadLock()
	
	func increment() async throws {
		lock.lock()
		counter += 1
		try await Task.sleep(for: .milliseconds(100))
		if counter < 2000 {
			try await increment()
		}
		lock.unlock()
	}
}

class BadLock: @unchecked Sendable {
	let _lock = NSRecursiveLock()
	
	func lock() {
		self._lock.lock()
	}
	
	func unlock() {
		self._lock.unlock()
	}
}
