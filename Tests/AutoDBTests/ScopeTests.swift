//
//  ScopeTests.swift
//  AutoDB
//
//  Created by Olof Andersson-Thorén on 2026-10-20.
//
//  Tests for scopes: one manager per set of databases. Production types are shared between suites here on purpose -
//  each suite's .autoDB manager keeps their rows apart, and models remember the manager they came from.

import Foundation
import Testing

@testable import AutoDB
import AutoDBTesting

/// a production-style type with one declaration, used by every suite below
final class ScopeItem: Model {
	struct Value: Table {
		static let tableName = "ScopeItem"
		var id: AutoId = 0
		var name = ""
		var cached = OneRelation<ScopeCached>()
	}
	let storage: ModelStorage<Value>
	init(_ value: Value) {
		self.storage = ModelStorage(value)
	}
}

/// lives in the cache file, so ScopeItem.cached is a relation between two databases
struct ScopeCached: Table {
	static let autoDBSettings = AutoDBSettings.cache
	var id: AutoId = 0
	var name = ""
}

final class ScopeSingleton: Sendable {}

/// a manager of our own, outside the suite's scope, in an emptied folder
private func freshManager(_ name: String) -> (AutoDBManager, URL) {
	let folder = AutoDBManager.shared.fileURL(for: .cache(path: "AutoDBTests/ScopeTestsManual/\(name)"))!
	try? FileManager.default.removeItem(at: folder)
	return (AutoDBManager(root: folder), folder)
}

/// write id 1 with this suite's name, give the other suite time to do the same, and read back our own row
private func writeAndReadOwnRow(_ name: String) async throws {
	try await ScopeItem.truncateTable()
	let item = await ScopeItem.create(1)
	item.value.name = name
	try await item.save()
	try await Task.sleep(for: .milliseconds(200))
	let rows = try await ScopeItem.Value.fetchQuery()
	#expect(rows.map(\.name) == [name])
	
	var cached = await ScopeCached.create(1)
	cached.name = name
	try await cached.save()
	let regular = try #require(AutoDBManager.current.fileURL(for: .regular))
	let cache = try #require(AutoDBManager.current.fileURL(for: .cache))
	#expect(regular.path.contains("/AutoDBTests/\(name)/"))
	#expect(regular != cache)
	#expect(FileManager.default.fileExists(atPath: regular.path))
	#expect(FileManager.default.fileExists(atPath: cache.path))
}

@Suite(.autoDB)
struct ScopeTestsA {
	@Test func ownRows() async throws {
		try await writeAndReadOwnRow("ScopeTestsA")
	}
}

@Suite(.autoDB)
struct ScopeTestsB {
	@Test func ownRows() async throws {
		try await writeAndReadOwnRow("ScopeTestsB")
	}
}

@Suite(.autoDB, .serialized)
struct ScopeTests {
	
	@Test func detachedSaveUsesTheModelsManager() async throws {
		let (manager, _) = freshManager("detached")
		let item = try await AutoDBManager.withScope(manager) {
			let item = await ScopeItem.create(2)
			try await item.save()
			return item
		}
		#expect(item.autoDBManager === manager)
		
		// Task.detached loses the scope, the model still knows where it came from
		try await Task.detached {
			item.value.name = "detached"
			try await item.save()
		}.value
		
		let saved = try await AutoDBManager.withScope(manager) {
			try await ScopeItem.Value.fetchId(2)
		}
		#expect(saved.name == "detached")
		// and nothing reached the suite's own database
		#expect(try await ScopeItem.Value.fetchQuery("WHERE id = 2").isEmpty)
	}
	
