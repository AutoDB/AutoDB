//
//  TaskLocalTokenTests.swift
//  AutoDB
//
//  Created by Olof Andersson-Thorén on 2026-08-22.
//
//  Tests for the ambient SemaphoreToken task-local: code inside transactions and migrations
//  no longer needs to forward the token explicitly, explicit tokens still win.

import Testing
import Foundation

@testable import AutoDB

/// old-schema table whose migration deliberately does NOT forward the token - the ambient task-local must carry it
struct MigNoToken: Table {
	var id: AutoId = 1
	var plain = "plain"
	
	static var createTableSQL: String {
		"""
		CREATE TABLE IF NOT EXISTS "MigNoToken" (
			`id` INTEGER NOT NULL DEFAULT 1,
			`plain_old` TEXT NOT NULL DEFAULT 'plain',
			PRIMARY KEY (`id`));
		"""
	}
	
	static func migration(_ db: isolated Database, _ state: MigrationState) async {
		if case let .changes(oldTableName, _) = state {
			// note: no token forwarded anywhere in here - previously this would deadlock
			do {
				let oldValues = try await db.query("SELECT id, plain_old FROM `\(oldTableName)`")
				for oldValue in oldValues {
					if let old = oldValue["plain_old"]?.stringValue, let id = oldValue["id"]?.uint64Value {
						try await db.execute("UPDATE MigNoToken SET plain = ? WHERE id = ?", [old, id])
					}
				}
			} catch {
				print("MigNoToken migration failed: \(error)")
			}
		}
	}
}

final class DoneFlag: @unchecked Sendable {
	var done = false
}

actor TokenBox {
	var value: AutoId?
	func set(_ value: AutoId?) {
		self.value = value
	}
}

class TaskLocalTokenTests: @unchecked Sendable {
	
	/// wait for a flag with a deadline, so a deadlock regression fails the test instead of hanging CI forever
	private func waitFor(_ flag: DoneFlag, seconds: TimeInterval = 10) async throws {
		let deadline = Date().addingTimeInterval(seconds)
		while flag.done == false && Date() < deadline {
			try await Task.sleep(for: .milliseconds(20))
		}
	}
	
	@Test func taskLocalInheritance() async throws {
		await SemaphoreToken.$current.withValue(7) {
			#expect(SemaphoreToken.current == 7)
			// Task {} inherits the binding
			let inherited = await Task { SemaphoreToken.current }.value
			#expect(inherited == 7)
			// Task.detached does not - detached work inside a transaction must keep waiting for it
			let detached = await Task.detached { SemaphoreToken.current }.value
			#expect(detached == nil)
		}
		// restored after the scope
		#expect(SemaphoreToken.current == nil)
	}
	
	@Test func nilTokenInsideTransaction() async throws {
		_ = try await TransClass.db()
		let flag = DoneFlag()
		let work = Task {
			try await TransClass.transaction { db in
				// none of these forward the token - previously each would deadlock
				try await db.query("SELECT 1")
				let item = await TransClass.create(77)
				item.integer = 5
				try await item.save()
				let fetched = try await TransClass.fetchId(77)
				#expect(fetched.integer == 5)
				try await db.execute("DELETE FROM TransClass WHERE id = 77")
			}
			flag.done = true
		}
		try await waitFor(flag)
		#expect(flag.done, "nil-token DB calls inside a transaction deadlocked")
		if flag.done == false {
			work.cancel()
		}
	}
	
	@Test func nestedTransactionReusesAmbientToken() async throws {
		// this exact shape used to be the deadlockSemaphore example in TransactionTests -
		// a nested transaction without a forwarded token now picks up the outer token from the task-local
		let db = try await TransClass.db()
		let flag = DoneFlag()
		let work = Task {
			try? await db.transaction { db in
				let outerToken = SemaphoreToken.current
				try await db.transaction { db in
					// reuses the outer lock token, nests only the savepoint
					#expect(SemaphoreToken.current == outerToken)
					try await db.execute("INSERT OR REPLACE INTO TransClass (id, integer) VALUES (78, 5)")
				}
				// roll back the outer - must also roll back the (released) inner savepoint
				throw TestError.transaction
			}
			flag.done = true
		}
		try await waitFor(flag)
		#expect(flag.done, "nested nil-token transaction deadlocked")
		if flag.done {
			let rows = try await db.query("SELECT id FROM TransClass WHERE id = 78")
			#expect(rows.isEmpty, "inner transaction's write survived the outer rollback")
		} else {
			work.cancel()
		}
	}
	
	@Test func explicitTokenWinsOverAmbient() async throws {
		// deliberately uses the deprecated token-taking API - this is the compatibility test
		// for users who still pass tokens explicitly, so the deprecation warning here is expected.
		let db = try await TransClass.db()
		let explicit = AutoId.generateId()
		try await SemaphoreToken.$current.withValue(AutoId.generateId()) {
			try await db.transaction(token: explicit) { db, token in
				#expect(token == explicit)
				#expect(SemaphoreToken.current == explicit)
			}
		}
	}
	
	@Test func debounceDoesNotInheritToken() async throws {
		// delayed work must never inherit a transaction token - it could re-enter a still-open transaction's lock
		let box = TokenBox()
		await SemaphoreToken.$current.withValue(42) {
			await Debounce.shared.debounce(id: "tokenScrubTest", delay: 0.01) {
				await box.set(SemaphoreToken.current ?? 0)
			}
			try? await Task.sleep(for: .milliseconds(300))
		}
		#expect(await box.value == 0, "debounced action saw an inherited token")
	}
	
	@Test func migrationWithoutForwardingToken() async throws {
		// create an "old" table for MigNoToken before its own setup runs, then trigger migration
		let db = try await MigFirst.db()
		_ = try? await db.execute("DROP TABLE MigNoToken")
		try await db.execute(MigNoToken.createTableSQL)
		try await db.execute("INSERT INTO MigNoToken (id, plain_old) VALUES (1, 'migrated value')")
		
		let flag = DoneFlag()
		let work = Task {
			// triggers setupDB -> migration inside a transaction; the migration uses no tokens at all
			let first = try await MigNoToken.fetchId(1)
			#expect(first.plain == "migrated value")
			flag.done = true
		}
		try await waitFor(flag)
		#expect(flag.done, "token-less migration deadlocked")
		if flag.done == false {
			work.cancel()
		}
	}
}
