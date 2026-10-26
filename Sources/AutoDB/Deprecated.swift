//
//  Deprecated.swift
//  AutoDB
//
//  Created by Olof Andersson-Thorén on 2026-08-22.
//
//  Removed APIs, kept as unavailable stubs so code that has not migrated stops with a migration
//  message instead of "cannot find ..." - and never starts up with a brand new, empty database.

import Foundation

// MARK: - Model storage

@available(*, deprecated, renamed: "Model", message: "Every Model keeps its value in a ModelStorage now, conform to Model")
public typealias StoredModel = Model

extension Model {
	
	@available(*, unavailable, message: "Change-tracking is automatic: replace `var value: Value { didSet { didSet(oldValue) } }` with `let storage: ModelStorage<Value>` and init it with `self.storage = ModelStorage(value)`. See 'Migrating to ModelStorage' in Documentation.md")
	public func didSet(_ oldValue: TableType) {
		fatalError("AutoDB: didSet(_:) is removed, change-tracking is automatic")
	}
}

// MARK: - Database settings

// SettingsKey and runtime registration are gone: Table.autoDBSettings is an AutoDBSettings with no default.
// These stubs exist so an app that has not migrated stops with a migration message instead of
// "cannot find SettingsKey" - and never starts up with a brand new, empty database at the default path.

@available(*, unavailable, message: "SettingsKey is removed: Table.autoDBSettings is now an AutoDBSettings. Use .regular, .cache, .memory, or the settings directly instead of .specific(settings). See 'Migrating from SettingsKey' in Documentation.md")
public enum SettingsKey: Sendable, Hashable {
	case regular
	case cache
	case memory
	case specific(AutoDBSettings)
}

extension AutoDBManager {
	
	@available(*, unavailable, message: "setAppSettings is removed: move these settings to `extension Table { static var autoDBSettings: AutoDBSettings { ... } }` or your app opens a new, empty database. See 'Migrating from SettingsKey' in Documentation.md")
	public nonisolated func setAppSettings(_ settings: AutoDBSettings, for key: SettingsKey) {
		fatalError("AutoDB: setAppSettings is removed. Move \(settings) to `extension Table { static var autoDBSettings: AutoDBSettings { ... } }`, otherwise your app opens a new, empty database. See 'Migrating from SettingsKey' in Documentation.md")
	}
	
	@available(*, unavailable, message: "appSettings(for:) is removed: read Table.autoDBSettings instead. See 'Migrating from SettingsKey' in Documentation.md")
	public nonisolated func appSettings(for key: SettingsKey) -> AutoDBSettings {
		fatalError("AutoDB: appSettings(for:) is removed, read Table.autoDBSettings instead. See 'Migrating from SettingsKey' in Documentation.md")
	}
	
	@available(*, unavailable, message: "appDefaults is removed: declare `extension Table { static var autoDBSettings: AutoDBSettings { ... } }` instead. See 'Migrating from SettingsKey' in Documentation.md")
	public static var appDefaults: [SettingsKey: AutoDBSettings] {
		fatalError("AutoDB: appDefaults is removed, declare `extension Table { static var autoDBSettings: AutoDBSettings { ... } }` instead. See 'Migrating from SettingsKey' in Documentation.md")
	}
	
	@available(*, unavailable, message: "switchDB is removed: give each test its own databases with @Suite(.autoDB) from AutoDBTesting, or run code against other files with AutoDBManager.withScope(AutoDBManager(root:)). See 'Scopes and testing' in Documentation.md")
	public func switchDB(_ newPositions: [AutoDBSettings: URL?]) async throws {
		fatalError("AutoDB: switchDB is removed, use @Suite(.autoDB) or AutoDBManager.withScope. See 'Scopes and testing' in Documentation.md")
	}
}
