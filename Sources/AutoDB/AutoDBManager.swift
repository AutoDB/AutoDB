//
//  AutoDBManager.swift
//  
//
//  Created by Olof Thorén on 2021-07-05.
//

import Foundation

extension UInt64 {
	static var shortDelay: UInt64 { 9_000 }
}

@globalActor public actor AutoDBManager: GlobalActor {
	
	public static let shared = AutoDBManager()
	
	var encoders = [ObjectIdentifier: SQLRowEncoder]()
	/// get the cached encoder for this class, or create one
	func getEncoder<T: Table>(_ classType: T.Type) async throws -> SQLRowEncoder {
		if let enc = encoders[ObjectIdentifier(T.self)] {
			return enc
		}
		try await setupDB(classType, settings: nil)
		if let enc = encoders[ObjectIdentifier(T.self)] {
			return enc
		}
		let enc = await SQLRowEncoder(T.self)
		encoders[ObjectIdentifier(T.self)] = enc
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
	
	var tables = [ObjectIdentifier: TableInfo]()
    var lookupTable = LookupTable()
	var cachedObjects = [ObjectIdentifier: WeakDictionary<AutoId, AnyObject>]()
	
	static var isSetup = Set<ObjectIdentifier>()
	var databases = [ObjectIdentifier: Database]()
	var sharedDatabases = [String: Database]()

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
	
	func truncateTable<Table: Model>(token: AutoId? = nil, _ table: Table.Type) async throws {
		try await truncateTable(token: token, table.TableType.self)
	}
	
	func truncateTable<T: Table>(token: AutoId? = nil, _ table: T.Type) async throws {
		let db = try await setupDB(table)
		try await db.execute(token: token, "DELETE FROM \(table.typeName)")
		let typeID = ObjectIdentifier(T.self)
		cachedObjects[typeID] = nil
	}
	
	/// Instead of asking each Table, supply defaults for any new table. If an ObjectIdentifier of a Table.Type is not within any - settings is picked from the first existing one in order: regular, cache, specific.
	/// Bypassed if the Table has its own settings
	/// If all is empty the default is used
	public var appDefaults: [SettingsKey: (typeID: Set<ObjectIdentifier>, settings: AutoDBSettings)] = [:]
	public enum SettingsKey: Sendable {
		case regular
		case cache
		case specific
		
		static var orderedKeys: [SettingsKey] { [.regular, .cache, .specific] }
	}
	
	/// insert a new global setting for the entire app, this is a good starting point for appstart
	public nonisolated func setAppSettingsSync(_ settings: AutoDBSettings, for key: SettingsKey, typeID: ObjectIdentifier? = nil) {
		// if this is called first at startup, semaphore is not strictly necessary. But there might be situations we don't know about where this will prevent side-effects.
		let semaphore = DispatchSemaphore(value: 0)
		Task(priority: .userInitiated) {
			await setAppSettings(settings, for: key, typeID: typeID)
			semaphore.signal()
		}
		semaphore.wait()
	}
	
	public func setAppSettings(_ settings: AutoDBSettings, for key: SettingsKey, typeID: ObjectIdentifier? = nil) {
		if appDefaults[key] == nil {
			let newValue: (typeID: Set<ObjectIdentifier>, settings: AutoDBSettings) = (.init(), settings)
			appDefaults[key] = newValue
		}
		
		if let typeID {
			appDefaults[key]?.typeID.insert(typeID)
		}
	}
	
	func appSettings(_ typeID: ObjectIdentifier) -> AutoDBSettings? {
		if appDefaults.isEmpty {
			return nil
		}
		
		for key in SettingsKey.orderedKeys {
			if let settings = appDefaults[key] {
				if settings.typeID.contains(typeID) {
					return settings.1
				}
			}
		}
		
		for key in SettingsKey.orderedKeys {
			if let settings = appDefaults[key]?.1 {
				return settings
			}
		}
		return nil
	}
	
	/// Setup database for this class, attach to file defined in settings - call manually for each table  to specify your own location.
	@discardableResult
	func setupDB<TableType: Table>(_ table: TableType.Type, _ typeID: ObjectIdentifier? = nil, settings: AutoDBSettings? = nil) async throws -> Database {
		let typeID = typeID ?? ObjectIdentifier(table)
		if AutoDBManager.isSetup.insert(typeID).inserted {
			
			let database: Database
			let settings = if let tableSettings = settings ?? table.autoDBSettings() {
				tableSettings
			} else {
				appSettings(typeID) ?? AutoDBSettings()
			}
			if settings.shareDB {
				let sharedKey = "\(settings.path)\(settings.inCacheFolder ? "_cache" : "")"
				if let db = sharedDatabases[sharedKey] {
					database = db
				} else {
					database = try await initDB(settings)
					sharedDatabases[sharedKey] = database
				}
			} else {
				database = try await initDB(settings)
			}
			
			// setup table and perform migrations
			databases[typeID] = database
			let table = try await SQLTableEncoder().setup(table, database)
			tables[typeID] = table
			
			return database
		}
		
		// if two threads try to setup at the same time the other must wait
		while databases[typeID] == nil {
			try await Task.sleep(nanoseconds: .shortDelay)
		}
		return databases[typeID]!
	}
	
	func tableInfo<T: Table>(token: AutoId? = nil, _ classType: T.Type) async -> TableInfo {
		let typeID = ObjectIdentifier(classType)
		while tables[typeID] == nil {
			try? await Task.sleep(nanoseconds: .shortDelay)
		}
		return tables[typeID]!
	}
	
	@discardableResult
	func initDB(_ settings: AutoDBSettings = AutoDBSettings()) async throws -> Database {
		
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
	
	/// Get a cached object - to check if init has run, or if this is a temp-object etc
	public func cached<T: Model>(_ objectType: T.Type, _ id: AutoId) -> T? {
		let typeID = ObjectIdentifier(T.self)
		return cachedObjects[typeID]?[id] as? T
	}
	
	/// Get all cached objects
	public func cached<T: Model>(_ objectType: T.Type) async -> [T] {
		let typeID = ObjectIdentifier(T.self)
		cachedObjects[typeID]?.cleanup()
		if let cache = cachedObjects[typeID] {
			return cache.compactMap {
				$0.value.unbox as? T
			}
		}
		return []
	}
	
	func cacheObject<T: Model>(_ object: T, _ identifier: ObjectIdentifier? = nil) {
		let typeID = identifier ?? ObjectIdentifier(T.self)
		if cachedObjects[typeID] == nil {
			cachedObjects[typeID] = WeakDictionary([object.id: object])
		} else {
			cachedObjects[typeID]?[object.id] = object
		}
	}
	
	func removeFromChanged<T: Model>(_ objects: [T], _ identifier: ObjectIdentifier? = nil) async {
		let typeID = identifier ?? ObjectIdentifier(T.self)
		for object in objects {
			lookupTable.changedObjects[typeID]?.removeValue(forKey: object.id)
		}
	}
	
	// Mark this object as changed by placing it in the array - we avoid storage variables on the objects themselves. 
	func objectHasChanged<T: Model>(_ object: T, _ identifier: ObjectIdentifier? = nil) {
		lookupTable.objectHasChanged(object, identifier)
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
	
	static func fetchId<T: Table>(token: AutoId? = nil, _ id: UInt64) async throws -> T? {
		try await shared.fetchId(token: token, id)
    }
	
	/// Fetch an object with known id, throw missingId if no object was found.
	func fetchId<T: Model>(token: AutoId? = nil, _ id: UInt64) async throws -> T {
		let typeID = ObjectIdentifier(T.self)
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
	func fetchId<T: Table>(token: AutoId? = nil, _ id: UInt64) async throws -> T {
		
		let items: [T] = try await fetchQuery(token: token, "WHERE id = ?", id)
		// type system requires us to first fetch the array!
		if let item: T = items.first {
			return item
		}
		throw AutoError.missingId
	}
	
	/// Fetch objects for these ids, missing objects will not be returned and no error thrown for missing objects.
	func fetchIds<T: Model>(token: AutoId? = nil, _ ids: [UInt64]) async throws -> [T] {
		if ids.isEmpty {
			return []
		}
		let typeID = ObjectIdentifier(T.self)
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
	func fetchIds<T: Table>(token: AutoId? = nil, _ ids: [UInt64]) async throws -> [T] {
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
	
	func fetchQuery<T: Table>(token: AutoId? = nil, _ whereQuery: String, arguments: [Sendable]) async throws -> [T] {
		try await fetchQuery(token: token, whereQuery, values: try arguments.map({ try SQLValue.fromAny($0) }))
	}
	
	/// fetchQuery for objects, handles cache and relations
	func fetchQuery<T: Model>(token: AutoId? = nil, _ whereQuery: String, arguments: [Sendable]) async throws -> [T] {
		try await fetchQuery(token: token, whereQuery, values: try arguments.map({ try SQLValue.fromAny($0) }))
	}
	
	/// Fetch an AutoModel struct from the DB.
	func fetchQuery<T: Table>(token: AutoId? = nil, _ whereQuery: String, values: [SQLValue], refreshData: Bool = false) async throws -> [T] {
		try await fetchQueryRelations(token: token, whereQuery, values: values, refreshData: refreshData).map(\.0)
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
		
		// force objects to go here
		//if T.self is AnyObject.Type {
		
		let result: [(T, [AnyRelation])] = try rows.map { row in
			decoder.values = row
			return (try T(from: decoder), decoder.relations)
		}
		return result
	}
	
	/// For objects containing structs, handles cache and relations
	func fetchQuery<T: Model>(token: AutoId? = nil, _ whereQuery: String, values: [SQLValue], refreshData: Bool = false) async throws -> [T] {
		
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
			
			return object
		}
		return result
	}
	
	@discardableResult
	public func query<T: Table>(token: AutoId? = nil, _ classType: T.Type, _ query: String, _ arguments: [Sendable]? = nil) async throws -> [Row] {
		let values = try arguments?.map {
			// we must cast or somehow find out which SQL-type each argument is!
			try SQLValue.fromAny($0)
		}
		return try await self.query(token: token, classType, query, sqlArguments: values ?? [])
	}
	
	public func valueQuery<T: Table, Val: SQLColumnWrappable>(token: AutoId? = nil, _ classType: T.Type, _ query: String = "", _ arguments: [Sendable]? = nil)  async throws -> Val? {
		let rows: [Row] = try await self.query(token: token, classType, query, arguments)
		return rows.first?.values.first.flatMap {
			Val.fromValue($0)
		}
	}
	
	// MARK: - direct database access, these methods must be locked.
	
	@discardableResult
	public func query<T: Table>(token: AutoId? = nil, _ classType: T.Type, _ query: String, sqlArguments: [SQLValue] = []) async throws -> [Row] {
		let database = try await setupDB(classType)
		return try await database.query(token: token, query, sqlArguments)
	}
	
	public func transaction<T: Table, R: Sendable>(_ classType: T.Type, _ action: (@Sendable (_ db: isolated Database, _ token: AutoId) async throws -> R) ) async throws -> R {
		let database = try await setupDB(classType)
		return try await database.transaction(action)
	}
	
	// MARK: - deletion
	
	public func isDeleted(_ id: AutoId, _ typeID: ObjectIdentifier) -> Bool {
		lookupTable.isDeleted(id, typeID)
	}
	
	public func delete(token: AutoId? = nil, _ ids: [AutoId], _ typeID: ObjectIdentifier) async throws {
		
		guard ids.isEmpty == false, let table = tables[typeID] else {
			return
		}
		lookupTable.setDeleted(ids, typeID)
		
		let query = String(format: table.deleteQuery, Self.questionMarks(ids.count))
		let database = databases[typeID]!
		let values = ids.map { SQLValue.uinteger($0) }
		try await database.query(token: token, query, values)
		
		// when should we remove deleted objects from lookupTable? Perhaps never - they cannot be removed while there are still references.
		// lookupTable.removeDeleted(typeID, Set(ids))
	}
	
	// TODO: in progress
	func deleteLater(token: AutoId? = nil, _ ids: [AutoId], _ typeID: ObjectIdentifier) {
		guard ids.isEmpty == false else {
			return
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
	
	// MARK: - change callbacks just subscribe to an AsyncSequence
	public func changeObserver<T: Table>(_ classType: T.Type) async throws -> ChangeObserver {
		
		let typeID = ObjectIdentifier(classType)
		let database = try await setupDB(T.self, typeID)
		guard let table = tables[typeID] else { throw AutoError.missingSetup }
		return await database.changeObserver(table.name)
	}
	
	// MARK: - DB helper functions
	
	/// We want the format to be "INSERT OR REPLACE INTO table (column1, column2) VALUES (?,?),(?,?),(?,?)", and then add an array with four values. Here objectCount = 3, columnCount = 2
	static func questionMarksForQueriesWithObjects(_ objectCount: Int, _ columnCount: Int) -> String
	{
		if (objectCount == 0)
		{
			//NSLog(@"AutoDB ERROR, asking for 0 objects (%@) questionMarksForQueriesWithObjects:", self);
			return "()"
		}
		
		let questionObject = "(\(questionMarks(columnCount))),"
		let questionMarks = "".padding(toLength: questionObject.count * objectCount, withPad: questionObject, startingAt: 0)
		
		let indexRange = questionMarks.startIndex ..< questionMarks.index(questionMarks.endIndex, offsetBy: -1)
		let substring = questionMarks[indexRange]
		
		return String(substring)
	}
	
	static func questionMarks(_ count: Int) -> String
	{
		if count == 0 {
			return "''";	//this will make your clause look like this: ... AND column IN ('') - which is always false (unless column can be the empty string), NOT IN is always true.
		}
		let questionMarks = "".padding(toLength: count*2, withPad: "?,", startingAt: 0)
		
		let indexRange = questionMarks.startIndex ..< questionMarks.index(questionMarks.endIndex, offsetBy: -1)
		let substring = questionMarks[indexRange]
		
		return String(substring)
	}
}
