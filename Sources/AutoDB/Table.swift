import Foundation

/// All table structs must implement AutoDB and be Sendable.
public protocol Table: Codable, Hashable, Identifiable, Sendable, TableModel {
	typealias ColumnKeyPath = PartialKeyPath<Self>
	var allKeyPaths: [String: ColumnKeyPath] { get }
	
	// To construct tables we must create empty objects, since Swift doesn't allow meta programming
	init()
	// Sometimes you know the id, then the object needs to be returned or created. and inserted into DB at next save
	static func create(token: AutoId?, _ id: AutoId?) async -> Self
	/// The unique id that identifies this object
	var id: AutoId { get set }
	static func autoDBSettings() async -> AutoDBSettings? //implement using "class func ..."
	
	/// The table name to use for storage, must be unique, good when having models inside modelObjects.
	static var typeName: String { get }
	
	/// return a list of keypaths to the variables that have index, grouped together to make multi-column index
	/// We can't use KeyPaths, so we have to check indices in runtime instead.
	static var indices: [[String]] { get }
	/// return a list of keypaths to the variables that have unique index, grouped together to make multi-column index
	static var uniqueIndices: [[String]] { get }
	
	/*
	 Note that the save functions are not exposed, since no need to implement them.
	 Understand that if your Table has a Model, you must call save or saveChanges (etc) on the model.
	 
	/// save and wait until completed, potentially handling errors
	func save(token: AutoId?) async throws
	/// save and don't wait until completed, ignoring errors
	//func save(token: AutoId?) - if we don't include it in the protocol Swift adds it from the extension - but then it won't call the function in concrete types?
	*/
}

/// When using classes we must loop through every value and check equallity - Note that structs handle this automatically.
public extension Table where Self: AnyObject {
	
	static func == (lhs: Self, rhs: Self) -> Bool {
		if lhs.id != rhs.id {
			return false
		}
		
		let rhsPaths = rhs.allKeyPaths
		for (column, path) in lhs.allKeyPaths {
			guard let pathR = rhsPaths[column] else {
				return false
			}
			let lhsValue = lhs[keyPath: path] as? AnyHashable
			let rhsValue = rhs[keyPath: pathR] as? AnyHashable
			
			if lhsValue != rhsValue {
				return false
			}
		}
		return true
	}
}

public extension Table {
	
	private subscript(checkedMirrorDescendant key: String) -> Any {
		return Mirror(reflecting: self).descendant(key)!
	}
	
	var allKeyPaths: [String: ColumnKeyPath] {
		var membersToKeyPaths = [String: ColumnKeyPath]()
		let mirror = Mirror(reflecting: self)
		for case (let key?, _) in mirror.children {
			membersToKeyPaths[key] = \Self.[checkedMirrorDescendant: key] as PartialKeyPath
		}
		return membersToKeyPaths
	}
	
	func hash(into hasher: inout Hasher) {
		hasher.combine(id)
	}
    
    /// a shortcut to get the name of the class as a string, to be used in SQL queries
    var typeName: String {
		Self.typeName
    }
    
    /// class shortcut to string name
    static var typeName: String {
        String(describing: self)
    }
	
	static var identifier: ObjectIdentifier {
		ObjectIdentifier(self)
	}
	
	/// async version of create, always call this one if you can
	static func create(token: AutoId? = nil, _ id: AutoId? = nil) async -> Self {
		if let id, let item = try? await fetchId(token: token, id) {
			return item
		}
		
		// no id or not in DB, create new object
		var item = Self()
		item.id = id ?? AutoId.generateId()
		
		await AutoDBManager.shared.setCreated(item.id, ObjectIdentifier(self))
		
		return item
	}
	
	/// sync version of create, if you must
	
	
	static func create(token: AutoId? = nil, _ id: AutoId? = nil) -> Self {
		let semaphore = DispatchSemaphore(value: 0)
		
		let store = Store<Self>()
		Task {
			store.item = await create(token: token, id)
			semaphore.signal()
		}
		semaphore.wait()
		
		return store.item!
	}
	
	func awakeFromFetch() {}
	
	/// Get this class AutoDB which allows direct SQL-access. You may setup db and override the class' settings, the first time you call this
	@discardableResult
	static func db(_ settings: AutoDBSettings? = nil) async throws -> Database {
		let settings = if settings == nil {
			await autoDBSettings()
		} else {
			settings
		}
		return try await AutoDBManager.shared.setupDB(self, nil, settings: settings)
	}
	
	/// Run actions inside a transaction - any thrown error causes the DB to rollback (and the error is rethrown).
	/// ⚠️  Must use token for all db-access inside transactions, otherwise will deadlock. ⚠️
	/// Why? Since async/await and actors does not and can not deal with threads, there is no other way of knowing if you are inside the transaction / holding the lock.
	static func transaction<R: Sendable>(_ action: (@Sendable (_ db: isolated Database, _ token: AutoId) async throws -> R) ) async throws -> R {
		try await db().transaction(action)
	}
	
