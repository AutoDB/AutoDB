//
//  Model.swift
//  AutoDB
//
//  Created by Olof Andersson-Thorén on 2025-03-07.
//
//import Dispatch
import Foundation

/// All table classes must implement AutoDB and be @unchecked Sendable. Regular Sendable is not meaningful (must both be decodable and owned by a global actor).
public protocol Model: Hashable, Identifiable, Sendable, AnyObject, RelationOwner, TableModel {
	associatedtype TableType: Table
	
	/// Always called when creating an object
	init(_ value: TableType)
	
	//var originalValue: TableType { get set }
	
	/// The backing value,
	var value: TableType { get set }
	
	var valueIdentifier: ObjectIdentifier { get }
	
	/// Id is owned by the Value, it can not be changed after init.
	var id: AutoId { get }
	
	/// If this object needs to be saved at some point in the future
	func didChange() async
	
	/// Called after calling the create() method, default implementation calls setOwnerOnRelations and caches object to make all future fetches return the same object (when saved)
	/// Call this method if you create objects in other ways.
	func awakeFromInit() async
	
	/// Find relationship-variables and set the owner
	func setOwnerOnRelations()
	
	typealias ColumnKeyPath = PartialKeyPath<Self>
	var allKeyPaths: [String: ColumnKeyPath] { get }
	
	/*
	 Note that the save functions are not exposed, since no need to implement them.
	 Understand that if your Table has a Model, you must call save or saveChanges (etc) on the model.
	 
	 /// save and wait until completed, potentially handling errors
	 func save(token: AutoId?) async throws
	 /// save and don't wait until completed, ignoring errors
	 //func save(token: AutoId?) - if we don't include it in the protocol Swift adds it from the extension - but then it won't call the function in concrete types?
	 /// save changes to all objects of the same type and wait until completed, potentially handling errors
	 static func saveChanges(token: AutoId?) async throws
	 /// save changes to all objects of the same type and don't wait until completed, ignoring errors
	 static func saveChangesDetached(token: AutoId?)
	 /// save changes to all changed objects and wait until completed, potentially handling errors
	 static func saveAllChanges(token: AutoId?) async throws
	 /// save changes to all changed objects and don't wait until completed, ignoring errors
	 static func saveAllChangesDetacted(token: AutoId?)
	 */
	
	
	// MARK: - cache
	
	/// Refresh all objects still used when changed by other processes like widgets, etc.
	static func refreshCache() async throws
	func refreshCache() async throws
}

public extension Model {
	
	var id: AutoId {
		value.id
	}
	
	/// Call this when value is changed for automatic change-tracking, like so: var value: TableType { didSet { didSet(oldValue) }}
	func didSet(_ oldValue: TableType) {
		if oldValue == value { return }
		didChange()
	}
	
	var valueIdentifier: ObjectIdentifier {
		ObjectIdentifier(TableType.self)
	}
	
	static var valueIdentifier: ObjectIdentifier {
		ObjectIdentifier(TableType.self)
	}
	
	static func == (lhs: Self, rhs: Self) -> Bool {
		lhs.id == rhs.id
	}
	func hash(into hasher: inout Hasher) {
		hasher.combine(id)
	}
	
	/// sometimes object's inits must be sync. Force-wait in that case.
	static func create(token: AutoId? = nil, _ id: AutoId? = nil) -> Self {
		
		let semaphore = DispatchSemaphore(value: 0)
		
		var wrapper: [Self] = []
		Task {
			let item = await create(token: token, id)
			wrapper.append(item)
			semaphore.signal()
		}
		semaphore.wait()
		
		return wrapper.first!
	}
	
	/// When you are in async mode, wait regularly
	static func create(token: AutoId? = nil, _ id: AutoId? = nil) async -> Self {
		// get encoder or setup db if not done
		guard let encoder = try? await AutoDBManager.shared.getEncoder(TableType.self) else {
			fatalError("Could not setup DB")
		}
		
		// don't let two threads create the same object at the same time
		let token = token ?? AutoId.generateId()
		await encoder.semaphore.wait(token: token)
		defer { Task { await encoder.semaphore.signal(token: token) }}
		
		if let id {
			if let item = await AutoDBManager.shared.cached(Self.self, id) {
				return item
			} else if let item = try? await fetchId(token: token, id) {
				return item
			}
		}
		
		// no id or not in db, create a new object.
		var value = TableType()
		value.id = id ?? AutoId.generateId()
		let item = Self(value)
		
		await item.awakeFromInit()
		
		return item
	}
	
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
	
