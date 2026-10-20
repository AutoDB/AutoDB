//
//  TableModel.swift
//  AutoDB
//
//  Created by Olof Andersson-Thorén on 2025-03-10.
//

/// Functionality common for the Table and the Model
public protocol TableModel: Sendable, Hashable {
	
	var id: AutoId { get }
	
	static func rowChangeObserver() async throws -> RowChangeObserver
	static func tableChangeObserver() async throws -> TableChangeObserver
	
	/// Fetch one object, throw missingId if no object was found
	static func fetchId(_ id: AutoId, _ identifier: ObjectIdentifier?) async throws -> Self
	static func fetchIds(_ ids: [AutoId], _ identifier: ObjectIdentifier?) async throws -> [Self]
	
	/// Fetch all objects matching this query.
	static func fetchQuery(_ query: String, _ arguments: [Sendable]?, sqlArguments: [SQLValue]?) async throws -> [Self]
	
	/// a general query with arguments of unknown type
	@discardableResult
	static func query(_ query: String, _ arguments: [Sendable]?) async throws -> [Row]
	
	// this cannot have the same signature
	/// a general query with arguments of converted types
	@discardableResult
	static func query(_ query: String, sqlArguments: [SQLValue]?) async throws -> [Row]
	
	// MARK: - saving
	
	/// called before storing to DB, default implementation does nothing
	static func willSave(_ objects: [Self]) async throws
	/// called after storing to DB, default implementation does nothing
	static func didSave(_ objects: [Self]) async throws
	
	// MARK: - deletion
	
	var isDeleted: Bool { get async }
}

public extension Collection where Element: TableModel {
	
	/// Convert an array with AutoModels to a dictionary
	func dictionary() -> [AutoId: Element] {
		let uniqueSet = Set(self)
		return Dictionary(uniqueKeysWithValues: uniqueSet.map { ($0.id, $0) })
	}
	
	/// Sort by ids, when you want the objects returned to be in the same order as fetched: fetchIds(idsToFetch).sortById(idsToFetch)
	func sortById(_ ids: [AutoId]) -> [Element] {
		dictionary().sortById(ids)
	}
	
	// fetch relations from multiple objects in one request
	func fetchAll<T: RelationToOne>(_ keyPath: KeyPath<Element, T>) async throws {
		if self.isEmpty { return }
		guard let list = (self as? [Self.Element]) ?? (Array(self) as? [Self.Element]) else {
			throw AutoError.missingSetup
		}
		
		if list.isEmpty { return }
		let objects: [T] = list.map { $0[keyPath: keyPath] }
		try await objects[0].fetchAll(objects)
	}
}

public extension Dictionary where Key == AutoId, Value: TableModel {
	
	/// If you need to fetch items in the order of ids, Fetch as dictionary and apply this. See fetch() in AutoRelations for an example
	func sortById(_ ids: [AutoId]) -> [Value] {
		ids.compactMap { self[$0] }
	}
}

public extension TableModel {
	var isDeleted: Bool {
		get async {
			false
		}
	}
}

public enum AutoError: Error {
	case fetchError
	/// we must have an id to create AutoModel objects
	case missingId
	/// Somehow this table was never setup
	case missingSetup
	/// one or more object has been deleted or never saved, but the relation wasn't updated.
	case missingRelation
	/// if you don't have FTS5 support, you cannot use full text search
	case noFTSSupport
	/// unique constraint failed, you tried to insert an object that already exists, it may return a list of the conflicting ids - if trying to save new non-objects this list can be empty.
	case uniqueConstraintFailed([AutoId])
	/// requireScope() was called on the manager and a table was used without a scope, the message names the table
	case noScope(String)
}

public enum TableError: Error {
	case notAutoModelClass
	case impossibleUrlMigration
}

/// Where a database lives and how its connection behaves. Tables pick one through `Table.autoDBSettings`, equal settings share one connection.
public struct AutoDBSettings: Sendable, Hashable {
	
	/// The default file in the app's support folder, backed up.
	public static let regular = AutoDBSettings()
	/// A file in the cache folder, never backed up - the system may remove it when the device is low on disc-space.
	public static let cache = AutoDBSettings.cache()
	/// An in-memory database, shared by every table using it. It never auto-closes and is gone when the process ends.
	public static let memory = AutoDBSettings(path: "", iCloudBackup: false, inAppFolder: false, inCacheFolder: false, autoCloseDelay: nil, inMemory: true)
	
	/// Cache settings-shorthand for tables stored in the cache folder.
	public static func cache(path: String = "AutoDB/AutoDB.db") -> AutoDBSettings {
		AutoDBSettings(path: path, iCloudBackup: false, inAppFolder: false, inCacheFolder: true)
	}
	
	/// Common settings for all tables to be stored in the app-folder and allow for being backed up. With both folder flags false, path is absolute.
	public init(path: String = "AutoDB/AutoDB.db", iCloudBackup: Bool = true, inAppFolder: Bool = true, inCacheFolder: Bool = false, autoCloseDelay: Double? = AutoDBManager.defaultWaitTime) {
		self.init(path: path, iCloudBackup: iCloudBackup, inAppFolder: inAppFolder, inCacheFolder: inCacheFolder, autoCloseDelay: autoCloseDelay, inMemory: false)
	}
	
	init(path: String, iCloudBackup: Bool, inAppFolder: Bool, inCacheFolder: Bool, autoCloseDelay: Double?, inMemory: Bool) {
		self.path = path
		self.iCloudBackup = iCloudBackup
		self.inAppFolder = inAppFolder
		self.inCacheFolder = inCacheFolder
		self.autoCloseDelay = autoCloseDelay
		self.inMemory = inMemory
	}
	
	/// the path or fileName inside your app's supportDirectory or cachesDirectory
	public let path: String
	/// Should this data be backed up and transfered to new devices?
	public let iCloudBackup: Bool
	/// Is the path relative to the applications folder?
	public let inAppFolder: Bool
	/// Is the path relative to the cache folder - so the system may remove it whenever the user is low on disc-space?
	public let inCacheFolder: Bool
	/// Auto-close the connection after this many seconds of non-use (it reopens transparently on the next access), nil keeps it open until closed manually.
	public let autoCloseDelay: Double?
	/// Keep the database in memory instead of a file, path and folder flags are ignored.
	public let inMemory: Bool
	
	/// Should this get its own unique actor to issue queries from, or share with other tables with the same DB-file? If you have a lot of writes it is usually FASTER to share (one actor are better at scheduling than many SQLite connectors who uses locks with busy/retries). In normal usage you won't see any difference so there is typically no need to split them up. It may improve performance in some esotheric situations, so the option is available. Measure!
	// let shareDB: Bool // this was a bad idea and is always worse. Don't do it.
}

/// Where a database's data lives, settings resolving to the same location share one connection.
enum DatabaseLocation: Hashable {
	case memory
	case file(String)
}

public typealias AnyTable = (any Table)

/// A set of column names.
public typealias ColumnNames = Set<String>