	/// Implement this to specify path to the database, or other settings.
	/// e.g. return a common setting like this:
	/// 	await AutoDBManager.shared.appSettings(for: .cache)
	static func autoDBSettings() async -> AutoDBSettings? {
		nil
	}
	
	/// return a list of variable names that have index, group together to make multi-column index
	static var indices: [[String]] { [] }
	/// return a list of variable names that have unique index, group together to make multi-column index
	static var uniqueIndices: [[String]] { [] }
	
	// MARK: - fetch shortcuts
	
	static func fetchId(token: AutoId? = nil, _ id: AutoId, _ identifier: ObjectIdentifier? = nil) async throws -> Self {
		
		try await AutoDBManager.shared.fetchId(token: token, id, identifier)
	}
	static func fetchIds(token: AutoId? = nil, _ ids: [AutoId], _ identifier: ObjectIdentifier? = nil) async throws -> [Self] {
		if ids.isEmpty {
			return []
		}
		return try await AutoDBManager.shared.fetchIds(token: token, ids, identifier)
	}
	
	static func fetchQuery(token: AutoId? = nil, _ query: String = "", _ arguments: [Sendable]? = nil, sqlArguments: [SQLValue]? = nil) async throws -> [Self] {
		try await AutoDBManager.shared.fetchQuery(token: token, query, arguments: arguments, sqlArguments: sqlArguments)
	}
	
	
	@discardableResult
	static func query(token: AutoId? = nil, _ query: String = "", _ arguments: [Sendable]? = nil) async throws -> [Row] {
		try await AutoDBManager.shared.query(token: token, Self.self, query, arguments)
	}
	
	/// Execute a query without returning any rows, like INSERT or UPDATE.
	static func execute(token: AutoId? = nil, _ query: String = "", _ arguments: [Sendable]? = nil, sqlArguments: [SQLValue]? = nil) async throws {
		try await AutoDBManager.shared.execute(token: token, Self.self, query, arguments, sqlArguments: sqlArguments)
	}
	
	// this cannot have the same signature
	@discardableResult
	static func query(token: AutoId? = nil, _ query: String = "", sqlArguments: [SQLValue]? = nil) async throws -> [Row] {
		try await AutoDBManager.shared.query(token: token, Self.self, query, sqlArguments: sqlArguments ?? [])
	}
	
	/// A non-throwable query, returns nil instead of throwing
	@discardableResult
	static func queryNT(token: AutoId? = nil, _ query: String = "", arguments: [Sendable]? = nil) async -> [Row]? {
		try? await AutoDBManager.shared.query(token: token, Self.self, query, arguments)
	}
	
	// MARK: - common queries
	
	/// return the first value of the first row of the result,
	/// throws fetchError if the value is nil 
	static func valueQuery<Val: SQLColumnWrappable>(token: AutoId? = nil, _ query: String = "", _ arguments: [Sendable]? = nil, sqlArguments: [SQLValue]? = nil) async throws -> Val {
		if let value: Val = try await AutoDBManager.shared.valueQuery(token: token, Self.self, query, arguments, sqlArguments: sqlArguments) {
			return value
		}
		throw AutoError.fetchError
	}
	
	///return an array with all values in the result for a (the first) column.
	static func groupConcatQuery<Val: SQLColumnWrappable>(token: AutoId? = nil, _ query: String = "", _ arguments: [Sendable]? = nil) async throws -> [Val] {
		try await AutoDBManager.shared.groupConcatQuery(token: token, Self.self, query, arguments)
	}
	
	/// When you don't need to wait for the save procedure
	func save(token: AutoId? = nil) {
		Task.detached {
			try? await self.save(token: token)
		}
	}
	
	/// Tell the manager to save this object
	func save(token: AutoId? = nil) async throws {
		try await Self.saveList(token: token, [self])
	}
	
	static func willSave(_ objects: [Self]) async throws {}
	static func didSave(_ objects: [Self]) async throws {}
	
	static func saveList(token: AutoId? = nil, _ objects: [Self]) async throws {
		try await saveList(token: token, objects, onlyUpdated: nil)
	}
	
