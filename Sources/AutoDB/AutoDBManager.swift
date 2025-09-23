//
//  AutoDBManager.swift
//  
//
//  Created by Olof Thorén on 2021-07-05.
//

import Foundation

extension UInt64 {
	static var shortDelay: UInt64 { 9_000 }
	static func seconds(_ seconds: Double) -> UInt64 { UInt64(seconds * 1_000_000_000) }
}

@globalActor public actor AutoDBManager: GlobalActor {
	
	public static let shared = AutoDBManager()
	
	var encoders = [ObjectIdentifier: SQLRowEncoder]()
	/// get the cached encoder for this class, or create one
	func getEncoder<T: Table>(_ classType: T.Type, _ typeID: ObjectIdentifier? = nil) async throws -> SQLRowEncoder {
		if let enc = encoders[typeID ?? ObjectIdentifier(T.self)] {
			return enc
		}
		try await setupDB(classType)
		if let enc = encoders[typeID ?? ObjectIdentifier(T.self)] {
			return enc
		}
		let enc = await SQLRowEncoder(T.self)
		encoders[typeID ?? ObjectIdentifier(T.self)] = enc
		return enc
	}
	
	var decoders = [ObjectIdentifier: SQLRowDecoder]()
	/// get the cached decoder for this class, or create one
	func getDecoder<T: Table>(_ classType: T.Type) async throws -> SQLRowDecoder {
		let typeID = ObjectIdentifier(T.self)
		if let enc = decoders[typeID] {
			return enc
		}
		let table = await tableInfo(T.self)
		let dec = SQLRowDecoder(T.self, table)
		decoders[ObjectIdentifier(T.self)] = dec
		return dec
	}
	
	private var tables = [ObjectIdentifier: TableInfo]()
    var lookupTable = LookupTable()
	var cachedObjects = [ObjectIdentifier: WeakDictionary<AutoId, AnyObject>]()
	private var createdObjects = [ObjectIdentifier: Set<AutoId>]()
	
	var databases = [ObjectIdentifier: Database]()
	var sharedDatabases = [SettingsKey: Database]()

	#if os(Android)
	#else
	// keep track of low memory warnings, save any unsaved objects to release memory.
	private let lowMemoryEventSource: DispatchSourceMemoryPressure
	
	private init() {
		lowMemoryEventSource = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical])
		lowMemoryEventSource.setEventHandler { [weak self] in
			guard let self else { return }
			Task {
				try? await self.saveAllChanges()
			}
		}
		Task {
			await self._init()
		}
	}
	
	private func _init() async {
		lowMemoryEventSource.resume()
	}
	#endif
	
	/// Only use this when testing, may create dublicate objects when live objects are saved.
	func truncateTable<T: Table>(token: AutoId? = nil, _ table: T.Type) async throws {
		let db = try await setupDB(table)
		try await db.execute(token: token, "DELETE FROM \(table.typeName)")
		let typeID = ObjectIdentifier(T.self)
		cachedObjects[typeID] = nil
		createdObjects[typeID] = nil
	}
	
	/// Instead of asking each Table, supply defaults for any new table. If an ObjectIdentifier of a Table.Type is not within any - settings is picked from the first existing one in order: regular, cache, specific.
	/// Bypassed if the Table has its own settings
	/// If all is empty the default is used
	public var appDefaults: [SettingsKey: AutoDBSettings] = [:]
	
	/// insert a new global setting for the entire app, this is a good starting point for appstart
	/// Define app settings e.g. path
	public func setAppSettings(_ settings: AutoDBSettings, for key: SettingsKey) async {
		// all with the same key will share the same settings
		appDefaults[key] = settings
	}
	
	 /// To ask for a common setting, e.g. when creating settings at startup:
	 /// AutoDBManager.shared.setAppSettingsSync(backupDBSettings, for: .regular)
	 /// AutoDBManager.shared.setAppSettingsSync(cacheDBSettings, for: .cache)
	public func appSettings(for key: SettingsKey) -> AutoDBSettings {
		
		if let settings = appDefaults[key] {
			return settings
		} else {
			switch key {
				case .cache:
					appDefaults[key] = AutoDBSettings.cache()
				default:
					appDefaults[key] = AutoDBSettings()
			}
		}
		
		return appDefaults[key]!
	}
	
	private let setupSemaphore = Semaphore()
	
	/// Setup database for this class, attach to file defined in settings. Settings defaults to .main, implement autoDBSettings in each Table to specify location or use the cache.
	@discardableResult
	func setupDB<TableType: Table>(_ table: TableType.Type, _ typeID: ObjectIdentifier? = nil) async throws -> Database {
		let typeID = typeID ?? ObjectIdentifier(table)
		if let db = databases[typeID] {
			return db
		}
		
		// many threads will go here at the same time at startup, they need to wait.
		await setupSemaphore.wait()
		if let db = databases[typeID] {
			await setupSemaphore.signal()
			return db
		}
		let database: Database
		let settingsKey = table.autoDBSettings
		let tableSettings = appSettings(for: settingsKey)
		
		// in theory you could have multiple actors for the same file, but that is always a bad idea.
		if let db = sharedDatabases[settingsKey] {
			database = db
		} else {
			database = try await initDB(tableSettings)
			sharedDatabases[settingsKey] = database
		}
		
		// setup table and perform migrations
		let (encoder, migrations) = try await SQLTableEncoder().setup(table, database, tableSettings)
		tables[typeID] = encoder
		
		if let migrations, migrations.isEmpty == false {
			// NOTE! This will deadlock if other tables are not setup.
			
			// we must wait until migrations take place, we do that using a transaction. All queries will wait until the transaction is done.
			try? await database.transaction { db, token in
				
				await setDatabase(db, typeID)
				// release the setupSemaphore so other tables can be created, this will allow other's to queue onto the db, but the transaction-semaphore will force them to wait until we are done.
				await setupSemaphore.signal()
				
				for migration in migrations {
					await TableType.migration(token, database, migration)
					
					if case MigrationState.changes(let tempTableName, _) = migration {
						try await database.query(token: token, "DROP TABLE `\(tempTableName)`")
					}
				}
			}
		} else {
			databases[typeID] = database
			await setupSemaphore.signal()
		}
		return database
	}
	
	func setDatabase(_ db: Database, _ typeID: ObjectIdentifier) {
		databases[typeID] = db
	}
	
	/// tables are created after awaits and may not exist in the beginning of execution, just add a short delay to wait for them
	func tableInfo<T: Table>(_ classType: T.Type) async -> TableInfo {
		await tableInfo(ObjectIdentifier(classType))
	}
	
	/// tables are created after awaits and may not exist in the beginning of execution, just add a short delay to wait for them
	func tableInfo(_ typeID: ObjectIdentifier) async -> TableInfo {
		while tables[typeID] == nil {
			try? await Task.sleep(nanoseconds: .shortDelay)
		}
		return tables[typeID]!
	}
	
	@discardableResult
	func initDB(_ settings: AutoDBSettings) async throws -> Database {
		
		var path: String
		if settings.inAppFolder || settings.inCacheFolder {
			path = settings.inCacheFolder ? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].path : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].path
			if path.hasSuffix("/") == false {
				path += "/"
			}
			path += settings.path
		} else {
			path = settings.path
		}
		print("sqlite3 \"\(path)\"")
		let db = try Database(path)
		
		// exclude from backup if desired
		if settings.iCloudBackup == false {
			var values = URLResourceValues()
			values.isExcludedFromBackup = true
			var url = URL(fileURLWithPath: path)
			try? url.setResourceValues(values)
		}
		return db
	}
    
    func lookupObjectsCount(_ typeName: ObjectIdentifier) async -> Int {
		lookupTable.changedObjects[typeName]?.count ?? 0
	}
	
	
	// Mark this object as changed by placing it in the array - we avoid storage variables on the objects themselves.
	func objectHasChanged<T: Model>(_ object: T, _ identifier: ObjectIdentifier? = nil) {
		lookupTable.objectHasChanged(object, identifier)
	}
	
	// MARK: created objects
	
	/// Mark an object as created.
	func setCreated(_ id: AutoId, _ typeID: ObjectIdentifier) {
		
		if createdObjects[typeID] == nil {
			createdObjects[typeID] = Set([id])
		} else {
			createdObjects[typeID]?.insert(id)
		}
	}
	
	/// Check if an object is created, this is used to make sure we use the plain insert statement instead of INSERT OR REPLACE. This allows failure on unique constraints.
	///  return one array with created objects and one with all other objects.
	func filterCreated<T: Table>(_ typeID: ObjectIdentifier, _ items: [T]) -> (created: [T], updated: [T]) {
		//let typeID = ObjectIdentifier(T.self)
		guard let created = createdObjects[typeID] else {
			return ([], items)
		}
		return items.reduce(into: (created: [T](), updated: [T]())) { result, item in
			if created.contains(item.id) {
				result.created.append(item)
			} else {
				result.updated.append(item)
			}
		}
	}
	
	/// Clear all created objects for this typeID, used after a save.
	func clearCreated<T: Table>(_ typeID: ObjectIdentifier, _ items: [T]) {
		//let typeID = ObjectIdentifier(T.self)
		if createdObjects[typeID] != nil {
			for item in items {
				createdObjects[typeID]?.remove(item.id)
			}
			if createdObjects[typeID]?.isEmpty == true {
				createdObjects[typeID] = nil
			}
		}
	}
	
	
	// MARK: cached objects
	
	/// Get a cached object - to check if init has run, or if this is a temp-object etc
	public func cached<T: Model>(_ objectType: T.Type, _ id: AutoId, _ identifier: ObjectIdentifier? = nil) -> T? {
		let typeID = identifier ?? ObjectIdentifier(T.self)
		return cachedObjects[typeID]?[id] as? T
	}
	
	/// Get all cached objects, filter by ids or general
	public func cached<T: Model>(_ objectType: T.Type, filterIds: [AutoId]? = nil, filter: ((T) -> Bool)? = nil) async -> [T] {
		let typeID = ObjectIdentifier(T.self)
		cachedObjects[typeID]?.cleanup()
		if let cache = cachedObjects[typeID] {
			return cache.compactMap {
				if let filterIds, !filterIds.contains($0.key) {
					return nil
				}
				let item = $0.value.unbox as? T
				if let filter, let item, !filter(item) {
					return nil
				}
				
				return item
			}
		}
		return []
	}
	
	/// Get all cached objects as a dictionary
	public func cached<T: Model>(_ objectType: T.Type, filterIds: [AutoId]? = nil, filter: ((T) -> Bool)? = nil) async -> [AutoId: T] {
		let typeID = ObjectIdentifier(T.self)
		cachedObjects[typeID]?.cleanup()
		if let cache = cachedObjects[typeID] {
			
			let keysValues: [(key: AutoId, value: T)] = cache.compactMap {
				if let filterIds, !filterIds.contains($0.key) {
					return nil
				}
				if let item = $0.value.unbox as? T {
				
					if let filter, !filter(item) {
						return nil
					} else {
						return (key: $0.key, value: item)
					}
				}
				return nil
			}
			return Dictionary(uniqueKeysWithValues: keysValues)
		}
		return [:]
	}
	
	func cacheObject<T: Model>(_ object: T, _ identifier: ObjectIdentifier? = nil) {
		let typeID = identifier ?? ObjectIdentifier(T.self)
		if cachedObjects[typeID] == nil {
			cachedObjects[typeID] = WeakDictionary([object.id: object])
		} else {
			cachedObjects[typeID]?[object.id] = object
		}
	}
	
	/// Refresh all objects currently in use - NOTE: this can't be done in Swift? And do you want to? You only need to refresh objects changed outside this process, not all of them!
	private func refreshCache() async throws {
		/* TODO:
		 fetchIds is generic, we must call each type one by one...
		for (typeID, cache) in cachedObjects {
			let allIds = cache.map { $0.key }
			let fetched = try await AutoDBManager.shared.fetchIds(allIds, typeID)
			for (id, fetchedValue) in fetched {
				cache[id]?.value = fetchedValue
			}
			
		}
		 */
	}
	
	func removeFromChanged(_ ids: [AutoId], _ typeID: ObjectIdentifier) {
		
		for id in ids {
			lookupTable.changedObjects[typeID]?.removeValue(forKey: id)
		}
	}
	
	/// A shorthand to return the Model for a Table, if it still exists.
	public func modelForTable<T: Model>(_ table: T.TableType?) -> T? {
		guard let table else {
			return nil
		}
		if let model = cached(T.self, table.id) {
			return model
		}
		
		return nil
	}
	
	// MARK: - fetching
	
	static func fetchId<T: Table>(token: AutoId? = nil, _ id: UInt64, _ identifier: ObjectIdentifier? = nil) async throws -> T? {
		try await shared.fetchId(token: token, id)
    }
	
	/// Fetch an object with known id, throw missingId if no object was found.
	func fetchId<T: Model>(token: AutoId? = nil, _ id: UInt64, _ typeIDIn: ObjectIdentifier? = nil) async throws -> T {
		let typeID = typeIDIn ?? ObjectIdentifier(T.self)
		if let obj = cachedObjects[typeID]?[id] as? T {
			return obj
		}
		let items: [T] = try await fetchQuery(token: token, "WHERE id = ?", id)
		if let item: T = items.first {
			return item
		}
		throw AutoError.missingId
	}
	
	/// Fetch an object with known id, throw missingId if no object was found.
	func fetchId<T: Table>(token: AutoId? = nil, _ id: UInt64, _ identifier: ObjectIdentifier? = nil) async throws -> T {
		
		let items: [T] = try await fetchQuery(token: token, "WHERE id = ?", id)
		// type system requires us to first fetch the array!
		if let item: T = items.first {
			return item
		}
		throw AutoError.missingId
	}
	
	/// Fetch objects for these ids, missing objects will not be returned and no error thrown for missing objects.
	func fetchIds<T: Model>(token: AutoId? = nil, _ ids: [UInt64], _ identifier: ObjectIdentifier?) async throws -> [T] {
		if ids.isEmpty {
			return []
		}
		let typeID = identifier ?? ObjectIdentifier(T.self)
		var cache = [AutoId: T]()
		
		for id in ids {
			if let obj = cachedObjects[typeID]?[id] as? T {
				cache[id] = obj
			}
		}
		
		// Don't fetch cached ids!
		let fetchIds = ids.filter { cache[$0] == nil }
		if fetchIds.isEmpty {
			// we don't need to fetch
			return ids.compactMap { id in
				cache[id]
			}
		}
		
		let questionMarks = Self.questionMarks(fetchIds.count)
		let list: [AutoId: T] = try await fetchQuery(token: token, "WHERE id IN (\(questionMarks))", arguments: fetchIds.map({ SQLValue.uinteger($0) })).dictionary()
		
		return ids.compactMap { id in
			if let cached = cache[id] {
				return cached
			} else if let object = list[id] {
				return object
			}
			return nil
		}
	}
	
	/// Fetch objects for these ids, missing objects will not be returned and no error thrown for missing objects.
	func fetchIds<T: Table>(token: AutoId? = nil, _ ids: [UInt64], _ identifier: ObjectIdentifier? = nil) async throws -> [T] {
		if ids.isEmpty {
			return []
		}
		
		let questionMarks = Self.questionMarks(ids.count)
		return try await fetchQuery(token: token, "WHERE id IN (\(questionMarks))", arguments: ids.map({ SQLValue.uinteger($0) }))
	}
	
	func fetchQuery<T: Table>(token: AutoId? = nil, _ query: String, _ arguments: Sendable...) async throws -> [T] {
		try await fetchQuery(token: token, query, arguments: arguments)
	}
	func fetchQuery<T: Model>(token: AutoId? = nil, _ query: String, _ arguments: Sendable...) async throws -> [T] {
		try await fetchQuery(token: token, query, arguments: arguments)
	}
	
	/// Fetch an AutoModel struct from the DB.
	func fetchQuery<T: Table>(token: AutoId? = nil, _ whereQuery: String, arguments: [Sendable]? = nil, sqlArguments: [SQLValue]? = nil, refreshData: Bool = false) async throws -> [T] {
		let values = try sqlArguments ?? arguments?.map { try SQLValue.fromAny($0) }
		
		return try await fetchQueryRelations(token: token, whereQuery, values: values ?? [], refreshData: refreshData).map(\.0)
	}
	
	func fetchQueryRelations<T: Table>(token: AutoId? = nil, _ whereQuery: String, values: [SQLValue], refreshData: Bool = false) async throws -> [(T, [AnyRelation])] {
		
		let typeID = ObjectIdentifier(T.self)
		try await setupDB(T.self, typeID)
		let decoder = try await getDecoder(T.self)
		let table = decoder.tableInfo
		
		let columnNames = table.columnNameString
		let query = "SELECT \(columnNames) FROM \(table.name) \(whereQuery)"
		let rows = try await self.query(token: token, T.self, query, values)
		if rows.isEmpty {
			return []
		}
		
		// decode all fetched values
		let result: [(T, [AnyRelation])] = try rows.map { row in
			decoder.values = row
			let value = try T(from: decoder)
			return (value, decoder.relations)
		}
		return result
	}
	
	/// fetchQuery for objects containing structs, handles cache and relations
	func fetchQuery<T: Model>(token: AutoId? = nil, _ whereQuery: String, arguments: [Sendable]? = nil, sqlArguments: [SQLValue]? = nil, refreshData: Bool = false) async throws -> [T] {
		let values = try sqlArguments ?? arguments?.map({ try SQLValue.fromAny($0) }) ?? []
		let rows: [(T.TableType, [AnyRelation])] = try await fetchQueryRelations(token: token, whereQuery, values: values)
		if rows.isEmpty {
			return []
		}
		
		let typeID = ObjectIdentifier(T.self)
		if cachedObjects[typeID] == nil {
			cachedObjects[typeID] = WeakDictionary([:])
		}
		
		let result: [T] = rows.map { tuple in
			
			let row = tuple.0
			if let cached = cachedObjects[typeID]?[row.id] as? T {
				// Don't recreate objects that exist
				return cached
			}
			
			// create a new object with this value
			let object = T(row)
			for relation in tuple.1 {
				relation.setOwner(object)
			}
			cacheObject(object, typeID)
			object.setOwnerOnInnerRelations()
			
			object.awakeFromFetch()
			
			return object
		}
		return result
	}
	
	/// Execute a regular query that may return results. Will use converted sqlArguments if provided, otherwise it will convert the arguments.
	@discardableResult
	public func query<T: Table>(token: AutoId? = nil, _ classType: T.Type, _ query: String, _ arguments: [Sendable]? = nil, sqlArguments: [SQLValue]? = nil) async throws -> [Row] {
		let database = try await setupDB(classType)
		
		let values = try sqlArguments ?? arguments?.map {
			// we must cast or somehow find out which SQL-type each argument is!
			try SQLValue.fromAny($0)
		}
		return try await database.query(token: token, query, sqlArguments: values ?? [])
	}
	
	/// Execute a query, e.g. an INSERT or UPDATE statement. Will use converted sqlArguments if provided, otherwise it will convert the arguments.
	public func execute<T: Table>(token: AutoId? = nil, _ classType: T.Type, _ query: String, _ arguments: [Sendable]? = nil, sqlArguments: [SQLValue]? = nil) async throws {
		
		let database = try await setupDB(classType)
		let values = try sqlArguments ?? arguments?.map {
			// we must cast or somehow find out which SQL-type each argument is!
			try SQLValue.fromAny($0)
		}
		try await database.execute(token: token, query, sqlArguments: values ?? [])
	}
	
	/// Fetch a single value from the database, e.g. a count or sum.
	public func valueQuery<T: Table, Val: SQLColumnWrappable>(token: AutoId? = nil, _ classType: T.Type, _ query: String = "", _ arguments: [Sendable]? = nil, sqlArguments: [SQLValue]? = nil) async throws -> Val? {
		let rows: [Row] = try await self.query(token: token, classType, query, arguments, sqlArguments: sqlArguments)
		return rows.first?.values.first.flatMap {
			Val.fromValue($0)
		}
	}
	
	/*
	/// Decode into a special result struct - useful for select id, name ... etc.
	public func decodeQuery<T: Table, Val: SQLColumnWrappable>(token: AutoId? = nil, _ classType: T.Type, _ query: String = "", _ arguments: [Sendable]? = nil, sqlArguments: [SQLValue]? = nil) async throws -> Val? {
		let rows: [Row] = try await self.query(token: token, classType, query, arguments, sqlArguments: sqlArguments)
		return rows.first?.values.first.flatMap {
			Val.fromValue($0)
		}
	}
	*/
	
	/// Fetch a single column/value from the database, e.g. a list of ids or strings.
	///return an array with all values in the result for a (the first) column.
	public func groupConcatQuery<T: Table, Val: SQLColumnWrappable>(token: AutoId? = nil, _ classType: T.Type, _ query: String = "", _ arguments: [Sendable]? = nil) async throws -> [Val] {
		let rows: [Row] = try await self.query(token: token, classType, query, arguments)
		
		return rows.compactMap {
			if let value = $0.first?.value {
				Val.fromValue(value)
			} else {
				nil
			}
		}
	}
	
	// MARK: - direct database access, these methods must be locked.
	
	public func transaction<T: Table, R: Sendable>(_ classType: T.Type, _ action: (@Sendable (_ db: isolated Database, _ token: AutoId) async throws -> R) ) async throws -> R {
		let database = try await setupDB(classType)
		return try await database.transaction(action)
	}
	
	// MARK: - deletion
	
	public func isDeleted(_ id: AutoId, _ typeID: ObjectIdentifier) -> Bool {
		lookupTable.isDeleted(id, typeID)
	}
	
	public func isDeleted(_ typeID: ObjectIdentifier) -> Set<AutoId> {
		lookupTable.deleted[typeID] ?? []
	}
	
	public func delete(token: AutoId? = nil, _ ids: [AutoId], _ typeID: ObjectIdentifier) async throws {
		
		guard ids.isEmpty == false else {
			return
		}
		let table = await tableInfo(typeID)
		lookupTable.setDeleted(ids, typeID)
		
		let query = String(format: table.deleteQuery, Self.questionMarks(ids.count))
		let database = databases[typeID]!
		let values = ids.map { SQLValue.uinteger($0) }
		try await database.query(token: token, query, values)
		
		// when should we remove deleted objects from lookupTable? Perhaps never - they cannot be removed while there are still references.
		// lookupTable.removeDeleted(typeID, Set(ids))
	}
	
	/// wait while the task exists, cancel if needed.
	var deleteLaterTask: Task<Void, Never>?
	
	/// coalesce multiple objects to be deleted at the next saveChanges.
	func deleteLater(_ ids: [AutoId], _ typeID: ObjectIdentifier) {
		guard ids.isEmpty == false else {
			return
		}
		
		lookupTable.setDeleteLater(ids, typeID)
		if deleteLaterTask != nil {
			return
		}
		deleteLaterTask = Task {
			do {
				// TODO: Think: should we leave this to the app instead and just wait for saveAllChanges to be called?
				try await Task.sleep(nanoseconds: .seconds(10))
				try await saveAllChanges()
			} catch {
				// stopped or failing.
			}
			deleteLaterTask = nil
		}
	}
	
	// MARK: - save
	
	public func saveAllChanges(token: AutoId? = nil) async throws {
		var anyError: Error? = nil
		for dict in lookupTable.changedObjects.values {
			if let item = dict.first?.value {
				do {
					try await saveChanges(token: token, item)
				} catch {
					anyError = error
				}
			}
		}
		if let anyError {
			throw anyError
		}
	}
	
	/// Calls saveChanges for this class type, the reason this function exist is to circumvent Swift's type system and allows us to call a static func using an object.
	public func saveChanges<T: Model>(token: AutoId? = nil, _ class: T) async throws {
		try await saveChanges(token: token, T.self)
	}
	
	/// delete objects waiting for deletion and save changed objects for this class
	public func saveChanges<T: Model>(token: AutoId? = nil, _ classType: T.Type) async throws {
		var anyError: Error? = nil
		let typeID = ObjectIdentifier(T.self)
		if let ids = lookupTable.deleteLater[typeID] {
			do {
				try await delete(token: token, Array(ids), typeID)
				lookupTable.removeDeleteLater(typeID, ids)
			} catch {
				anyError = error
			}
		}
		let dict = lookupTable.changedObjects[typeID]
		if let dict, let array = Array(dict.values) as? [T], array.isEmpty == false {
			
			try await T.saveList(token: token, array)
		}
		if let anyError {
			throw anyError
		}
	}
	
	// temporary storage for tasks
	var debounceTasks: [ObjectIdentifier: Task<Void, Error>] = [:]
	
	/// coalesce changes for this class type and save later, typically used when multiple changes are made to the same object, and you only care that the last save is executed. Each call postpones the save for 3 seconds.
	public func saveChangesLater<T: Model>(_ classType: T.Type) async throws {
		
		let typeID = ObjectIdentifier(T.self)
		debounceTasks[typeID]?.cancel()
		
		debounceTasks[typeID] = Task {
			try await Task.sleep(nanoseconds: .seconds(3))
			debounceTasks[typeID] = nil
			try await saveChanges(T.self)
		}
	}
	
	// MARK: - change callbacks just subscribe to an AsyncSequence
	
	public func tableChangeObserver<T: Table>(_ classType: T.Type) async throws -> TableChangeObserver {
		
		let typeID = ObjectIdentifier(classType)
		let database = try await setupDB(T.self, typeID)
		let table = await tableInfo(typeID)
		return await database.tableChangeObserver(table.name)
	}
	
	public func rowChangeObserver<T: Table>(_ classType: T.Type) async throws -> RowChangeObserver {
		
		let typeID = ObjectIdentifier(classType)
		let database = try await setupDB(T.self, typeID)
		let table = await tableInfo(typeID)
		return await database.rowChangeObserver(table.name)
	}
	
	// MARK: - open and close db
	
	/// Close all databases within waitSec
	public func close(waitSec: Double = 10) async {
		for db in sharedDatabases {
			await db.value.close(waitSec: waitSec)
		}
	}
	
	/// Open after close
	public func open() async {
		for db in sharedDatabases {
			try? await db.value.open()
		}
	}
	
	/// Change database file in the middle of operations, this is good for testing. No dbURL means memory.
	public func switchDB(_ newPositions: [SettingsKey: URL]) async throws {
		for db in sharedDatabases {
			await db.value.closeNow()
		}
		tables.removeAll()
		databases.removeAll()
		for db in sharedDatabases {
			let url = newPositions[db.key]
			try await db.value.switchDB(url)
		}
	}
	
	// MARK: - DB helper functions
	
	/// We want the format to be "INSERT OR REPLACE INTO table (column1, column2) VALUES (?,?),(?,?),(?,?)", and then add an array with four values. Here objectCount = 3, columnCount = 2
	nonisolated public static func questionMarksForQueriesWithObjects(_ objectCount: Int, _ columnCount: Int) -> String {
		
		objectCount.questionMarksForQueriesWithColumns(columnCount)
	}
	
	nonisolated
	public static func questionMarks(_ count: Int) -> String {
		
		count.questionMarks
	}
}