	@Test func notificationSaveUsesTheModelsManager() async throws {
		let (manager, _) = freshManager("notification")
		let item = await AutoDBManager.withScope(manager) {
			await ScopeItem.create(3)
		}
		let name = Notification.Name("ScopeTests.save")
		let observer = NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { _ in
			item.value.name = "notified"
			item.save()
		}
		defer { NotificationCenter.default.removeObserver(observer) }
		DispatchQueue.global().async {
			NotificationCenter.default.post(name: name, object: nil)
		}
		
		try await waitForCondition(delay: 5, "the notification's save never reached the model's manager") {
			let saved = try? await AutoDBManager.withScope(manager) {
				try await ScopeItem.Value.fetchId(3)
			}
			return saved?.name == "notified"
		}
		#expect(try await ScopeItem.Value.fetchQuery("WHERE id = 3").isEmpty)
	}
	
	@Test func requireScopeThrowsAndLeavesNoFile() async throws {
		let (manager, folder) = freshManager("requireScope")
		await manager.requireScope()
		await AutoDBManager.withScope(manager) {
			await #expect(throws: AutoError.self) {
				try await ScopeItem.Value.db()
			}
		}
		#expect(FileManager.default.fileExists(atPath: folder.path) == false)
	}
	
	/// deletes look up the table without setting it up first - they used to wait forever for a setup requireScope refused
	@Test(.timeLimit(.minutes(1))) func requireScopeThrowsOnDelete() async throws {
		let (manager, _) = freshManager("requireScopeDelete")
		await manager.requireScope()
		await #expect(throws: AutoError.self) {
			try await manager.delete([1], ObjectIdentifier(ScopeItem.Value.self))
		}
		await AutoDBManager.withScope(manager) {
			await #expect(throws: AutoError.self) {
				try await ScopeItem.deleteIds([1])
			}
		}
	}
	
	@Test func testManagerFolder() async throws {
		let manager = AutoDBManager.testManager("ScopeTests/testManager()")
		let regular = try #require(manager.fileURL(for: .regular))
		#expect(regular.path.contains("/AutoDBTests/ScopeTests_testManager/"))
	}
	
	@Test func storageIsPerManager() {
		let (first, _) = freshManager("storageFirst")
		let (second, _) = freshManager("storageSecond")
		let one = first.storage(for: "singleton") { ScopeSingleton() }
		#expect(first.storage(for: "singleton") { ScopeSingleton() } === one)
		#expect(second.storage(for: "singleton") { ScopeSingleton() } !== one)
	}
	
	@Test func crossDatabaseRelation() async throws {
		var cached = await ScopeCached.create(4)
		cached.name = "in the cache"
		try await cached.save()
		let item = await ScopeItem.create(4)
		await item.value.cached.setObject(cached)
		try await item.save()
		
		#expect(try await ScopeItem.Value.db() !== ScopeCached.db())
		let row = try await ScopeItem.Value.fetchId(4)
		#expect(try await row.cached.object.name == "in the cache")
	}
	
	@Test func rootedLocations() throws {
		let root = URL(fileURLWithPath: "/tmp/AutoDBScopeRoot")
		let manager = AutoDBManager(root: root)
		#expect(manager.fileURL(for: .regular)?.path == "/tmp/AutoDBScopeRoot/Application Support/" + AutoDBSettings.regular.path)
		#expect(manager.fileURL(for: .cache)?.path == "/tmp/AutoDBScopeRoot/Caches/" + AutoDBSettings.cache.path)
		let absolute = AutoDBSettings(path: "/somewhere/else/absolute.db", iCloudBackup: false, inAppFolder: false, inCacheFolder: false)
		#expect(manager.fileURL(for: absolute)?.path == "/tmp/AutoDBScopeRoot/absolute.db")
		#expect(manager.fileURL(for: .memory) == nil)
	}
	
	@Test func scopeReachesChildTasks() async throws {
		let suiteManager = AutoDBManager.current
		#expect(suiteManager !== AutoDBManager.shared)
		#expect(await Task { AutoDBManager.current }.value === suiteManager)
		#expect(await Task.detached { AutoDBManager.current }.value === AutoDBManager.shared)
	}
}
