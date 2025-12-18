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
public protocol FTSCallbackOwner: TableModel {
	
	// what text for these ids should be used in the fast-text-index?
	static func textCallback(_ ids: [AutoId]) async -> [AutoId: String]
}

typealias TextCallbackSignature = (@Sendable ([AutoId]) async -> [AutoId: String]?)

/// Store information about the FTS-columns/tables so we can use static functions.
struct FTSTableInfo {
	let tableName: String
	let targetTableName: String
	var textCallback: TextCallbackSignature?
}

/// A helper class for handling FTS columns in a thread-safe manner.
actor FTSHandler {
	
	private init() {}
	static let shared = FTSHandler()
	
	/// this table's FTS column is locked by semaphore when searching and setting up - note that we only use one semaphore per table even if you have multiple FTS columns.
	var columnLock = [ObjectIdentifier: Semaphore]()
	var ftsTables = [ObjectIdentifier: [String : FTSTableInfo]]()	// note that each table can have multiple FTS columns
	
	// return true if this is the first time called
	func setup<TargetTableType: TableModel>(_ type: TargetTableType.Type, _ column: String, _ typeID: ObjectIdentifier, _ targetTableName: String) async throws -> Bool {
		
		if ftsTables[typeID]?[column] != nil {
			return false
		}
		if ftsTables[typeID] == nil {
			ftsTables[typeID] = [:]
		}
		let tableName = "\(targetTableName)\(column)Table"
		ftsTables[typeID]?[column] = FTSTableInfo(tableName: tableName, targetTableName: targetTableName)
		
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
			try await TargetTableType.query(token: nil, sqlStatement, nil)
		} catch {
			throw error
		}
		
		// Keep deleted and updated data up to date with triggers, if we delete or update text in the target-table we must delete it from the FTS-table (it will later be re-indexed).
		let deleteTrigger = """
		CREATE TRIGGER IF NOT EXISTS `\(tableName)Delete` AFTER DELETE ON `\(targetTableName)` BEGIN
			DELETE FROM `\(tableName)` WHERE `\(tableName)`.id = OLD.id;
		END;
		"""
		try await TargetTableType.query(token: nil, deleteTrigger, nil)
		
		
		let updateTrigger = """
		CREATE TRIGGER IF NOT EXISTS `\(tableName)Update` AFTER UPDATE ON `\(targetTableName)` BEGIN
			DELETE FROM `\(tableName)` WHERE `\(tableName)`.id = OLD.id;
		END;
		"""
		try await TargetTableType.query(token: nil, updateTrigger, nil)
		
		let insertTrigger = """
		CREATE TRIGGER IF NOT EXISTS `\(tableName)Insert` AFTER INSERT ON `\(targetTableName)` BEGIN
			DELETE FROM `\(tableName)` WHERE `\(tableName)`.id = NEW.id;
		END;
		"""
		try await TargetTableType.query(token: nil, insertTrigger, nil)
		try await TargetTableType.query(token: nil, "PRAGMA trusted_schema=1;", nil)
		
		return true
	}
	
	func setTextCallback(_ typeID: ObjectIdentifier, _ column: String, _ callback: @escaping TextCallbackSignature) {
		ftsTables[typeID]?[column]?.textCallback = callback
	}
}

/// A virtual column for fast text search, that does not need to be stored in DB alongside your other columns (but can for simplicity).
public final class FTSColumn<TargetTableType: Table>: Codable, Relation, @unchecked Sendable {
	
	public static func == (lhs: FTSColumn<TargetTableType>, rhs: FTSColumn<TargetTableType>) -> Bool {
		lhs.column == rhs.column
	}
	
	weak var owner: Owner? = nil
	
	private var column: String
	private var targetTableName: String {
		TargetTableType.tableName
	}
	
	init(_ column: String) {
		self.column = column
		Task {
			try await setup(TargetTableType.self)
		}
	}
	
	/// if owner implements FTSCallbackOwner, it gets handled automatically. Otherwise it will import text directly from the column with the same name
	public func setOwner<OwnerType: Owner>(_ owner: OwnerType) {
		self.owner = owner
		Task {
			if let ftsOwner = owner as? (any FTSCallbackOwner) {
				await setCallbackOwner(ftsOwner)
			}
		}
	}
	
	/// Calls setCallbackOwner for this class type, the reason this function exist is to circumvent Swift's type system and allows us to call a static func using an object.
	public func setCallbackOwner<T: FTSCallbackOwner>(_ object: T) async {
		if let modelClass = object as? any Model {
			await setCallbackOwner(T.self, modelClass.valueIdentifier)
		} else {
			await setCallbackOwner(T.self)
		}
		
	}
	
	/// override the default implementation to let some other class handle processing the text for this FTS column. It will detect changes per id, and ask about the text for those.
	public func setCallbackOwner<T: FTSCallbackOwner>(_ ftsOwner: T.Type, _ typeID: ObjectIdentifier? = nil) async {
		
		let typeID = typeID ?? ObjectIdentifier(ftsOwner)
		await FTSHandler.shared.setTextCallback(typeID, column, ftsOwner.textCallback)
	}
	
	// we must store the column in order for Codable to work.
	private enum CodingKeys: CodingKey {
		case column
	}
	
