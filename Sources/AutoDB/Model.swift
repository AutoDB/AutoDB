//
//  Model.swift
//  AutoDB
//
//  Created by Olof Andersson-Thorén on 2025-03-07.
//

import Foundation

/// let the manager store info about the types so we don't need to perform the same lookups several times.
struct Optimizations: @unchecked Sendable {
	var relationPaths: [AnyKeyPath]?
	var innerRelations: [AnyKeyPath]?
}

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
	
	/// called when created from DB
	func awakeFromFetch()
	
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
		// check if the value actually have changed
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
		
		let store = Store<Self>()
		Task(priority: .userInitiated) {
			store.item = await create(token: token, id)
			semaphore.signal()
		}
		semaphore.wait()
		
		return store.item!
	}
	
	/// When you are in async mode, wait regularly
	static func create(token: AutoId? = nil, _ id: AutoId? = nil) async -> Self {
		// get encoder or setup db if not done
		let typeID = ObjectIdentifier(Self.self)
		guard let encoder = try? await AutoDBManager.shared.getEncoder(TableType.self, typeID) else {
			fatalError("Could not setup DB")
		}
		
		// don't let two threads create the same object at the same time
		let token = token ?? AutoId.generateId()
		await encoder.semaphore.wait(token: token)
		defer { Task { await encoder.semaphore.signal(token: token) }}
		
		if let id {
			if let item = await AutoDBManager.shared.cached(Self.self, id, typeID) {
				return item
			} else {
				do {
					return try await fetchId(token: token, id, typeID)
				} catch {
					//print("error fetching id: \(error)")
				}
			}
		}
		
		// no id or not in db, create a new object.
		var value = TableType()
		value.id = id ?? token
		let item = Self(value)
		
		// set in cache so it won't be created twice
		await AutoDBManager.shared.cacheObject(item, typeID)
		await AutoDBManager.shared.setCreated(value.id, ObjectIdentifier(TableType.self))
		
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
		
		let optimization = AutoDBManager.shared.optimization(self)
		if let paths = optimization?.relationPaths {
			for path in paths {
				if let relation = value[keyPath: path] as? any Relation {
					relation.setOwner(self)
				}
			}
		} else {
			var relationPaths = [AnyKeyPath]()
			for (_, path) in value.allKeyPaths {
				
				if let relation = value[keyPath: path] as? any Relation {
					relation.setOwner(self)
					relationPaths.append(path as AnyKeyPath)
				}
			}
			let opt = Optimizations(relationPaths: relationPaths)
			Task(priority: .userInitiated) {
				await AutoDBManager.shared.setOptimization(self, opt)
			}
		}
		
		setOwnerOnInnerRelations()
	}
	
	/// for other relations that does not need to be stored, like FTSColumn, RelationQuery, etc -  it can be placed in this Model having the Table if you want. This method is called by setOwnerOnRelations() and after decoding
	func setOwnerOnInnerRelations() {
		let optimization = AutoDBManager.shared.optimization(self)
		if let paths = optimization?.innerRelations {
			for path in paths {
				if let relation = self[keyPath: path] as? any Relation {
					relation.setOwner(self)
				}
			}
		}
		else {
			var innerRelations = [AnyKeyPath]()
			for (_, path) in self.allKeyPaths {
				if let relation = self[keyPath: path] as? any Relation {
					relation.setOwner(self)
					innerRelations.append(path as AnyKeyPath)
				}
			}
			let opt = Optimizations(innerRelations: innerRelations)
			Task(priority: .userInitiated) {
				await AutoDBManager.shared.setOptimization(self, opt)
			}
		}
	}
	
	/// called when created from DB
	func awakeFromFetch() {}
	
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
	static func db() async throws -> Database {
		try await TableType.db()
	}
	
	/// Run actions inside a transaction - any thrown error causes the DB to rollback (and the error is rethrown).
	/// ⚠️  Must use token for all db-access inside transactions, otherwise will deadlock. ⚠️
	/// Why? Since async/await and actors does not and can not deal with threads, there is no other way of knowing if you are inside the transaction / holding the lock.
	static func transaction<R: Sendable>(_ action: (@Sendable (_ db: isolated Database, _ token: AutoId) async throws -> R) ) async throws -> R {
		try await db().transaction(action)
	}
	
	// MARK: - fetch shortcuts
	
	static func fetchId(token: AutoId? = nil, _ id: AutoId, _ typeID: ObjectIdentifier? = nil) async throws -> Self {
		
		try await AutoDBManager.shared.fetchId(token: token, id, typeID)
	}
	
	static func fetchIds(token: AutoId? = nil, _ ids: [AutoId], _ identifier: ObjectIdentifier? = nil) async throws -> [Self] where Self: AnyObject {
		if ids.isEmpty {
			return []
		}
		return try await AutoDBManager.shared.fetchIds(token: token, ids, identifier)
	}
	
	static func fetchQuery(token: AutoId? = nil, _ query: String = "", _ arguments: [Sendable]? = nil, sqlArguments: [SQLValue]? = nil) async throws -> [Self] where Self: AnyObject {
		try await AutoDBManager.shared.fetchQuery(token: token, query, arguments: arguments, sqlArguments: sqlArguments)
	}
	
	/// Tell the manager to save at a later time
	func didChange() async {
		await AutoDBManager.shared.objectHasChanged(self)
	}
	
	func didChange() {
		Task {
			await AutoDBManager.shared.objectHasChanged(self)
		}
	}
	
	/// Refresh all objects currently in use, if changed by external process - this will bring in fresh values from DB.
	/// note that you can only remove objects from cache by stop referencing them. Otherwise there will be duplicate objects.
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
		try await AutoDBManager.shared.query(token: token, TableType.self, query, sqlArguments: sqlArguments)
	}
	
	/// Execute a query without returning any rows, like INSERT or UPDATE.
	static func execute(token: AutoId? = nil, _ query: String = "", _ arguments: [Sendable]? = nil) async throws {
		try await AutoDBManager.shared.execute(token: token, TableType.self, query, arguments)
	}
	
	/// Execute a query without returning any rows, like INSERT or UPDATE.
	static func execute(token: AutoId? = nil, _ query: String = "", sqlArguments: [SQLValue]? = nil) async throws {
		try await AutoDBManager.shared.execute(token: token, TableType.self, query, sqlArguments: sqlArguments)
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
	
	///return an array with all values in the result for a (the first) column.
	static func groupConcatQuery<Val: SQLColumnWrappable>(token: AutoId? = nil, _ query: String = "", _ arguments: [Sendable]? = nil) async throws -> [Val] {
		try await AutoDBManager.shared.groupConcatQuery(token: token, TableType.self, query, arguments)
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
	
	static func saveChangesLater() {
		Task.detached {
			await AutoDBManager.shared.saveChangesLater(Self.self)
		}
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
		
		let (created, updated) = await AutoDBManager.shared.filterCreated(TableType.identifier, list)
		
		// note that we do these in two steps, since creating objects may fail, and we don't want to save the updated objects twice.
		if updated.isEmpty == false {
			try await TableType.saveList(token: token, updated, onlyUpdated: true)
			//remove all changed objects
			await AutoDBManager.shared.removeFromChanged(created.map(\.id), ObjectIdentifier(self))
		}
		
		if created.isEmpty == false {
			try await TableType.saveList(token: token, created, onlyUpdated: false)
			//remove all changed objects
			await AutoDBManager.shared.removeFromChanged(created.map(\.id), ObjectIdentifier(self))
		}
		
		try await didSave(objects)
	}
	
	// MARK: - deletions
	
	static func truncateTable() async throws {
		
		try await AutoDBManager.shared.truncateTable(Self.self.TableType)
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
	
	/// delete when calling saveChanges, or after x seconds
	static func deleteIdsLater(_ ids: [AutoId]) async {
		await AutoDBManager.shared.deleteLater(ids, ObjectIdentifier(TableType.self))
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
	
	func delete(token: AutoId? = nil) async throws {
		let ids = self.map(\.id)
		try await Element.deleteIds(token: token, ids)
	}
	
	/// Convert an array with AutoModels to a dictionary
	func dictionary() -> [AutoId: Element] {
		let uniqueSet = Set(self)
		return Dictionary(uniqueKeysWithValues: uniqueSet.map { ($0.id, $0) })
	}
	
	/// Sort by ids, when you want the objects returned to be in the same order as fetched: fetchIds(idsToFetch).sortById(idsToFetch)
	func sortById(_ ids: [AutoId]) -> [Element] {
		dictionary().sortById(ids)
	}
}
