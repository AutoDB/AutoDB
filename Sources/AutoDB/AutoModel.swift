import Foundation

/*
 Create your data classes like this:
 
 final class Example: AutoModel, @unchecked Sendable {
	var id: AutoId = 0
	// then fill in what ever variables you like below
	var name: String = "Olof"
	...
	
	// then we can have indcies, sadly these must be stringly typed. Perhaps we can read codables CodingKeys somehow and improve this in the future.
	static var uniqueIndices: [[String]] { [["name"]] }
 }
 
 1. All AutoModels must allow setting their id AND be sendable. This is impossible. The only solution is to mark your classes as @unchecked Sendable. The whole point of AutoDB is to have classes that are created in a concurrency-safe fashion, but that you can modify and access from any thread. So it is not possible to do this in any other way and would otherwise defeat the purpose.
 2. They must also be final since the framework must be able to create objects with a blank init() method due to Swift's type system and codable. That also makes having init methods pointless.
 3. They inherit Codable to be able to be stored in a DB. There could be other ways to do this, and perhaps will migrate in the future.
*/

public enum AutoError: Error {
	case fetchError
	/// we must have an id to create AutoModel objects
	case missingId
	/// Somehow this table was never setup
	case missingSetup
	/// one or more object has been deleted or never saved, but the relation wasn't updated.
	case missingRelation
	/// if you don't have FTS5 support, you cannot use full text search
	case noFTSSupport
}

public enum TableError: Error {
	case notAutoModelClass
	case impossibleUrlMigration
}

///Class specific settings to generate SQL information that can't be known automatically, each DB needs to define its path and cache settings. Then every table may subscribe to one of these settings, if none is chosen the default will be used
public struct AutoDBSettings: Sendable {
    
	// Common settings for all tables to be stored in the cache
	static func cache(path: String = "AutoDB.db", ignoreProperties: Set<String>? = nil, shareDB: Bool = true) -> AutoDBSettings {
		AutoDBSettings(path: path, iCloudBackup: false, inCacheFolder: true, ignoreProperties: ignoreProperties, shareDB: shareDB)
	}
	
	// Common settings for all tables to be stored in the app-folder and allow for being backed up.
	public init(path: String = "AutoDB.db", iCloudBackup: Bool = true, inCacheFolder: Bool = false, ignoreProperties: Set<String>? = nil, shareDB: Bool = true) {
		self.path = path
		self.iCloudBackup = iCloudBackup
		self.inCacheFolder = inCacheFolder
		self.ignoreProperties = ignoreProperties
		self.shareDB = shareDB
	}
	
	let path: String
	let iCloudBackup: Bool
	let inCacheFolder: Bool
	
	/// Should this get its own unique actor to issue queries from, or share with other tables with the same DB-file? If you have a lot of writes it is usually FASTER to share (one actor are better at scheduling than many SQLite connectors who uses locks with busy/retries). In normal usage you won't see any difference so there is typically no need to split them up. It may improve performance in some esotheric situations, so the option is available. Measure!
	let shareDB: Bool
	
	/// by default we store everything, note that this is controlled by CodingKeys already only use if you must include a CodingKey that you don't want to be stored.
	let ignoreProperties: Set<String>?
}

public typealias AutoId = UInt64
public extension AutoId {
	static func generateId() -> AutoId {
		
		let random = random(in: 1..<AutoId.max)
		return random >> 4  //save some bits for Swift's optimisations
	}
}

public typealias AnyAutoModel = (any AutoModel)
public typealias AutoModelObject = (AutoModel & AnyObject)

/// A set of column names.
public typealias ColumnNames = Set<String>
/// AutoDB tructs need to implement this protocol - not completed, just proof of concept that it works.
public protocol AutoDBStruct {}

/// All table classes must implement AutoDB and be @unchecked Sendable. Regular Sendable is not meaningful (must both be decodable and owned by a global actor).
public protocol AutoModel: Codable, Hashable, Identifiable, Sendable, AnyObject {
	typealias ColumnKeyPath = PartialKeyPath<Self>
	var allKeyPaths: [String: ColumnKeyPath] { get }
	