	/// Connect this FTS column with a table
	public func setup<T: Table>(_ tableType: T.Type) async throws {
		let column = column
		let typeID = ObjectIdentifier(T.self)
		let firstSetup = try await FTSHandler.shared.setup(T.self, column, typeID, targetTableName)
		
		if firstSetup {
			try await setupCallback(T.self, typeID)
		}
	}
	
	/// set up the callback for fetching missing text
	func setupCallback<T: Table>(_ tableType: T.Type, _ typeID: ObjectIdentifier) async throws {
		
		// allow fetching all missing ids in one go.
		let column = self.column
		let targetTableName = self.targetTableName
		let textCallback: TextCallbackSignature = { ids in
			let questionMarks = AutoDBManager.questionMarks(ids.count)
			var result = [AutoId: String]()
			for row in (try? await T.query(token: nil, "SELECT id, `\(column)` FROM `\(targetTableName)` WHERE id IN (\(questionMarks))", ids)) ?? [] {
				if let id = row["id"]?.uint64Value, let text = row[column]?.stringValue {
					result[id] = text
				}
			}
			return result
		}	
		
		await FTSHandler.shared.setTextCallback(typeID, column, textCallback)
	}
	
	/// insert missing text into the index
	static func populateIndex(_ column: String) async throws {
		
		let typeID = ObjectIdentifier(TargetTableType.self)
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
		
		let isEmpty: Bool = try await TargetTableType.valueQuery("SELECT count(*) = 0 as isEmpty FROM `\(tableInfo.tableName)`")
		if isEmpty {
			// sometimes these indieces gets messed up, then the join below will always return nothing. Fix that by deleting all and starting over.
			try await TargetTableType.query("DELETE FROM `\(tableInfo.tableName)`")
		}
		
		let limit = 20000	// any limit will do, just make it small enough to not take noticable RAM/CPU per fetch, while big enough to handle most updates in one go.
		let query = "SELECT id FROM `\(tableInfo.targetTableName)` WHERE id NOT in (SELECT id FROM `\(tableInfo.tableName)`) LIMIT \(limit)"
		let ids = try await TargetTableType.query(query).flatMap { $0.values.compactMap { $0.uint64Value } }
		if ids.isEmpty {
			return
		}
		if let changeList = await textCallback(ids) {
			
			// turn changeList into an id, text array by mapping SQLValues since we know what to use. TODO: allow other transforms than removeDiacritics
			let args = changeList.map { item in
				[SQLValue.uinteger(item.key), SQLValue.text(removeDiacritics(item.value))]
			}.flatMap { $0 }
			
			let questionMarks = AutoDBManager.questionMarksForQueriesWithObjects(ids.count, 2)
			try await TargetTableType.query("INSERT OR REPLACE INTO `\(tableInfo.tableName)` (id, text) VALUES \(questionMarks)", sqlArguments: args)
		}
		if ids.count == limit {
			try await populateIndexIterate(typeID, column)
		}
	}
	
	/// search for a phrase in the index when you only have one FTS-column, return matching objects, ordered by rank (FTS5 measure of relevance)
	public static func search(_ phrase: String, limit: Int = 2000, offset: Int = 0) async throws -> [TargetTableType] {
		
		let typeID = ObjectIdentifier(TargetTableType.self)
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
	public func search(_ phrase: String, limit: Int = 2000, offset: Int = 0) async throws -> [TargetTableType] {
		try await Self.search(phrase, limit: limit, offset: offset, column: column)
	}
	
	/// search for a phrase in the index, return matching objects, ordered by rank (FTS5 measure of relevance)
	static func search(_ phrase: String, limit: Int = 2000, offset: Int = 0, column: String) async throws -> [TargetTableType] {
		
		// make sure all text is indexed, but also locking & setup. We must avoid doing this work until needed, and after any owners are set.
		try await Self.populateIndex(column)
		
		let typeID = ObjectIdentifier(TargetTableType.self)
		guard let tableInfo = await FTSHandler.shared.ftsTables[typeID]?[column] else {
			return []
		}
		return try await search(phrase, limit: limit, offset: offset, tableInfo: tableInfo)
	}
	
	static private func search(_ phrase: String, limit: Int = 2000, offset: Int = 0, tableInfo: FTSTableInfo) async throws -> [TargetTableType] {
		
		//https://www.sqlite.org/fts5.html
		let query = "SELECT id FROM `\(tableInfo.tableName)` WHERE text MATCH ? ORDER BY rank LIMIT ? OFFSET ?"
		let ids = try await TargetTableType.query(query, [phrase, limit, offset]).ids()
		return try await TargetTableType.fetchIds(ids)
	}
	
	/// Only remove diacritics for chars that has the same meaning without them, "lizard" and "farming" is not related! (Ödla vs Odla) While "fiancé" vs "fiance" has the same meaning.
	static func removeDiacritics(_ phrase: String) -> String {
		let regular = Set("äöåÖÄÅ".precomposedStringWithCanonicalMapping)
		return String(phrase.precomposedStringWithCanonicalMapping.map { regular.contains($0) ? $0 : String($0).folding(options: .diacriticInsensitive, locale: nil).first! })
	}
}

