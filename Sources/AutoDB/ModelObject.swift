//
//  AutoModelObject.swift
//  AutoDB
//
//  Created by Olof Andersson-Thorén on 2025-03-07.
//



/// All table classes must implement AutoDB and be @unchecked Sendable. Regular Sendable is not meaningful (must both be decodable and owned by a global actor).
public protocol ModelObject: Hashable, Identifiable, Sendable, AnyObject, RelationOwner {
	associatedtype TableType: Model
	
	/// Always called when creating an object
	init(_ value: TableType)
	
	//var originalValue: TableType { get set }
	
	/// The backing value,
	var value: TableType { get set }
	
	/// Id is owned by the Value, it can not be changed after init.
	var id: AutoId { get }
	
	/// If this object needs to be saved at some point in the future
	func didChange() async
	
	/// Called after calling the create() method, default implementation calls setOwnerOnRelations and caches object to make all future fetches return the same object (when saved)
	/// Call this method if you create objects in other ways.
	func awakeFromInit() async
	
	/// Find relationship-variables and set the owner
	func setOwnerOnRelations()
}

public extension ModelObject {
	
	var id: AutoId {
		value.id
	}
	
	static func == (lhs: Self, rhs: Self) -> Bool {
		lhs.id == rhs.id
	}
	func hash(into hasher: inout Hasher) {
		hasher.combine(id)
	}
	
	static func create(token: AutoId? = nil, _ id: AutoId? = nil) async -> Self {
		if let id {
			if let item = await AutoDBManager.shared.cached(Self.self, id) {
				return item
			} else if let item = try? await fetchId(token: token, id) {
				return item
			}
		}
		
		// no id or not in DB, create new object
		var value = TableType()
		value.id = id ?? AutoId.generateId()
		let item = Self(value)
		
		await item.awakeFromInit()
		return item
	}
	
	func setOwnerOnRelations() {
		for (_, path) in value.allKeyPaths {
			if let relation = value[keyPath: path] as? any Relation {
				relation.setOwner(self)
			}
		}
	}
	
	func awakeFromInit() async {
		await AutoDBManager.shared.cacheObject(self)
		setOwnerOnRelations()
	}
	
	/// Get this class AutoDB which allows direct SQL-access. You may setup db and override the class' settings, the first time you call this
	@discardableResult
	static func db(_ settings: AutoDBSettings? = nil) async throws -> Database {
		try await AutoDBManager.shared.setupDB(self.TableType, nil, settings: settings ?? autoDBSettings())
	}
	
	/// Run actions inside a transaction - any thrown error causes the DB to rollback (and the error is rethrown).
	/// ⚠️  Must use token for all db-access inside transactions, otherwise will deadlock. ⚠️
	/// Why? Since async/await and actors does not and can not deal with threads, there is no other way of knowing if you are inside the transaction / holding the lock.
	static func transaction<R: Sendable>(_ action: (@Sendable (_ db: isolated Database, _ token: AutoId) async throws -> R) ) async throws -> R {
		try await db().transaction(action)
	}
	
	static func autoDBSettings() -> AutoDBSettings? {
		TableType.autoDBSettings()
	}
	
	// MARK: - fetch shortcuts
	
	static func fetchId(token: AutoId? = nil, _ id: AutoId) async throws -> Self {
		
		try await AutoDBManager.shared.fetchId(token: token, id)
	}
	
	static func fetchIds(token: AutoId? = nil, _ ids: [AutoId]) async throws -> [Self] where Self: AnyObject {
		if ids.isEmpty {
			return []
		}
		return try await AutoDBManager.shared.fetchIds(token: token, ids)
	}
	
	static func fetchQuery(token: AutoId? = nil, _ query: String = "", _ arguments: [Sendable]? = nil) async throws -> [Self] where Self: AnyObject {
		try await AutoDBManager.shared.fetchQuery(token: token, query, arguments: arguments ?? [])
	}
	
	
	static func fetchQuery(token: AutoId? = nil, _ query: String = "", _ arguments: [SQLValue]? = nil) async throws -> [Self] where Self: AnyObject {
		try await AutoDBManager.shared.fetchQuery(token: token, query, arguments: arguments ?? [])
	}
	
