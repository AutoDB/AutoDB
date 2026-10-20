//
//  SettingsTests.swift
//  AutoDB
//
//  Tests for compile-time database settings: which database a table lands in is decided by its
//  autoDBSettings - its own declaration, a refined protocol's default, or the module-wide one -
//  and settings resolving to the same place share one connection.

import Foundation
import Testing

@testable import AutoDB

private struct SettingsFirst: Table {
	static let autoDBSettings = TestDatabase.settings
	var id: AutoId = 0
	var name = ""
}

private struct SettingsSecond: Table {
	static let autoDBSettings = TestDatabase.settings
	var id: AutoId = 0
	var name = ""
}

/// same file as TestDatabase.settings but other options - it must share the first one's connection
private struct SettingsSameFileOtherOptions: Table {
	static let autoDBSettings = AutoDBSettings(path: TestDatabase.settings.path, iCloudBackup: false, inAppFolder: false, inCacheFolder: false, autoCloseDelay: nil)
	var id: AutoId = 0
	var name = ""
}

private struct SettingsMemoryFirst: Table {
	static let autoDBSettings = AutoDBSettings.memory
	var id: AutoId = 0
	var name = ""
}

private struct SettingsMemorySecond: Table {
	static let autoDBSettings = AutoDBSettings.memory
	var id: AutoId = 0
	var name = ""
}

/// a group of tables sent to another file through a refined protocol
private protocol SettingsGroupTable: Table {}
extension SettingsGroupTable {
	static var autoDBSettings: AutoDBSettings { TestDatabase.settingsGroup }
}

private struct SettingsGrouped: SettingsGroupTable {
	var id: AutoId = 0
	var name = ""
}

/// the type's own declaration beats its group's
private struct SettingsGroupedOverride: SettingsGroupTable {
	static let autoDBSettings = TestDatabase.settings
	var id: AutoId = 0
	var name = ""
}

struct SettingsTests {
	
	@Test func explicitPathIsUsed() async throws {
		let db = try await SettingsFirst.db()
		#expect(await db.dbURL?.path == TestDatabase.settings.path)
		#expect(FileManager.default.fileExists(atPath: TestDatabase.settings.path))
	}
	
	@Test func memoryDatabase() async throws {
		let db = try await SettingsMemoryFirst.db()
		#expect(await db.dbURL == nil)
		
		var item = await SettingsMemoryFirst.create()
		item.name = "in memory"
		try await item.save()
		#expect(try await SettingsMemoryFirst.fetchId(item.id).name == "in memory")
		
		// auto-close would discard the data, so a memory database stays open
		await db.setAutoClose(after: 0.05)
		try await Task.sleep(for: .milliseconds(200))
		#expect(await db.isClosed == false)
		#expect(try await SettingsMemoryFirst.fetchId(item.id).name == "in memory")
	}
	
	@Test func equalSettingsShareConnection() async throws {
		#expect(try await SettingsFirst.db() === SettingsSecond.db())
		#expect(try await SettingsMemoryFirst.db() === SettingsMemorySecond.db())
		#expect(try await SettingsFirst.db() !== SettingsMemoryFirst.db())
	}
	
	@Test func sameFileDifferentOptionsShareConnection() async throws {
		#expect(SettingsSameFileOtherOptions.autoDBSettings != SettingsFirst.autoDBSettings)
		#expect(try await SettingsFirst.db() === SettingsSameFileOtherOptions.db())
	}
	
	@Test func refinedProtocolAndOwnDeclarationWin() async throws {
		#expect(SettingsGrouped.autoDBSettings == TestDatabase.settingsGroup)
		#expect(SettingsGroupedOverride.autoDBSettings == TestDatabase.settings)
		
		let grouped = try await SettingsGrouped.db()
		#expect(await grouped.dbURL?.path == TestDatabase.settingsGroup.path)
		#expect(try await SettingsGroupedOverride.db() === SettingsFirst.db())
	}
	
	@Test func location() {
		#expect(AutoDBManager.location(for: .memory) == .memory)
		#expect(AutoDBManager.location(for: TestDatabase.settings) == .file(TestDatabase.settings.path))
		
		guard case .file(let regular) = AutoDBManager.location(for: .regular), case .file(let cache) = AutoDBManager.location(for: .cache) else {
			Issue.record(".regular and .cache should be files")
			return
		}
		#expect(regular.hasSuffix("/" + AutoDBSettings.regular.path))
		#expect(cache.hasSuffix("/" + AutoDBSettings.cache.path))
		#expect(regular != cache)
	}
}
