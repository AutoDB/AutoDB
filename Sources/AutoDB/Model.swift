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
	
	/// The backing value
	var value: TableType { get set }
	
	/// Read or modify the value, fires change-tracking when the value changed.
	/// The default implementation is a get-modify-set on `value` (same guarantees as mutating `value` directly), StoredModel conformers get a truly atomic version.
	@discardableResult
	func withValue<R>(_ body: (inout TableType) throws -> R) rethrows -> R
	
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
	
	/// Read or modify the value through a closure. This default bridges via `value`,
	/// so the conformer's didSet performs the change-tracking.
	@discardableResult
	func withValue<R>(_ body: (inout TableType) throws -> R) rethrows -> R {
		var copy = value
		let result = try body(&copy)
		value = copy
		return result
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
	
	/// sometimes object's inits must be sync. Force-wait in that case, this causes hang by design.
	static func create(_ id: AutoId? = nil) -> Self {
		
		let semaphore = DispatchSemaphore(value: 0)
		
		let store = Store<Self>()
		Task(priority: .userInitiated) {
			store.item = await create(id)
			semaphore.signal()
		}
		semaphore.wait()
		
		return store.item!
	}
	
	/// When you are in async mode, wait regularly
	static func create(_ id: AutoId? = nil) async -> Self {
		// get encoder or setup db if not done
		let typeID = ObjectIdentifier(Self.self)
		guard let encoder = try? await AutoDBManager.shared.getEncoder(TableType.self, typeID) else {
			fatalError("Could not setup DB")
		}
		
		// don't let two threads create the same object at the same time.
		// reuse an ambient transaction token so creation inside transactions can re-enter (an explicit token wins)
		let semToken = SemaphoreToken.current ?? AutoId.generateId()
		await encoder.semaphore.wait(token: semToken)
		defer { Task { await encoder.semaphore.signal(token: semToken) } }
		
		if let id {
			if let item = await AutoDBManager.shared.cached(Self.self, id, typeID) {
				return item
			} else {
				do {
					return try await fetchId(id, typeID)
				} catch {
					//print("error fetching id: \(error)")
				}
			}
		}
		
		// no id or not in db, create a new object.
		// note: an explicitly passed token doubles as the default id (legacy behavior), but an ambient token must not - every object created inside one transaction needs a unique id.
		var value = TableType()
		value.id = id ?? AutoId.generateId()
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
			AutoDBManager.shared.setOptimization(self, opt)
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
		} else {
			var innerRelations = [AnyKeyPath]()
			for (_, path) in self.allKeyPaths {
				if let relation = self[keyPath: path] as? any Relation {
					relation.setOwner(self)
					innerRelations.append(path as AnyKeyPath)
				}
			}
			let opt = Optimizations(innerRelations: innerRelations)
			AutoDBManager.shared.setOptimization(self, opt)
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
	/// The transaction token is carried as an ambient task-local for the duration of the closure, so all db-access inside re-enters the lock automatically - no need to forward the token.
	/// Passing the token explicitly is still supported and always wins over the ambient one. Note: Task.detached inside the closure does not inherit the token and waits for the transaction (by design).
	static func transaction<R: Sendable>(_ action: (@Sendable (_ db: isolated Database) async throws -> R)) async throws -> R {
		try await db().transaction(action)
	}
	
	// MARK: - fetch shortcuts
	
	static func fetchId(_ id: AutoId, _ typeID: ObjectIdentifier? = nil) async throws -> Self {
		
		try await AutoDBManager.shared.fetchId(id, typeID)
	}
	
	static func fetchIds(_ ids: [AutoId], _ identifier: ObjectIdentifier? = nil) async throws -> [Self] where Self: AnyObject {
		if ids.isEmpty {
			return []
		}
		return try await AutoDBManager.shared.fetchIds(ids, identifier)
	}
	
	static func fetchQuery(_ query: String = "", _ arguments: [Sendable]? = nil, sqlArguments: [SQLValue]? = nil) async throws -> [Self] where Self: AnyObject {
		try await AutoDBManager.shared.fetchQuery(query, arguments: arguments, sqlArguments: sqlArguments)
	}
	
	/// Tell the manager to save at a later time
	func didChange() async {
		await AutoDBManager.shared.objectHasChanged(self)
	}
	
	func didChange() {
		if #available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, *) {
			Task.immediate {
				await AutoDBManager.shared.objectHasChanged(self)
			}
		} else {
			Task {
				await AutoDBManager.shared.objectHasChanged(self)
			}
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
	static func query(_ query: String = "", _ arguments: [Sendable]? = nil) async throws -> [Row] {
		try await AutoDBManager.shared.query(TableType.self, query, arguments)
	}
	
	// this cannot have the same signature
	@discardableResult
	static func query(_ query: String = "", sqlArguments: [SQLValue]? = nil) async throws -> [Row] {
		try await AutoDBManager.shared.query(TableType.self, query, sqlArguments: sqlArguments)
	}
	
	/// Execute a query without returning any rows, like INSERT or UPDATE.
	static func execute(_ query: String = "", _ arguments: [Sendable]? = nil) async throws {
		try await AutoDBManager.shared.execute(TableType.self, query, arguments)
	}
	
	/// Execute a query without returning any rows, like INSERT or UPDATE.
	static func execute(_ query: String = "", sqlArguments: [SQLValue]? = nil) async throws {
		try await AutoDBManager.shared.execute(TableType.self, query, sqlArguments: sqlArguments)
	}
	
	/// Execute a query without returning any rows, like INSERT or UPDATE. Returns the amount of affected rows. Since Swift 6 has a bug with @discardableResult we need to have two versions of this method.
	static func executeAffectedRows(_ query: String = "", sqlArguments: [SQLValue]? = nil) async throws -> Int {
		return try await AutoDBManager.shared.execute(TableType.self, query, sqlArguments: sqlArguments)
	}
	
	/// A non-throwable query, returns nil instead of throwing
	@discardableResult
	static func queryNT(_ query: String = "", arguments: [Sendable]? = nil) async -> [Row]? {
		try? await AutoDBManager.shared.query(TableType.self, query, arguments)
	}
	
	// MARK: - common queries
	
	/// return the first value of the first row of the result,
	/// throws fetchError if the value is nil
	static func valueQuery<Val: SQLColumnWrappable>(_ query: String = "", _ arguments: [Sendable]? = nil) async throws -> Val {
		if let value: Val = try await AutoDBManager.shared.valueQuery(TableType.self, query, arguments) {
			return value
		}
		throw AutoError.fetchError
	}
	
	///return an array with all values in the result for a (the first) column.
	static func groupConcatQuery<Val: SQLColumnWrappable>(_ query: String = "", _ arguments: [Sendable]? = nil) async throws -> [Val] {
		try await AutoDBManager.shared.groupConcatQuery(TableType.self, query, arguments)
	}
	
	// MARK: - saving
	
	/// When you don't need to wait for the save procedure
	func save() {
		Task.detached {
			try? await self.save()
		}
	}
	
	/// Tell the manager to save this object
	func save() async throws {
		try await [self].save()
	}
	
	static func saveChanges() async throws {
		try await AutoDBManager.shared.saveChanges(Self.self)
	}
	
	static func saveChangesLater() {
		Task.detached {
			await AutoDBManager.shared.saveChangesLater(Self.self)
		}
	}
	
	static func saveChangesDetached() {
		Task.detached {
			try? await AutoDBManager.shared.saveChanges(Self.self)
		}
	}
	
	static func saveAllChanges() async throws {
		try await AutoDBManager.shared.saveAllChanges()
	}
	
	static func saveAllChangesDetacted() {
		Task.detached {
			try? await AutoDBManager.shared.saveAllChanges()
		}
	}
	
	static func willSave(_ objects: [Self]) async throws {}
	static func didSave(_ objects: [Self]) async throws {}
	
	/// All save functions ends up here, where we encode the objects to SQL queries, store them, remove from isChanged and call did/will save.
	static func saveList(_ objects: [Self]) async throws {
		guard objects.isEmpty == false else { return }
		let list = objects.map(\.value)
		
		try await willSave(objects)
		
		let (created, updated) = await AutoDBManager.shared.filterCreated(TableType.identifier, list)
		
		// note that we do these in two steps, since creating objects may fail, and we don't want to save the updated objects twice.
		if updated.isEmpty == false {
			try await TableType.saveList(updated, onlyUpdated: true)
			//remove all changed objects
			await AutoDBManager.shared.removeFromChanged(updated.map(\.id), ObjectIdentifier(self))
		}
		
		if created.isEmpty == false {
			try await TableType.saveList(created, onlyUpdated: false)
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
	
	/// Synchronous delete, spawns deletion and ignores errors
	func delete() {
		Task {
			// don't inherit an ambient transaction token - a fire-and-forget delete should wait for the transaction, not race into it. An explicit token still wins.
			try? await SemaphoreToken.detached {
				try await delete()
			}
		}
	}
	
	func delete() async throws {
		try await Self.deleteIds([id])
	}
	
	static func deleteIds(_ ids: [AutoId]) async throws {
		try await AutoDBManager.shared.delete(ids, ObjectIdentifier(TableType.self))
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
	func save() where Self: Sendable {
		Task.detached {
			try? await self.save()
		}
	}
	
	/// Shorthand to saveList()
	func save() async throws {
		// Do some compiler-type magic to be allowed to call...
		if let list = (self as? [Self.Element]) ?? (Array(self) as? [Self.Element]) {
			try await Element.saveList(list)
		} else {
			throw AutoError.missingSetup
		}
	}
	
	func delete() async throws {
		let ids = self.map(\.id)
		try await Element.deleteIds(ids)
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