	// To construct tables we must create empty objects, since Swift doesn't allow meta programming
	init()
	// Sometimes you know the id, then the object needs to be returned or created. and inserted into DB at next save
	static func create(token: AutoId?, _ id: AutoId?) async -> Self
	/// The unique id that identifies this object
	var id: AutoId { get set }
	static func autoDBSettings() -> AutoDBSettings? //implement using "class func ..."
	
	/// return a list of keypaths to the variables that have index, grouped together to make multi-column index
	/// We can't use KeyPaths, so we have to check indices in runtime instead.
	static var indices: [[String]] { get }
	/// return a list of keypaths to the variables that have unique index, grouped together to make multi-column index
	static var uniqueIndices: [[String]] { get }
	
	/// If this object needs to be saved at some point in the future
	func didChange() async
    
	/// Called after fetching from DB, default implementation does nothing
	func awakeFromFetch()
	
	/// Called after calling the create() method, calls setOwnerOnRelations() - call this if you implement this function
	func awakeFromInit()
	
	/// Find relationship-variables and set the owner
	func setOwnerOnRelations()
	
	/// Fetch one object, throw missingId if no object was found
	static func fetchId(token: AutoId?, _ id: AutoId) async throws -> Self
	static func fetchIds(token: AutoId?, _ ids: [AutoId]) async throws -> [Self]
	
	/// Fetch all objects matching this query.
	static func fetchQuery(token: AutoId?, _ query: String, _ arguments: [Sendable]?) async throws -> [Self]
	//static func fetchQuery(_ query: String, _ arguments: Sendable...) async throws -> [Self]
	/// save and wait until completed, potentially handling errors
	func save(token: AutoId?) async throws
	/// save and don't wait until completed, ignoring errors
	//func save(token: AutoId?) - if we don't include it in the protocol Swift adds it from the extension
	/// save changes to all objects of the same type and wait until completed, potentially handling errors
	static func saveChanges(token: AutoId?) async throws
	/// save changes to all objects of the same type and don't wait until completed, ignoring errors
	static func saveChangesDetached(token: AutoId?)
	/// save changes to all changed objects and wait until completed, potentially handling errors
	static func saveAllChanges(token: AutoId?) async throws
	/// save changes to all changed objects and don't wait until completed, ignoring errors
	static func saveAllChangesDetacted(token: AutoId?)
}

public extension AutoModel {
	
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
	