	/// for relations that are saved in db, like ManyRelation, it must be kept in the value. When not created decoding, call this method.
	func setOwnerOnRelations() {
		
		for (_, path) in value.allKeyPaths {
			if let relation = value[keyPath: path] as? any Relation {
				relation.setOwner(self)
			}
		}
		
		setOwnerOnInnerRelations()
	}
	
	/// for other relations that does not need to be stored, like FTSColumn, RelationQuery, etc -  it can be placed in this Model having the Table if you want. This method is called by setOwnerOnRelations() and after decoding
	func setOwnerOnInnerRelations() {
		
		for (_, path) in self.allKeyPaths {
			if let relation = self[keyPath: path] as? any Relation {
				relation.setOwner(self)
			}
		}
	}
	
	func awakeFromInit() {
		Task {
			await awakeFromInit()
		}
	}
	
	func awakeFromInit() async {
		await AutoDBManager.shared.cacheObject(self)
		setOwnerOnRelations()
	}
	
	/// Get this class AutoDB which allows direct SQL-access. You may setup db and override the class' settings, the first time you call this
	@discardableResult
	static func db(_ settings: AutoDBSettings? = nil) async throws -> Database {
		try await TableType.db(settings)
	}
	
	/// Run actions inside a transaction - any thrown error causes the DB to rollback (and the error is rethrown).
	/// ⚠️  Must use token for all db-access inside transactions, otherwise will deadlock. ⚠️
	/// Why? Since async/await and actors does not and can not deal with threads, there is no other way of knowing if you are inside the transaction / holding the lock.
	static func transaction<R: Sendable>(_ action: (@Sendable (_ db: isolated Database, _ token: AutoId) async throws -> R) ) async throws -> R {
		try await db().transaction(action)
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
	
	/// Refresh all objects currently in use
	static func refreshCache() async throws {
		let objects: [AutoId: Self] = await AutoDBManager.shared.cached(Self.self)
		let ids: [AutoId] = Array(objects.keys)
		let values: [TableType] = try await AutoDBManager.shared.fetchIds(ids)
		for value in values {
			objects[value.id]?.value = value
		}
	}
	
	/// Refresh our value
	func refreshCache() async throws {
		self.value = try await AutoDBManager.shared.fetchId(id)
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
	
	// MARK: - common queries
	
	/// return the first value of the first row of the result,
	/// throws fetchError if the value is nil 
	static func valueQuery<Val: SQLColumnWrappable>(token: AutoId? = nil, _ query: String = "", _ arguments: [Sendable]? = nil) async throws -> Val {
		if let value: Val = try await AutoDBManager.shared.valueQuery(token: token, TableType.self, query, arguments) {
			return value
		}
		throw AutoError.fetchError
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
	
	static func truncateTable() async throws {
		
		try await AutoDBManager.shared.truncateTable(Self.self)
	}
	
	var isDeleted: Bool {
		get async {
			await AutoDBManager.shared.isDeleted(id, ObjectIdentifier(TableType.self))
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
		try await AutoDBManager.shared.delete(token: token, ids, ObjectIdentifier(TableType.self))
	}
	
	// TODO: in progress
	static func deleteIdsLater(token: AutoId? = nil, _ ids: [AutoId]) async {
		await AutoDBManager.shared.deleteLater(token: token, ids, ObjectIdentifier(TableType.self))
	}
	
	// MARK: - callbacks
	
	/// get row-level changes from db with ids of changed rows
	static func rowChangeObserver() async throws -> RowChangeObserver {
		try await AutoDBManager.shared.rowChangeObserver(TableType.self)
	}
	
	/// get notified by AutoDB after saves or deletions. You can bypass this notification by crafting your own save/delete SQL.
	static func tableChangeObserver() async throws -> TableChangeObserver {
		try await AutoDBManager.shared.tableChangeObserver(TableType.self)
	}
}

public extension Collection where Element: Model {
	
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