	/// All save functions ends up here, where we encode the objects to SQL queries, store them, remove from isChanged and call did/will save.
	static func saveList(token: AutoId? = nil, _ objects: [Self], onlyUpdated: Bool?) async throws {
		
		let typeID = ObjectIdentifier(self)
		
		// don't re-save deleted items
		let deletedIds = await AutoDBManager.shared.isDeleted(typeID)
		let objects = objects.filter { deletedIds.contains($0.id) == false }
		guard objects.isEmpty == false else { return }
		
		try await willSave(objects)
		
		let encoder = try await AutoDBManager.shared.getEncoder(Self.self, typeID)
		await encoder.semaphore.wait()
		defer { Task { await encoder.semaphore.signal() }}
		
		// separate insert and update, otherwise update will overwrite existing objects.
		let updated: [Self]
		let created: [Self]
		if onlyUpdated == true {
			// we only have updated objects, so we can skip the created check
			updated = objects
			created = []
		}
		else if onlyUpdated == false {
			// we only have created objects, so we can skip the updated check
			updated = []
			created = objects
		}
		else {
			let result = await AutoDBManager.shared.filterCreated(typeID, objects)
			created = result.created
			updated = result.updated
		}
		
		if updated.isEmpty == false {
			for object in updated {
				try object.encode(to: encoder)
			}
			// apply dbSemaphoreToken if we have one
			try await encoder.commit(token, update: true)
		}
		if created.isEmpty == false {
			for object in created {
				try object.encode(to: encoder)
			}
			do {
				// apply dbSemaphoreToken if we have one
				try await encoder.commit(token, update: false)
			} catch Database.Error.uniqueConstraintFailed {
				
				// return an error with a list of ids that caused the failure. If the user cares, they can fetch the objects
				var duplicates = [AutoId]()
				for object in created {
					
					for uniqueIndexSet in Self.uniqueIndices {
						let values: [Any?] = uniqueIndexSet.map { object[keyPath: object.allKeyPaths[$0]!] }
						let arguments = try values.map {
							// we must cast or somehow find out which SQL-type each argument is!
							try SQLValue.fromAny($0)
						}
						let query = "SELECT id FROM \(Self.typeName) WHERE \(uniqueIndexSet.map { "\($0) = ?" }.joined(separator: " AND "))"
						if let existing: AutoId = try? await Self.valueQuery(token: token, query, sqlArguments: arguments) {
							duplicates.append(existing)
						}
					}
				}
				throw AutoError.uniqueConstraintFailed(duplicates)
			}
			await AutoDBManager.shared.clearCreated(typeID, created)
		}
		
		try await didSave(objects)
	}
	
	// MARK: - deletions
	
	static func truncateTable() async throws {
		
		try await AutoDBManager.shared.truncateTable(Self.self)
	}
	
	var isDeleted: Bool {
		get async {
			await AutoDBManager.shared.isDeleted(id, ObjectIdentifier(Self.self))
		}
	}
	
	func delete(token: AutoId? = nil) {
		Task {
			try await delete(token: token)
		}
	}
	
	func delete(token: AutoId? = nil) async throws {
		try await Self.deleteIds(token: token, [id])
	}
	
	static func deleteIds(token: AutoId? = nil, _ ids: [AutoId]) async throws {
		try await AutoDBManager.shared.delete(token: token, ids, ObjectIdentifier(self))
	}
	
	/// Batch delete
	func deleteLater() {
		let id = self.id
		Task {
			await Self.deleteIdsLater([id])
		}
	}
	
	/// Batch delete
	static func deleteIdsLater(_ ids: [AutoId]) async {
		await AutoDBManager.shared.deleteLater(ids, ObjectIdentifier(self))
	}
	
	// MARK: - callbacks
	
	/// get notified by AutoDB after saves or deletions. You can bypass this notification by crafting your own save/delete SQL.
	static func tableChangeObserver() async throws -> TableChangeObserver {
		try await AutoDBManager.shared.tableChangeObserver(Self.self)
	}
	
	/// get row-level changes from db with ids of changed rows
	static func rowChangeObserver() async throws -> RowChangeObserver {
		try await AutoDBManager.shared.rowChangeObserver(Self.self)
	}
}

public extension Collection where Element: Table {
	
	/// Shorthand to saveList() - When you don't need to wait for the save procedure
	func save(token: AutoId? = nil) where Self: Sendable {
		Task.detached {
			try? await self.save(token: token)
		}
	}
	
	/// Shorthand to saveList()
	func save(token: AutoId? = nil) async throws {
		// Do some compiler-type magic to be allowed to call...
		if let list = (self as? [Self.Element]) ?? (Array(self) as? [Self.Element]) {
			try await Element.saveList(token: token, list)
		} else {
			throw AutoError.missingSetup
		}
	}
	
	/// Convert an array with AutoModels to a dictionary
	func dictionary() -> [AutoId: Element] {
		Dictionary(uniqueKeysWithValues: self.map { ($0.id, $0) })
	}
	
	/// Sort by ids, when you want the objects returned to be in the same order as fetched: fetchIds(idsToFetch).sortById(idsToFetch)
	func sortById(_ ids: [AutoId]) -> [Element] {
		dictionary().sortById(ids)
	}
}

public extension Dictionary where Key == AutoId, Value: Table {
	
	/// If you need to fetch items in the order of ids, Fetch as dictionary and apply this. See fetch() in AutoRelations for an example
	func sortById(_ ids: [AutoId]) -> [Value] {
		ids.compactMap { self[$0] }
	}
}

/// Bridge sync and unsynced code
final class Store<T>: @unchecked Sendable {
	init() {}
	var item: T?
}