public extension Int {
	var questionMarks: String
	{
		if self == 0 {
			return "''";	//this will make your clause look like this: ... AND column IN ('') - which is always false (unless column can be the empty string), NOT IN is always true.
		}
		let questionMarks = "".padding(toLength: self*2, withPad: "?,", startingAt: 0)
		
		let indexRange = questionMarks.startIndex ..< questionMarks.index(questionMarks.endIndex, offsetBy: -1)
		let substring = questionMarks[indexRange]
		
		return String(substring)
	}
	
	/// How many groups of questions marks for a multi-insert, then specify columnCount.
	/// We want the format to be "INSERT OR REPLACE INTO table (column1, column2) VALUES (?,?),(?,?),(?,?)", and then add an array with four values. Here self = 3, columnCount = 2
	func questionMarksForQueriesWithColumns(_ columnCount: Int) -> String
	{
		if (self == 0)
		{
			//NSLog(@"AutoDB ERROR, asking for 0 objects (%@) questionMarksForQueriesWithObjects:", self);
			return "()"
		}
		
		let questionObject = "(\(columnCount.questionMarks)),"
		let questionMarks = "".padding(toLength: questionObject.count * self, withPad: questionObject, startingAt: 0)
		
		let indexRange = questionMarks.startIndex ..< questionMarks.index(questionMarks.endIndex, offsetBy: -1)
		let substring = questionMarks[indexRange]
		
		return String(substring)
	}
}