	//
	
	/// Tell the manager to save at a later time
	func didChange() async {
		await AutoDBManager.shared.objectHasChanged(self)
	}
	
	func didChange() {
		Task {
			await AutoDBManager.shared.objectHasChanged(self)
		}
	}
	
	func refresh() async throws {
		value = try await AutoDBManager.shared.fetchId(id)
	}
	
	// MARK: - db queries
	
	@discardableResult
	static func query(token: AutoId? = nil, _ query: String = "", _ arguments: [Sendable]? = nil)  async throws -> [Row] {
		try await AutoDBManager.shared.query(token: token, TableType.self, query, arguments)
	}
	
	// this cannot have the same signature
	@discardableResult
	static func query(token: AutoId? = nil, _ query: String = "", sqlArguments: [SQLValue]? = nil)  async throws -> [Row] {
		try await AutoDBManager.shared.query(token: token, TableType.self, query, sqlArguments: sqlArguments ?? [])
	}
	
	/// A non-throwable query, returns nil instead of throwing
	@discardableResult
	static func queryNT(token: AutoId? = nil, _ query: String = "", arguments: [Sendable]? = nil) async -> [Row]? {
		try? await AutoDBManager.shared.query(token: token, TableType.self, query, arguments)
	}
	
	static func valueQuery<Val: SQLColumnWrappable>(token: AutoId? = nil, _ query: String = "", _ arguments: [Sendable]? = nil)  async throws -> Val? {
		try await AutoDBManager.shared.valueQuery(token: token, TableType.self, query, arguments)
	}
	
	// MARK: - saving
	
	/// When you don't need to wait for the save procedure
	func save(token: AutoId? = nil) {
		Task.detached {
			try? await self.save(token: token)
		}
	}
	
	/// Tell the manager to save this object
	func save(token: AutoId? = nil) async throws {
		try await [self].save(token: token)
	}
	
	static func saveChanges(token: AutoId? = nil) async throws {
		try await AutoDBManager.shared.saveChanges(token: token, Self.self)
	}
	
	static func saveChangesDetached(token: AutoId? = nil) {
		Task.detached {
			try? await AutoDBManager.shared.saveChanges(token: token, Self.self)
		}
	}
	
	static func saveAllChanges(token: AutoId? = nil) async throws {
		try await AutoDBManager.shared.saveAllChanges(token: token)
	}
	
	static func saveAllChangesDetacted(token: AutoId? = nil) {
		Task.detached {
			try? await AutoDBManager.shared.saveAllChanges(token: token)
		}
	}
	
	static func willSave(_ objects: [Self]) async throws {}
	static func didSave(_ objects: [Self]) async throws {}
	
	/// All save functions ends up here, where we encode the objects to SQL queries, store them, remove from isChanged and call did/will save.
	static func saveList(token: AutoId? = nil, _ objects: [Self]) async throws {
		guard objects.isEmpty == false else { return }
		let list = objects.map(\.value)
		
		try await willSave(objects)
		
		try await TableType.saveList(token: token, list)
		
		//remove all changed objects
		let typeID = ObjectIdentifier(self)
		await AutoDBManager.shared.removeFromChanged(objects, typeID)
		
		try await didSave(objects)
	}
	
	// MARK: - deletions
	
	var isDeleted: Bool {
		get async {
			await AutoDBManager.shared.isDeleted(id, ObjectIdentifier(Self.self))
		}
	}
	
	func delete(token: AutoId? = nil) async throws {
		try await Self.deleteIds([id])
	}
	
	static func deleteIds(token: AutoId? = nil, _ ids: [AutoId]) async throws {
		try await AutoDBManager.shared.delete(token: token, ids, ObjectIdentifier(TableType.self))
	}
	
	// TODO: in progress
	static func deleteIdsLater(token: AutoId? = nil, _ ids: [AutoId]) async {
		await AutoDBManager.shared.deleteLater(token: token, ids, ObjectIdentifier(TableType.self))
	}
	
	// MARK: - callbacks
	
	static func changeObserver() async throws -> ChangeObserver {
		try await AutoDBManager.shared.changeObserver(TableType.self)
	}
}


public extension Collection where Element: ModelObject {
	
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
}
