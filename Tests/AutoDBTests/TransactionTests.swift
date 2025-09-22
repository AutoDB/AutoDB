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
	
	var threadBlocker = 0
	
	@Test func testTransaction() async throws {
		
		try await TransClass.db().setDebug()
		try? await TransClass.transaction { db, token in
			print("in transaction")
			
			let first = await TransClass.create(token: token, 1)
			first.integer = 2
			try await first.save(token: token)
			
			#expect(first.integer == 2)
			Task.detached {
				do {
					let db = try await TransClass.db()
					self.threadBlocker = 1
					try await db.transaction({ db, token in
						// first transaction is now gone.
						let found = try? await TransClass.fetchId(token: token, 1)
						#expect(found == nil)
						self.threadBlocker = 2
					})
				} catch {
					print(error)
				}
			}
			
			while threadBlocker == 1 {
				// we will wait here until the detached Task has started
				try await Task.sleep(for: .milliseconds(4))
			}
			
			// the detached Task  
			throw TestError.transaction
		}
		print("outside transaction")
		let found = try? await TransClass.fetchId(1)
		#expect(found == nil)
		while threadBlocker <= 1 {
			// we will wait here until the detached Task has started
			try await Task.sleep(for: .milliseconds(4))
			print("\(threadBlocker)")
		}
		
		try await TransClass.db().setDebug(false)
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
	//@Test
	func deadlockSemaphore() async throws {
		let db = try await TransClass.db()
		await db.semaphoreWatchdog(1)
		do {
			try await db.transaction { db, token in
				print("will deadlock now:")
				try await db.transaction { db, token in
					print("this will never happen")
				}
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
