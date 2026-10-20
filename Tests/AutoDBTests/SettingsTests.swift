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
import AutoDBTesting

/// the suite runs under .autoDB, so these land in its folder
private let settingsFile = AutoDBSettings.cache(path: "SettingsTests.db")
private let settingsGroupFile = AutoDBSettings.cache(path: "SettingsTestsGroup.db")

private struct SettingsFirst: Table {
	static let autoDBSettings = settingsFile
	var id: AutoId = 0
	var name = ""
}

private struct SettingsSecond: Table {
	static let autoDBSettings = settingsFile
	var id: AutoId = 0
	var name = ""
}

/// same file as settingsFile but other options - it must share the first one's connection
private struct SettingsSameFileOtherOptions: Table {
	static let autoDBSettings = AutoDBSettings(path: settingsFile.path, iCloudBackup: false, inAppFolder: false, inCacheFolder: true, autoCloseDelay: nil)
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
	static var autoDBSettings: AutoDBSettings { settingsGroupFile }
}

private struct SettingsGrouped: SettingsGroupTable {
	var id: AutoId = 0
	var name = ""
}

/// the type's own declaration beats its group's
private struct SettingsGroupedOverride: SettingsGroupTable {
	static let autoDBSettings = settingsFile
	var id: AutoId = 0
	var name = ""
}

@Suite(.autoDB)
struct SettingsTests {
	
	@Test func explicitPathIsUsed() async throws {
		let db = try await SettingsFirst.db()
		let path = try #require(AutoDBManager.current.fileURL(for: settingsFile)?.path)
		#expect(path.hasSuffix("/SettingsTests/Caches/SettingsTests.db"))
		#expect(await db.dbURL?.path == path)
		#expect(FileManager.default.fileExists(atPath: path))
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
		#expect(SettingsGrouped.autoDBSettings == settingsGroupFile)
		#expect(SettingsGroupedOverride.autoDBSettings == settingsFile)
		
		let grouped = try await SettingsGrouped.db()
		#expect(await grouped.dbURL?.path == AutoDBManager.current.fileURL(for: settingsGroupFile)?.path)
		#expect(try await SettingsGroupedOverride.db() === SettingsFirst.db())
	}
	
	@Test func location() {
		#expect(AutoDBManager.location(for: .memory) == .memory)
		let absolute = AutoDBSettings(path: "/tmp/AutoDB/absolute.db", iCloudBackup: false, inAppFolder: false, inCacheFolder: false)
		#expect(AutoDBManager.location(for: absolute) == .file(absolute.path))
		
		guard case .file(let regular) = AutoDBManager.location(for: .regular), case .file(let cache) = AutoDBManager.location(for: .cache) else {
			Issue.record(".regular and .cache should be files")
			return
		}
		#expect(regular.hasSuffix("/" + AutoDBSettings.regular.path))
		#expect(cache.hasSuffix("/" + AutoDBSettings.cache.path))
		#expect(regular != cache)
	}
}