	static func == (lhs: Self, rhs: Self) -> Bool {
		lhs.id == rhs.id
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
	
	/*
	 it is possible to allow for structs, but don't know if it will ever be used.
	static func create(_ id: AutoId? = nil) async -> Self where Self : AutoDBStruct {
		let id = id ?? generateId()
		if let item = await AutoDBManager.shared.cached(Self.self, id) {
			return item
		} else {
			var item = Self()
			item.id = id
			return item
		}
	}
	*/
	
	static func create(token: AutoId? = nil, _ id: AutoId? = nil) async -> Self where Self : AnyObject {
		if let id {
			if let item = await AutoDBManager.shared.cached(Self.self, id) {
				return item
			} else if let item = try? await fetchId(token: token, id) {
				return item
			}
		}
		
		// no id or not in DB, create new object
		let item = Self()
		item.id = id ?? AutoId.generateId()
		await item.setup()
		return item
	}
	
	func setup() async {
		await AutoDBManager.shared.cacheObject(self)
		self.awakeFromInit()
	}
	
	func awakeFromInit() {
		setOwnerOnRelations()
	}
	
	func setOwnerOnRelations() {
		for (_, value) in self.allKeyPaths {
			if var relation = self[keyPath: value] as? any AnyRelation {
				relation.setOwner(self)
			}
		}
	}
	
	func awakeFromFetch() {}
	
	/// Get this class AutoDB which allows direct SQL-access. You may setup db and override the class' settings, the first time you call this
	@discardableResult
	static func db(_ settings: AutoDBSettings? = nil) async throws -> AutoDB {
		try await AutoDBManager.shared.setupDB(self, nil, settings: settings ?? autoDBSettings())
	}
	
	/// Run actions inside a transaction - any thrown error causes the DB to rollback (and the error is rethrown).
	/// ⚠️  Must use token for all db-access inside transactions, otherwise will deadlock. ⚠️
	/// Why? Since async/await and actors does not and can not deal with threads, there is no other way of knowing if you are inside the transaction / holding the lock.
	static func transaction<R: Sendable>(_ action: (@Sendable (_ db: isolated AutoDB, _ token: AutoId) async throws -> R) ) async throws -> R {
		try await db().transaction(action)
	}
	
	static func autoDBSettings() -> AutoDBSettings? {
		nil
	}
	
	/// return a list of variable names that have index, group together to make multi-column index
	static var indices: [[String]] { [] }
	/// return a list of variable names that have unique index, group together to make multi-column index
	static var uniqueIndices: [[String]] { [] }
	
	// MARK: - fetch shortcuts
	
	static func fetchId(token: AutoId? = nil, _ id: AutoId) async throws -> Self where Self: AnyObject {
		
		try await AutoDBManager.shared.fetchId(token: token, id)
	}
	static func fetchIds(token: AutoId? = nil, _ ids: [AutoId]) async throws -> [Self] where Self: AnyObject {
		try await AutoDBManager.shared.fetchIds(token: token, ids)
	}
	
	static func fetchQuery(token: AutoId? = nil, _ query: String = "", _ arguments: [Sendable]? = nil) async throws -> [Self] where Self: AnyObject {
		try await AutoDBManager.shared.fetchQuery(token: token, query, arguments: arguments ?? [])
	}
	
	
	static func fetchQuery(token: AutoId? = nil, _ query: String = "", _ arguments: [SQLValue]? = nil) async throws -> [Self] where Self: AnyObject {
		try await AutoDBManager.shared.fetchQuery(token: token, query, arguments: arguments ?? [])
	}
	
	/*
	 
	@discardableResult
	static func query(_ query: String = "", _ arguments: Sendable...)  async throws -> [Row] {
		try await AutoDBManager.shared.query(Self.self, query, arguments)
	}*/
	
	@discardableResult
	static func query(token: AutoId? = nil, _ query: String = "", _ arguments: [Sendable]? = nil)  async throws -> [Row] {
		try await AutoDBManager.shared.query(token: token, Self.self, query, arguments)
	}
	
	@discardableResult
	static func query(token: AutoId? = nil, _ query: String = "", _ arguments: [SQLValue]? = nil)  async throws -> [Row] {
		try await AutoDBManager.shared.query(token: token, Self.self, query, arguments)
	}
	
	/// A non-throwable query, returns nil instead of throwing
	@discardableResult
	static func queryNT(token: AutoId? = nil, _ query: String = "", arguments: [Sendable]? = nil) async -> [Row]? {
		try? await AutoDBManager.shared.query(token: token, Self.self, query, arguments)
	}
	
	static func valueQuery<Val: SQLColumnWrappable>(token: AutoId? = nil, _ query: String = "", _ arguments: [Sendable]? = nil)  async throws -> Val? {
		try await AutoDBManager.shared.valueQuery(token: token, Self.self, query, arguments)
	}
	
	
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
	
	static func saveList(token: AutoId? = nil, _ objects: [Self]) async throws {
		guard objects.isEmpty == false else { return }
		
		let encoder = try await AutoDBManager.shared.getEncoder(Self.self)
		await encoder.semaphore.wait()
		defer { Task { await encoder.semaphore.signal() }}
		
		for object in objects {
			try object.encode(to: encoder)
		}
		// apply dbSemaphoreToken if we have one
		try await encoder.commit(token)
		
		//remove all changed objects
		let typeID = ObjectIdentifier(self)
		await AutoDBManager.shared.removeFromChanged(objects, typeID)
	}
	
	var isDeleted: Bool {
		get async {
			await AutoDBManager.shared.isDeleted(id, ObjectIdentifier(Self.self))
		}
	}
	
	func delete(token: AutoId? = nil) async throws {
		try await Self.deleteIds([id])
	}
	
	static func deleteIds(token: AutoId? = nil, _ ids: [AutoId]) async throws {
		try await AutoDBManager.shared.delete(token: token, ids, ObjectIdentifier(self))
	}
	
	static func deleteIdsLater(token: AutoId? = nil, _ ids: [AutoId]) async {
		await AutoDBManager.shared.deleteLater(token: token, ids, ObjectIdentifier(self))
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
	
	// MARK: - callbacks
	
	static func changeObserver() async throws -> ChangeObserver {
		try await AutoDBManager.shared.changeObserver(Self.self)
	}
}

public extension Collection where Element: AutoModel {
	
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
