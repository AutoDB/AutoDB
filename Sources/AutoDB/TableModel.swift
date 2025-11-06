//
//  TableModel.swift
//  AutoDB
//
//  Created by Olof Andersson-Thorén on 2025-03-10.
//

/// Functionality common for the Table and the Model
public protocol TableModel {
	
	var id: AutoId { get }
	
	static func rowChangeObserver() async throws -> RowChangeObserver
	static func tableChangeObserver() async throws -> TableChangeObserver
	
	/// Fetch one object, throw missingId if no object was found
	static func fetchId(token: AutoId?, _ id: AutoId, _ identifier: ObjectIdentifier?) async throws -> Self
	static func fetchIds(token: AutoId?, _ ids: [AutoId], _ identifier: ObjectIdentifier?) async throws -> [Self]
	
	/// Fetch all objects matching this query.
	static func fetchQuery(token: AutoId?, _ query: String, _ arguments: [Sendable]?, sqlArguments: [SQLValue]?) async throws -> [Self]
	
	/// a general query with arguments of unknown type
	@discardableResult
	static func query(token: AutoId?, _ query: String, _ arguments: [Sendable]?) async throws -> [Row]
	
	// this cannot have the same signature
	/// a general query with arguments of converted types
	@discardableResult
	static func query(token: AutoId?, _ query: String, sqlArguments: [SQLValue]?) async throws -> [Row]
	
	// MARK: - saving
	
	/// called before storing to DB, default implementation does nothing
	static func willSave(_ objects: [Self]) async throws
	/// called after storing to DB, default implementation does nothing
	static func didSave(_ objects: [Self]) async throws
	
	// MARK: - deletion
	
	var isDeleted: Bool { get async }
}

public extension TableModel {
	var isDeleted: Bool {
		get async {
			false
		}
	}
}

/// AutoId is just a basic unsigned int, with the last 4 bits untouched for Swift-optimizations
public typealias AutoId = UInt64
public extension AutoId {
	static func generateId() -> AutoId {
		
		let random = random(in: 1..<AutoId.max)
		return random >> 4  //save some bits for Swift's optimisations
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
}

public enum TableError: Error {
	case notAutoModelClass
	case impossibleUrlMigration
}

///Class specific settings to generate SQL information that can't be known automatically, each DB needs to define its path and cache settings. Then every table may subscribe to one of these settings, if none is chosen the default will be used
public struct AutoDBSettings: Sendable, Hashable {
	
	// Cache settings-shorthand for all tables to be stored in the cache
	static func cache(path: String = "AutoDB/AutoDB.db") -> AutoDBSettings {
		AutoDBSettings(path: path, iCloudBackup: false, inAppFolder: false, inCacheFolder: true)
	}
	
	// Common settings for all tables to be stored in the app-folder and allow for being backed up.
	public init(path: String = "AutoDB/AutoDB.db", iCloudBackup: Bool = true, inAppFolder: Bool = true, inCacheFolder: Bool = false) {
		self.path = path
		self.iCloudBackup = iCloudBackup
		self.inAppFolder = inAppFolder
		self.inCacheFolder = inCacheFolder
	}
	
	/// the path or fileName inside your app's supportDirectory or cachesDirectory
	let path: String
	/// Should this data be backed up and transfered to new devices?
	let iCloudBackup: Bool
	/// Is the path relative to the applications folder?
	let inAppFolder: Bool
	/// Is the path relative to the cache folder - so the system may remove it whenever the user is low on disc-space?
	let inCacheFolder: Bool
	
	/// Should this get its own unique actor to issue queries from, or share with other tables with the same DB-file? If you have a lot of writes it is usually FASTER to share (one actor are better at scheduling than many SQLite connectors who uses locks with busy/retries). In normal usage you won't see any difference so there is typically no need to split them up. It may improve performance in some esotheric situations, so the option is available. Measure!
	// let shareDB: Bool // this was a bad idea and is always worse. Don't do it.
}

public typealias AnyTable = (any Table)

/// A set of column names.
public typealias ColumnNames = Set<String>
