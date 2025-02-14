//
//  FTSTable.swift
//  AutoDB
//
//  Created by Olof Andersson-Thorén on 2024-12-12.
//
import Foundation
#if canImport(Darwin)
import SQLite3
#else
import SQLCipher
#endif

// implement this protocol if you don't want textCreation to be automatically pulled from the column with the same name.
public protocol FTSOwner: AutoModelObject {
	
	// what text for this id should be used in the fast-text-index?
	func textCallback(_ ids: [AutoId]) async -> [AutoId: String]
}

typealias TextCallbackSignature = (@Sendable ([AutoId]) async -> [AutoId: String]?)

/// Store information about the FTS-columns/tables so we can use static functions.
struct FTSTableInfo {
	let tableName: String
	let ownerName: String
	var textCallback: TextCallbackSignature?
}

/// A helper class for handling FTS columns in a thread-safe manner.
actor FTSHandler {
	
	private init() {}
	static let shared = FTSHandler()
	
	/// this owner's FTS column is locked by semaphore when searching and setting up - note that we only use one semaphore per table even if you have multiple FTS columns.
	var columnLock = [ObjectIdentifier: Semaphore]()
	var ftsTables = [ObjectIdentifier: [String : FTSTableInfo]]()	// note that each owner can have multiple FTS columns
	
	// return true if this is the first time called
	func setup<OwnerType: AutoModelObject>(_ column: String, _ typeID: ObjectIdentifier, _ ownerTableName: String, _ owner: OwnerType) async throws -> Bool {
		
		if ftsTables[typeID]?[column] != nil {
			return false
		}
		if ftsTables[typeID] == nil {
			ftsTables[typeID] = [:]
		}
		let tableName = "\(ownerTableName)\(column)Table"
		ftsTables[typeID]?[column] = FTSTableInfo(tableName: tableName, ownerName: ownerTableName)
		
		// first FTS-column in the table creates the table's semaphore
		if columnLock[typeID] == nil {
			columnLock[typeID] = Semaphore()
		}
		
		// no-one is allowed to query or populate index before we are setup
		await columnLock[typeID]?.wait()
		defer { Task { await columnLock[typeID]?.signal() }}
		
		guard sqlite3_compileoption_used("ENABLE_FTS5") != 0 else {
			throw AutoError.noFTSSupport
		}
		
		// since the wrong diacritics is removed by SQLite no-one should use it. Always set remove_diacritics to 0. Instead we supply our own superiour method.
		// UNINDEXED is used to prevent the id from being inserted into the FTS-index
		let sqlStatement = "CREATE VIRTUAL TABLE IF NOT EXISTS `\(tableName)` USING FTS5(id UNINDEXED, text, tokenize='unicode61 remove_diacritics 0');"
		do {
			try await OwnerType.query(sqlStatement)
		} catch {
			throw error
		}
		
		// Keep deleted and updated data up to date with triggers, if we delete or update text in the owner-table we must delete it from the FTS-table (it will later be re-indexed).
		let deleteTrigger = """
		CREATE TRIGGER IF NOT EXISTS `\(tableName)Delete` AFTER DELETE ON `\(ownerTableName)` BEGIN
			DELETE FROM `\(tableName)` WHERE `\(tableName)`.id = OLD.id;
		END;
		"""
		try await OwnerType.query(deleteTrigger)
		
		
		let updateTrigger = """
		CREATE TRIGGER IF NOT EXISTS `\(tableName)Update` AFTER UPDATE ON `\(ownerTableName)` BEGIN
			DELETE FROM `\(tableName)` WHERE `\(tableName)`.id = OLD.id;
		END;
		"""
		try await OwnerType.query(updateTrigger)
		
		let insertTrigger = """
		CREATE TRIGGER IF NOT EXISTS `\(ownerTableName)Insert` AFTER INSERT ON `\(ownerTableName)` BEGIN
			DELETE FROM `\(tableName)` WHERE `\(tableName)`.id = NEW.id;
		END;
		"""
		try await OwnerType.query(insertTrigger)
		try await OwnerType.query("PRAGMA trusted_schema=1;")
		
		return true
	}
	
	func setTextCallback(_ typeID: ObjectIdentifier, _ column: String, _ callback: @escaping TextCallbackSignature) {
		ftsTables[typeID]?[column]?.textCallback = callback
	}
}

/// A virtual column for fast text search, that does not need to be stored in DB alongside your other columns (but can for simplicity).
class FTSColumn<AutoType: AutoModelObject>: Codable, AnyRelation, @unchecked Sendable {
	
	public typealias OwnerType = AutoType
	weak var owner: AutoType? = nil
	
	private var column: String
	
	private var ownerName: String {
		OwnerType.typeName
	}
	
	/// set textCallback to null if you only want to import text directly from the column with the same name
	init(_ column: String) {
		self.column = column
	}
	
	public func setOwner<OwnerType>(_ owner: OwnerType) where OwnerType : AutoModel {
		if let owner = owner as? AutoType {
			self.owner = owner
			Task {
				try await setup(owner)
			}
		}
	}
	
	// we must store the column in order for Codable to work.
	private enum CodingKeys: CodingKey {
		case column
	}
	
	func setup(_ owner: OwnerType) async throws {
		let column = column
		let typeID = ObjectIdentifier(OwnerType.self)
		let firstSetup = try await FTSHandler.shared.setup(column, typeID, ownerName, owner)
		
		if firstSetup {
			try await setupCallback(owner, typeID)
			
			// deleting is handled for us, but adding and updating cannot be done nilly-willy. We must go through our callback
			Task.detached {
				try await Self.populateIndex(column)
			}
		}
	}
	
