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
	
	/// The app's manager, used by every call outside `withScope`.
	public static let shared = AutoDBManager()
	
	/// Where this manager keeps its files, nil for the real locations. See `init(root:)`.
	public nonisolated let root: URL?
	/// full-text search state of this manager's tables
	nonisolated let ftsHandler = FTSHandler()
	/// coalesces saveAllChangesLater
	private let debounce = Debounce()
	/// see storage(for:default:)
	nonisolated let storageSlots = Locked<[String: any Sendable]>([:])
	/// set by requireScope(), setupDB throws instead of opening a database
	var scopeRequired = false
	
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
		let enc = try await SQLRowEncoder(T.self, self)
		encoders[typeID ?? ObjectIdentifier(T.self)] = enc
		return enc
	}
	
	/// A fresh encoder for one save: the table's encoding comes from the cached template, the row buffers are the caller's alone - so saves need no lock.
	func rowEncoder<T: Table>(_ classType: T.Type, _ typeID: ObjectIdentifier? = nil) async throws -> SQLRowEncoder {
		SQLRowEncoder(template: try await getEncoder(classType, typeID))
	}
	
	private var creationLocks = [ObjectIdentifier: Semaphore]()
	/// the lock create() holds so two tasks never create the same object at the same time - one per type, taken after the database's transaction slot
	func creationLock(_ typeID: ObjectIdentifier) -> Semaphore {
		if let lock = creationLocks[typeID] {
			return lock
		}
		let lock = Semaphore()
		creationLocks[typeID] = lock
		return lock
	}
	
	var decoders = [ObjectIdentifier: SQLRowDecoder]()
	/// get the cached decoder for this class, or create one
	func getDecoder<T: Table>(_ classType: T.Type) async throws -> SQLRowDecoder {
		let typeID = ObjectIdentifier(T.self)
		if let enc = decoders[typeID] {
			return enc
		}
		let table = try await tableInfo(T.self)
		let dec = SQLRowDecoder(T.self, table)
		decoders[ObjectIdentifier(T.self)] = dec
		return dec
	}
	
	/// The table's columns as AutoDB created them: name, SQL type, Swift type and nullability. Sets the table up first.
	public func columns<T: Table>(_ type: T.Type) async throws -> [Column] {
		try await tableInfo(T.self).columns
	}
	
	/// `base` with the row's columns decoded over it. Columns the row lacks keep base's values, a NULL clears an optional.
	/// For partial rows that come from outside the database (sync, imports).
	public func decode<T: Table>(_ row: Row, into base: T) async throws -> T {
		let decoder = SQLRowDecoder(T.self, try await tableInfo(T.self), row, base: base)
		return try T(from: decoder)
	}
	
	private var tables = [ObjectIdentifier: TableInfo]()
	var lookupTable = LookupTable()
	var cachedObjects = [ObjectIdentifier: WeakDictionary<AutoId, AnyObject>]()
	private var createdObjects = [ObjectIdentifier: Set<AutoId>]()
	private var modelCacheIdentifiersByTableIdentifier = [ObjectIdentifier: Set<ObjectIdentifier>]()
	
	var databases = [ObjectIdentifier: Database]()
	var sharedDatabases = [DatabaseLocation: Database]()
	/// the settings each shared database was opened with, the first settings for a location win
	private var openedSettings = [DatabaseLocation: AutoDBSettings]()
	
	// TODO: Android/Linux memory pressure, see Backlog.md
	#if canImport(Darwin)
		// keep track of low memory warnings, save any unsaved objects to release memory.
		private let lowMemoryEventSource: DispatchSourceMemoryPressure
	#endif
	
	/// A manager with its own databases, caches and changed objects. Bind it with `withScope` to use it.
	/// With a root, every file database lives inside root instead of its real location: app-folder settings in `root/Application Support/<path>`, cache-folder settings in `root/Caches/<path>`, absolute paths in `root/<file name>`. Memory databases are private to the manager either way.
	public init(root: URL? = nil) {
		self.root = root
		#if canImport(Darwin)
			lowMemoryEventSource = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical])
			lowMemoryEventSource.setEventHandler { [weak self] in
				guard let self else { return }
				Task {
					try? await self.saveAllChanges()
				}
			}
			lowMemoryEventSource.resume()
		#endif
	}
	
	#if canImport(Darwin)
		deinit {
			lowMemoryEventSource.cancel()
		}
	#endif
	
	/// Only use this when testing, may create dublicate objects when live objects are saved.
	func truncateTable<T: Table>(_ table: T.Type) async throws {
		let db = try await setupDB(table)
		try await db.execute("DELETE FROM \(table.tableName)")
		let typeID = ObjectIdentifier(T.self)
		clearCachedState(for: typeID)
		
		if let relatedModelTypeIDs = modelCacheIdentifiersByTableIdentifier[typeID] {
			for modelTypeID in relatedModelTypeIDs {
				clearCachedState(for: modelTypeID)
			}
		}
	}
	
	private func clearCachedState(for typeID: ObjectIdentifier) {
		cachedObjects[typeID] = nil
		createdObjects[typeID] = nil
		lookupTable.clear(typeID)
	}
	
	private let setupSemaphore = Semaphore()
	
	/// migration info, to get a callback when migration is done simply call: `_ = try await table.db()` which will wait until migration is complete.
	func migrationState<TableType: Table>(_ table: TableType.Type, _ typeID: ObjectIdentifier? = nil) async -> MigrationTableState {
		let typeID = typeID ?? ObjectIdentifier(table)
		if databases[typeID] != nil {
			return .done
		}
		return .isMigrating
	}
	
	/// one lock per table for its first-time setup, taken inside the database's transaction slot (see setupDB)
	private var setupLocks = [ObjectIdentifier: Semaphore]()
	private func setupLock(_ typeID: ObjectIdentifier) -> Semaphore {
		if let lock = setupLocks[typeID] {
			return lock
		}
		let lock = Semaphore()
		setupLocks[typeID] = lock
		return lock
	}
	
	/// The Database for these settings, created once. The setup semaphore only guards this - opening the file - never table work.
	private func sharedDatabase(for settings: AutoDBSettings) async throws -> Database {
		// in theory you could have multiple actors for the same file, but that is always a bad idea.
		let location = location(for: settings)
		if let db = sharedDatabases[location] {
			warnIfDifferent(settings, location)
			return db
		}
		// many threads will go here at the same time at startup, they need to wait.
		await setupSemaphore.wait()
		defer { Task { await setupSemaphore.signal() } }
		if let db = sharedDatabases[location] {
			warnIfDifferent(settings, location)
			return db
		}
		let database = try await initDB(settings)
		sharedDatabases[location] = database
		openedSettings[location] = settings
		return database
	}
	
	private var warnedLocations = Set<DatabaseLocation>()
	/// two different settings for the same file share the first one's connection, say so once
	private func warnIfDifferent(_ settings: AutoDBSettings, _ location: DatabaseLocation) {
		guard let opened = openedSettings[location], opened != settings, warnedLocations.insert(location).inserted else { return }
		AutoLog.error("two AutoDBSettings resolve to the same file \(location); the first one's options are in use. First: \(opened), ignored: \(settings)")
	}
	
	/// Where these settings put the database: App Support or Caches (plus the app name on macOS) joined with path, path itself when both folder flags are false, or memory.
	nonisolated static func location(for settings: AutoDBSettings) -> DatabaseLocation {
		if settings.inMemory {
			return .memory
		}
		guard settings.inAppFolder || settings.inCacheFolder else {
			return .file(settings.path)
		}
		let url = settings.inCacheFolder ? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0] : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
		var path = url.path
		if path.hasSuffix("/") == false {
			path += "/"
		}
		#if os(macOS)
			let appName = Bundle.main.infoDictionary?["CFBundleName"] as? String ?? Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String ?? "AutoDBApp"
			path += appName + "/"
		#endif
		return .file(path + settings.path)
	}
	
	/// Where these settings put the database for this manager: `Self.location(for:)` moved inside root when there is one.
	nonisolated func location(for settings: AutoDBSettings) -> DatabaseLocation {
		let location = Self.location(for: settings)
		guard let root, case .file(let path) = location else {
			return location
		}
		if settings.inCacheFolder {
			return .file(root.appendingPathComponent("Caches").appendingPathComponent(settings.path).path)
		}
		if settings.inAppFolder {
			return .file(root.appendingPathComponent("Application Support").appendingPathComponent(settings.path).path)
		}
		return .file(root.appendingPathComponent(URL(fileURLWithPath: path).lastPathComponent).path)
	}
	
	/// The file these settings open through this manager, nil for a memory database.
	public nonisolated func fileURL(for settings: AutoDBSettings) -> URL? {
		guard case .file(let path) = location(for: settings) else {
			return nil
		}
		return URL(fileURLWithPath: path)
	}
	
	/// Setup database for this class, attach to file defined in settings. Settings defaults to .main, implement autoDBSettings in each Table to specify location or use the cache.
	///
	/// Lock order: the database's transaction slot first (`excludingTransactions`), then this table's own setup lock. The table's queries - PRAGMA, CREATE, a copy for changed columns - wait for an open transaction otherwise.
	/// Inside a transaction the ambient token re-enters both, so a first-time setup from inside a transaction is fine, and other tables are never held back by this one.
	@discardableResult
	func setupDB<TableType: Table>(_ table: TableType.Type, _ typeID: ObjectIdentifier? = nil) async throws -> Database {
		let typeID = typeID ?? ObjectIdentifier(table)
		if let db = databases[typeID] {
			return db
		}
		if scopeRequired {
			throw AutoError.noScope("\(table) used outside a test database")
		}
		let tableSettings = table.autoDBSettings
		let database = try await sharedDatabase(for: tableSettings)
		let lock = setupLock(typeID)
		
		return try await database.excludingTransactions {
			let token = SemaphoreToken.current
			await lock.wait(token: token)
			defer { Task { await lock.signal(token: token) } }
			// set up meanwhile by whoever held the lock
			if let db = await self.databases[typeID] {
				return db
			}
			// user migrations call the static API, bind ourselves so it comes back here
			return try await Self.withScope(self) {
				try await self.setUpTable(table, typeID, database, tableSettings)
			}
		}
	}
	
	/// the table's first-time setup: create or migrate it and register it. Runs with the table's setup lock held, inside the transaction slot.
	private func setUpTable<TableType: Table>(_ table: TableType.Type, _ typeID: ObjectIdentifier, _ database: Database, _ settings: AutoDBSettings) async throws -> Database {
		do {
			let (encoder, migrations) = try await SQLTableEncoder().setup(table, database, settings)
			tables[typeID] = encoder
			
			if let migrations, migrations.isEmpty == false {
				// migrations run inside a transaction so a failure rolls the table back. The table is registered first: a migration callback's own queries on it must hit the fast path, not set it up again.
				try? await database.transaction { db in
					await self.setDatabase(db, typeID)
					for migration in migrations {
						await TableType.migration(database, migration)
						
						if case MigrationState.changes(let tempTableName, _) = migration {
							try await database.query("DROP TABLE `\(tempTableName)`")
						}
					}
				}
			} else {
				databases[typeID] = database
			}
			return database
			
		} catch {
			if case Database.Error.databaseIsClosed = error {
				print("database is closed error, perhaps switching DB-path during migrations? \(error)")
			} else {
				print("error setting up database: \(error) probably uncaught migration error, check your migrations!")
			}
			throw error
		}
	}
	
	func setDatabase(_ db: Database, _ typeID: ObjectIdentifier) {
		databases[typeID] = db
	}
	
	/// The table's info, setting the table up first when needed.
	func tableInfo<T: Table>(_ classType: T.Type) async throws -> TableInfo {
		try await setupDB(classType)
		return try tableInfo(ObjectIdentifier(classType))
	}
	
	/// The info of a table this manager has set up. Throws instead of waiting: a table setupDB refused, like one used outside a required scope, never shows up.
	func tableInfo(_ typeID: ObjectIdentifier) throws -> TableInfo {
		if let table = tables[typeID] {
			return table
		}
		if scopeRequired {
			throw AutoError.noScope("a table was used outside a test database")
		}
		throw AutoError.missingSetup
	}
	
	@discardableResult
	func initDB(_ settings: AutoDBSettings) async throws -> Database {
		
		guard case .file(let path) = location(for: settings) else {
			// memory databases never auto-close: closing one discards its data
			return try Database(nil)
		}
		print("sqlite3 \"\(path)\"")
		let db = try Database(path, key: try await settings.encryptionKey?(), keyProvider: settings.encryptionKey)
		await db.setAutoClose(after: settings.autoCloseDelay)
		
		// exclude from backup if desired
		if settings.iCloudBackup == false {
			var values = URLResourceValues()
			values.isExcludedFromBackup = true
			var url = URL(fileURLWithPath: path)
			try? url.setResourceValues(values)
			for suffix in ["-shm", "-wal"] {
				url = URL(fileURLWithPath: path.appending(suffix))
				try? url.setResourceValues(values)
			}
		}
		return db
	}
	
	#if SQLCipher
		/// Re-encrypt the database of these settings with key. Store the new key where the settings' key closure reads it before calling this, or the next open uses the old key and throws wrongEncryptionKey.
		public func changeEncryptionKey(for settings: AutoDBSettings, to key: EncryptionKey) async throws {
			guard settings.isEncrypted else {
				throw Database.Error.notEncrypted
			}
			try await sharedDatabase(for: settings).changeEncryptionKey(to: key)
		}
	#endif
	
	func lookupObjectsCount(_ tableName: ObjectIdentifier) async -> Int {
		lookupTable.changedObjects[tableName]?.count ?? 0
	}
	
	// Mark this object as changed by placing it in the array - we avoid storage variables on the objects themselves.
	func objectHasChanged<T: Model>(_ object: T, _ identifier: ObjectIdentifier? = nil) {
		let modelTypeID = identifier ?? ObjectIdentifier(T.self)
		registerModelCacheIdentifier(modelTypeID, tableTypeID: object.valueIdentifier)
		lookupTable.objectHasChanged(object, modelTypeID)
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
		guard var objects = cachedObjects[typeID] else {
			return nil
		}
		
		return objects[id] as? T
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
		registerModelCacheIdentifier(typeID, tableTypeID: object.valueIdentifier)
		remember(object)
		if cachedObjects[typeID] == nil {
			cachedObjects[typeID] = WeakDictionary([object.id: object])
		} else {
			cachedObjects[typeID]?[object.id] = object
		}
	}
	
	private func registerModelCacheIdentifier(_ modelTypeID: ObjectIdentifier, tableTypeID: ObjectIdentifier) {
		if modelCacheIdentifiersByTableIdentifier[tableTypeID] == nil {
			modelCacheIdentifiersByTableIdentifier[tableTypeID] = [modelTypeID]
		} else {
			modelCacheIdentifiersByTableIdentifier[tableTypeID]?.insert(modelTypeID)
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
	
	// MARK: other lookup functions
	
	/// cached relation-keypath lookups. Read synchronously from any thread when creating/decoding objects
	/// (setOwnerOnRelations cannot await), so it is guarded by a lock instead of the actor.
	private let optimizations = Locked<[ObjectIdentifier: Optimizations]>([:])
	
	nonisolated func optimization<T: Model>(_ t: T, _ identifier: ObjectIdentifier? = nil) -> Optimizations? {
		let typeID = identifier ?? ObjectIdentifier(T.self)
		return optimizations.withLock { $0[typeID] }
	}
	
	nonisolated func setOptimization<T: Model>(_ t: T, identifier: ObjectIdentifier? = nil, _ opt: Optimizations) {
		let typeID = identifier ?? ObjectIdentifier(T.self)
		optimizations.withLock { storage in
			var optimize = storage[typeID] ?? Optimizations()
			if let relations = opt.relationPaths {
				optimize.relationPaths = relations
			}
			if let innerRelations = opt.innerRelations {
				optimize.innerRelations = innerRelations
			}
			storage[typeID] = optimize
		}
	}
	
	// MARK: - fetching
	
	static func fetchId<T: Table>(_ id: UInt64, _ identifier: ObjectIdentifier? = nil) async throws -> T? {
		try await current.fetchId(id)
	}
	
	/// Fetch an object with known id, throw missingId if no object was found.
	func fetchId<T: Model>(_ id: UInt64, _ typeIDIn: ObjectIdentifier? = nil) async throws -> T {
		let typeID = typeIDIn ?? ObjectIdentifier(T.self)
		if let obj = cachedObjects[typeID]?[id] as? T {
			return obj
		}
		let items: [T] = try await fetchQuery("WHERE id = ?", id)
		if let item: T = items.first {
			return item
		}
		throw AutoError.missingId
	}
	
	/// Fetch an object with known id, throw missingId if no object was found.
	func fetchId<T: Table>(_ id: UInt64, _ identifier: ObjectIdentifier? = nil) async throws -> T {
		
		let items: [T] = try await fetchQuery("WHERE id = ?", id)
		// type system requires us to first fetch the array!
		if let item: T = items.first {
			return item
		}
		throw AutoError.missingId
	}
	
	/// Fetch objects for these ids, missing objects will not be returned and no error thrown for missing objects.
	func fetchIds<T: Model>(_ ids: [UInt64], _ identifier: ObjectIdentifier?) async throws -> [T] {
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
		let list: [AutoId: T] = try await fetchQuery("WHERE id IN (\(questionMarks))", arguments: fetchIds.map({ SQLValue.uinteger($0) })).dictionary()
		
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
	func fetchIds<T: Table>(_ ids: [UInt64], _ identifier: ObjectIdentifier? = nil) async throws -> [T] {
		if ids.isEmpty {
			return []
		}
		
		let questionMarks = Self.questionMarks(ids.count)
		return try await fetchQuery("WHERE id IN (\(questionMarks))", arguments: ids.map({ SQLValue.uinteger($0) }))
	}
	
	func fetchQuery<T: Table>(_ query: String, _ arguments: Sendable...) async throws -> [T] {
		try await fetchQuery(query, arguments: arguments)
	}
	func fetchQuery<T: Model>(_ query: String, _ arguments: Sendable...) async throws -> [T] {
		try await fetchQuery(query, arguments: arguments)
	}
	
	/// Fetch an AutoModel struct from the DB.
	func fetchQuery<T: Table>(_ whereQuery: String, arguments: [Sendable]? = nil, sqlArguments: [SQLValue]? = nil, refreshData: Bool = false) async throws -> [T] {
		let values = try sqlArguments ?? arguments?.map { try SQLValue.fromAny($0) }
		
		return try await fetchQueryRelations(whereQuery, values: values ?? [], refreshData: refreshData).map(\.0)
	}
	
	func fetchQueryRelations<T: Table>(_ whereQuery: String, values: [SQLValue], refreshData: Bool = false) async throws -> [(T, [AnyRelation])] {
		
		let typeID = ObjectIdentifier(T.self)
		try await setupDB(T.self, typeID)
		let decoder = try await getDecoder(T.self)
		let table = decoder.tableInfo
		
		let columnNames = table.columnNameString
		let query = "SELECT \(columnNames) FROM \(table.name) \(whereQuery)"
		let rows = try await self.query(T.self, query, values)
		if rows.isEmpty {
			return []
		}
		
		// decode all fetched values
		let result: [(T, [AnyRelation])] = try rows.map { row in
			decoder.values = row
			do {
				let value = try T(from: decoder)
				return (value, decoder.relations)
			} catch {
				// this only happens if we have a type that we can't decode, which shouldn't happen...
				print("decode error: \(error)")
				throw error
			}
		}
		return result
	}
	
	/// fetchQuery for objects containing structs, handles cache and relations
	func fetchQuery<T: Model>(_ whereQuery: String, arguments: [Sendable]? = nil, sqlArguments: [SQLValue]? = nil, refreshData: Bool = false) async throws -> [T] {
		let values = try sqlArguments ?? arguments?.map({ try SQLValue.fromAny($0) }) ?? []
		let rows: [(T.TableType, [AnyRelation])] = try await fetchQueryRelations(whereQuery, values: values)
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
	public func query<T: Table>(_ classType: T.Type, _ query: String, _ arguments: [Sendable]? = nil, sqlArguments: [SQLValue]? = nil) async throws -> [Row] {
		let database = try await setupDB(classType)
		
		let values =
			try sqlArguments
			?? arguments?.map {
				// we must cast or somehow find out which SQL-type each argument is!
				try SQLValue.fromAny($0)
			}
		return try await database.query(query, sqlArguments: values ?? [])
	}
	
	/// Execute a query, e.g. an INSERT or UPDATE statement. Will use converted sqlArguments if provided, otherwise it will convert the arguments. Returns the number of affected rows.
	@discardableResult
	public func execute<T: Table>(_ classType: T.Type, _ query: String, _ arguments: [Sendable]? = nil, sqlArguments: [SQLValue]? = nil) async throws -> Int {
		
		let database = try await setupDB(classType)
		let values =
			try sqlArguments
			?? arguments?.map {
				// we must cast or somehow find out which SQL-type each argument is!
				try SQLValue.fromAny($0)
			}
		return try await database.execute(query, sqlArguments: values ?? [])
	}
	
	/// Fetch a single value from the database, e.g. a count or sum.
	public func valueQuery<T: Table, Val: SQLColumnWrappable>(_ classType: T.Type, _ query: String = "", _ arguments: [Sendable]? = nil, sqlArguments: [SQLValue]? = nil) async throws -> Val? {
		let rows: [Row] = try await self.query(classType, query, arguments, sqlArguments: sqlArguments)
		return rows.first?.values.first.flatMap {
			Val.fromValue($0)
		}
	}
	
	/*
	/// Decode into a special result struct - useful for select id, name ... etc.
	public func decodeQuery<T: Table, Val: SQLColumnWrappable>(_ classType: T.Type, _ query: String = "", _ arguments: [Sendable]? = nil, sqlArguments: [SQLValue]? = nil) async throws -> Val? {
		let rows: [Row] = try await self.query(classType, query, arguments, sqlArguments: sqlArguments)
		return rows.first?.values.first.flatMap {
			Val.fromValue($0)
		}
	}
	*/
	
	/// Fetch a single column/value from the database, e.g. a list of ids or strings.
	///return an array with all values in the result for a (the first) column.
	public func groupConcatQuery<T: Table, Val: SQLColumnWrappable>(_ classType: T.Type, _ query: String = "", _ arguments: [Sendable]? = nil) async throws -> [Val] {
		let rows: [Row] = try await self.query(classType, query, arguments)
		
		return rows.compactMap {
			if let value = $0.first?.value {
				Val.fromValue(value)
			} else {
				nil
			}
		}
	}
	
	// MARK: - direct database access, these methods must be locked.
	
	public func transaction<T: Table, R: Sendable>(_ classType: T.Type, _ action: (@Sendable (_ db: isolated Database) async throws -> R)) async throws -> R {
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
	
	/// Delete rows of a table, setting it up first when needed.
	public func delete<T: Table>(_ ids: [AutoId], _ classType: T.Type) async throws {
		if ids.isEmpty {
			return
		}
		try await setupDB(classType)
		try await delete(ids, ObjectIdentifier(classType))
	}
	
	/// Delete rows of a table this manager has set up, throws `missingSetup` otherwise - pass the type to set it up.
	public func delete(_ ids: [AutoId], _ typeID: ObjectIdentifier) async throws {
		
		guard ids.isEmpty == false else {
			return
		}
		let table = try tableInfo(typeID)
		lookupTable.setDeleted(ids, typeID)
		
		let query = String(format: table.deleteQuery, Self.questionMarks(ids.count))
		let database = databases[typeID]!
		let values = ids.map { SQLValue.uinteger($0) }
		try await database.query(query, values)
		
		// when should we remove deleted objects from lookupTable? Perhaps never - they cannot be removed while there are still references.
		// lookupTable.removeDeleted(typeID, Set(ids))
	}
	
	// MARK: - debounce delays
	
	/// The standard wait for all debounced work: idle auto-close, saveChangesLater, saveAllChangesLater and deleteLater.
	public static let defaultWaitTime: Double = 3
	
	/// how long saveChangesLater / saveAllChangesLater coalesces changes before saving
	public private(set) var saveLaterDelay: Double = AutoDBManager.defaultWaitTime
	/// how long deleteLater waits before performing the delete
	public private(set) var deleteLaterDelay: Double = AutoDBManager.defaultWaitTime
	
	/// Change how long saveChangesLater / saveAllChangesLater waits before saving. Takes effect for saves scheduled after the change.
	public func setSaveLaterDelay(_ seconds: Double) {
		saveLaterDelay = seconds
	}
	
	/// Change how long deleteLater waits before performing the delete. Takes effect for deletes scheduled after the change.
	public func setDeleteLaterDelay(_ seconds: Double) {
		deleteLaterDelay = seconds
	}
	
	/// margin added on top of a debounce delay when holding a connection open for it, so the flush wins the race against the idle auto-close despite timer jitter
	private static let keepOpenMargin: Double = 0.5
	
	/// postpone auto-close of this type's database while delayed work waits to run
	private func keepDatabaseOpen(_ typeID: ObjectIdentifier, for seconds: Double) async {
		await databases[typeID]?.keepOpen(for: seconds + Self.keepOpenMargin)
	}
	
	/// postpone auto-close of every database while delayed work waits to run
	private func keepAllDatabasesOpen(for seconds: Double) async {
		for db in sharedDatabases.values {
			await db.keepOpen(for: seconds + Self.keepOpenMargin)
		}
	}
	
	/// wait while the task exists, cancel if needed.
	var deleteLaterTask: Task<Void, Never>?
	
	/// coalesce multiple objects to be deleted at the next saveChanges.
	func deleteLater(_ ids: [AutoId], _ typeID: ObjectIdentifier) async {
		guard ids.isEmpty == false else {
			return
		}
		
		await keepDatabaseOpen(typeID, for: deleteLaterDelay)
		lookupTable.setDeleteLater(ids, typeID)
		if deleteLaterTask != nil {
			return
		}
		// bind nil around the Task creation - task-locals are captured when the Task is created, so this delayed save never inherits a transaction token and can't re-enter a still-open transaction's lock
		SemaphoreToken.$current.withValue(nil) {
			deleteLaterTask = Task {
				do {
					// TODO: Think: should we leave this to the app instead and just wait for saveAllChanges to be called?
					try await Task.sleep(nanoseconds: .seconds(deleteLaterDelay))
					try await saveAllChanges()
				} catch {
					// stopped or failing.
				}
				deleteLaterTask = nil
			}
		}
	}
	
	// MARK: - save
	
	public func saveAllChanges() async throws {
		var anyError: Error? = nil
		// delete objects waiting for deletion first, just like the typed saveChanges - otherwise a lone deleteLater is never carried out
		for (typeID, ids) in lookupTable.deleteLater where ids.isEmpty == false {
			do {
				try await delete(Array(ids), typeID)
				lookupTable.removeDeleteLater(typeID, ids)
			} catch {
				anyError = error
			}
		}
		let buckets = Array(lookupTable.changedObjects.values)
		for bucket in buckets {
			do {
				// saveList is static, bind ourselves so it saves here
				try await Self.withScope(self) {
					try await bucket.saveChanges()
				}
			} catch {
				anyError = error
			}
		}
		if let anyError {
			throw anyError
		}
	}
	
	/// coalesce all changes and save later, typically used when multiple changes are made to the same object, and you only care that the last save is executed. Waits saveLaterDelay seconds (3 by default, see setSaveLaterDelay).
	nonisolated public func saveAllChangesLater() {
		Task {
			await self.keepAllDatabasesOpen(for: self.saveLaterDelay)
			await self.debounce.debounce(delay: self.saveLaterDelay) {
				do {
					try await self.saveAllChanges()
				} catch {
					print("saveAllChangesLater error: \(error)")
				}
			}
		}
	}
	
	/// Calls saveChanges for this class type, the reason this function exist is to circumvent Swift's type system and allows us to call a static func using an object.
	public func saveChanges<T: Model>(_ class: T) async throws {
		try await saveChanges(T.self)
	}
	
	/// delete objects waiting for deletion and save changed objects for this class
	public func saveChanges<T: Model>(_ classType: T.Type) async throws {
		var anyError: Error? = nil
		let typeID = ObjectIdentifier(T.self)
		if let ids = lookupTable.deleteLater[typeID] {
			do {
				try await delete(Array(ids), typeID)
				lookupTable.removeDeleteLater(typeID, ids)
			} catch {
				anyError = error
			}
		}
		
		if let bucket = lookupTable.changedObjects[typeID] as? ChangedModelBucket<T> {
			try await Self.withScope(self) {
				try await bucket.saveChanges()
			}
		}
		if let anyError {
			throw anyError
		}
	}
	
	// temporary storage for tasks
	var debounceTasks: [ObjectIdentifier: Task<Void, Error>] = [:]
	
	/// coalesce changes for this class type and save later, typically used when multiple changes are made to the same object, and you only care that the last save is executed. Each call postpones the save by saveLaterDelay seconds (3 by default, see setSaveLaterDelay).
	public func saveChangesLater<T: Model>(_ classType: T.Type) async {
		
		let typeID = ObjectIdentifier(T.self)
		debounceTasks[typeID]?.cancel()
		await keepDatabaseOpen(typeID, for: saveLaterDelay)
		
		// bind nil around the Task creation - task-locals are captured when the Task is created, so this delayed save never inherits a transaction token and can't re-enter a still-open transaction's lock
		debounceTasks[typeID] = SemaphoreToken.$current.withValue(nil) {
			Task {
				try await Task.sleep(nanoseconds: .seconds(saveLaterDelay))
				debounceTasks[typeID] = nil
				do {
					try await saveChanges(T.self)
				} catch {
					print("saveChangesLater(\(classType)) error: \(error)")
					throw error
				}
			}
		}
	}
	
	// MARK: - change callbacks just subscribe to an AsyncSequence
	
	public func tableChangeObserver<T: Table>(_ classType: T.Type) async throws -> TableChangeObserver {
		
		let typeID = ObjectIdentifier(classType)
		let database = try await setupDB(T.self, typeID)
		let table = try tableInfo(typeID)
		return await database.tableChangeObserver(table.name)
	}
	
	public func rowChangeObserver<T: Table>(_ classType: T.Type) async throws -> RowChangeObserver {
		
		let typeID = ObjectIdentifier(classType)
		let database = try await setupDB(T.self, typeID)
		let table = try tableInfo(typeID)
		return await database.rowChangeObserver(table.name)
	}
	
	// MARK: - open and close db
	
	/// Close all databases within waitSec. allowReopen: the next access reopens a database transparently, pass false to keep them closed until open().
	/// Close all file databases, memory databases are skipped since closing one discards its data.
	public func close(waitSec: Double = 10, allowReopen: Bool = true) async {
		for db in sharedDatabases where db.key != .memory {
			await db.value.close(waitSec: waitSec, allowReopen: allowReopen)
		}
	}
	
	/// Open after close
	public func open() async {
		for db in sharedDatabases {
			try? await db.value.open()
		}
	}
	
	/// Change the idle auto-close delay for all databases, nil disables auto-close.
	public func setAutoClose(after delay: Double?) async {
		for db in sharedDatabases {
			await db.value.setAutoClose(after: delay)
		}
	}
	
	// MARK: - DB helper functions
	
	/// We want the format to be "INSERT OR REPLACE INTO table (column1, column2) VALUES (?,?),(?,?),(?,?)", and then add an array with four values. Here objectCount = 3, columnCount = 2
	nonisolated public static func questionMarksForQueriesWithObjects(_ objectCount: Int, _ columnCount: Int) -> String {
		
		objectCount.questionMarksForQueriesWithColumns(columnCount)
	}
	
	nonisolated
		public static func questionMarks(_ count: Int) -> String
	{
		
		count.questionMarks
	}
}

public extension Int {
	var questionMarks: String {
		if self == 0 {
			return "''";  //this will make your clause look like this: ... AND column IN ('') - which is always false (unless column can be the empty string), NOT IN is always true.
		}
		let questionMarks = "".padding(toLength: self * 2, withPad: "?,", startingAt: 0)
		
		let indexRange = questionMarks.startIndex..<questionMarks.index(questionMarks.endIndex, offsetBy: -1)
		let substring = questionMarks[indexRange]
		
		return String(substring)
	}
	
	/// How many groups of questions marks for a multi-insert, then specify columnCount.
	/// We want the format to be "INSERT OR REPLACE INTO table (column1, column2) VALUES (?,?),(?,?),(?,?)", and then add an array with four values. Here self = 3, columnCount = 2
	func questionMarksForQueriesWithColumns(_ columnCount: Int) -> String {
		if (self == 0) {
			//NSLog(@"AutoDB ERROR, asking for 0 objects (%@) questionMarksForQueriesWithObjects:", self);
			return "()"
		}
		
		let questionObject = "(\(columnCount.questionMarks)),"
		let questionMarks = "".padding(toLength: questionObject.count * self, withPad: questionObject, startingAt: 0)
		
		let indexRange = questionMarks.startIndex..<questionMarks.index(questionMarks.endIndex, offsetBy: -1)
		let substring = questionMarks[indexRange]
		
		return String(substring)
	}
}