	/// set up the callback for fetching missing text
	func setupCallback(_ owner: OwnerType, _ typeID: ObjectIdentifier) async throws {
		
		let textCallback: TextCallbackSignature
		if let ftsOwner = owner as? (any FTSOwner) {
			
			textCallback = { ids in
				await ftsOwner.textCallback(ids)
			}
		} else {
			
			// allow fetching all missing ids in one go.
			let column = self.column
			let ownerName = self.ownerName
			textCallback = { ids in
				let questionMarks = AutoDBManager.questionMarks(ids.count)
				var result = [AutoId: String]()
				for row in (try? await OwnerType.query("SELECT id, `\(column)` FROM `\(ownerName)` WHERE id IN (\(questionMarks))", ids)) ?? [] {
					if let id = row["id"]?.uint64Value, let text = row[column]?.stringValue {
						result[id] = text
					}
				}
				return result
			}
		}
		await FTSHandler.shared.setTextCallback(typeID, column, textCallback)
	}
	
	/// insert missing text into the index
	static func populateIndex(_ column: String) async throws {
		
		let typeID = ObjectIdentifier(OwnerType.self)
		while await FTSHandler.shared.columnLock[typeID] == nil {
			try? await Task.sleep(nanoseconds: 1_000_000)
			await Task.yield()
		}
		guard let semaphore = await FTSHandler.shared.columnLock[typeID] else {
			return
		}
		
		// at first entrence we must wait for semaphore
		await semaphore.wait()
		defer { Task { await semaphore.signal() }}
		
		try await populateIndexIterate(typeID, column)
	}
	
	static private func populateIndexIterate(_ typeID: ObjectIdentifier, _ column: String) async throws {
		
		guard let tableInfo = await FTSHandler.shared.ftsTables[typeID]?[column],
			  let textCallback = tableInfo.textCallback else {
			return
		}
		
		let limit = 20000	// any limit will do, just make it small enough to not take noticable RAM/CPU per fetch, while big enough to handle most updates in one go.
		let ids = try await OwnerType.query("SELECT id FROM `\(tableInfo.ownerName)` WHERE id NOT in (SELECT id FROM `\(tableInfo.tableName)`) LIMIT \(limit)").flatMap { $0.values.compactMap { $0.uint64Value } }
		if ids.isEmpty {
			return
		}
		if let changeList = await textCallback(ids) {
			
			// turn changeList into an id, text array!
			let args = changeList.map { item in
				[SQLValue.uinteger(item.key), SQLValue.text(removeDiacritics(item.value))]
			}.flatMap { $0 }
			
			let questionMarks = AutoDBManager.questionMarksForQueriesWithObjects(ids.count, 2)
			try await OwnerType.query("INSERT OR REPLACE INTO `\(tableInfo.tableName)` (id, text) VALUES \(questionMarks)", sqlArguments: args)
		}
		if ids.count == limit {
			try await populateIndexIterate(typeID, column)
		}
	}
	
	/// search for a phrase in the index when you only have one FTS-column, return matching objects, ordered by rank (FTS5 measure of relevance)
	static func search(_ phrase: String, limit: Int = 2000, offset: Int = 0) async throws -> [OwnerType] {
		
		let typeID = ObjectIdentifier(OwnerType.self)
		guard let tables = await FTSHandler.shared.ftsTables[typeID],
			  let firstColumn = tables.keys.first,
			  let tableInfo = tables[firstColumn]
		else {
			return []
		}
		
		try await Self.populateIndex(firstColumn)
		return try await search(phrase, limit: limit, offset: offset, tableInfo: tableInfo)
	}
	
	/// search (without needing to specify column or swift-generic types) for a phrase in the index, return matching objects, ordered by rank (FTS5 measure of relevance). It does not use the specific value from this column.
	func search(_ phrase: String, limit: Int = 2000, offset: Int = 0) async throws -> [OwnerType] {
		try await Self.search(phrase, limit: limit, offset: offset, column: column)
	}
	
	/// search for a phrase in the index, return matching objects, ordered by rank (FTS5 measure of relevance)
	static func search(_ phrase: String, limit: Int = 2000, offset: Int = 0, column: String) async throws -> [OwnerType] {
		
		// make sure all text is indexed, but also locking & setup
		try await Self.populateIndex(column)
		
		let typeID = ObjectIdentifier(OwnerType.self)
		guard let tableInfo = await FTSHandler.shared.ftsTables[typeID]?[column] else {
			return []
		}
		return try await search(phrase, limit: limit, offset: offset, tableInfo: tableInfo)
	}
	
	static private func search(_ phrase: String, limit: Int = 2000, offset: Int = 0, tableInfo: FTSTableInfo) async throws -> [OwnerType] {
		
		//https://www.sqlite.org/fts5.html
		let query = "SELECT id FROM `\(tableInfo.tableName)` WHERE text MATCH ? ORDER BY rank LIMIT ? OFFSET ?"
		let ids = try await OwnerType.query(query, [phrase, limit, offset]).ids()
		return try await OwnerType.fetchIds(ids)
	}
	
	/// Only remove diacritics for chars that has the same meaning without them, "lizard" and "farming" is not related! (Ödla vs Odla) While "fiancé" vs "fiance" has the same meaning.
	static func removeDiacritics(_ phrase: String) -> String {
		let regular = Set("äöåÖÄÅ".precomposedStringWithCanonicalMapping)
		return String(phrase.precomposedStringWithCanonicalMapping.map { regular.contains($0) ? $0 : String($0).folding(options: .diacriticInsensitive, locale: nil).first! })
	}
}
