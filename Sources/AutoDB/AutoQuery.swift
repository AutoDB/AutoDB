//
//  AutoQuery.swift
//  AutoDB
//
//  Created by Olof Andersson-Thorén on 2024-12-05.
//

//TODO: Think this through, we are duplicating a lot of code.
/*
protocol ObserverSubject {
	func willChange()
}

/// Since swift forces the use of names, we cannot have one AutoQuery that with combine and the same with Observable - and then a third one with nothing. So instead we have a plain AutoQuery that is an exact copy of AutoQueryObservable but that also sends changes to an asyncPublisher called changePublisher
// TODO: just solve it with a protocoll!
/// non-observable version for use in other circumstanses, just a plain copy without @Observable
public final class AutoQuery<AutoType: AutoModelObject>: Codable, @unchecked Sendable, AnyRelation {
	
	let query: String
	var arguments: [Value]? = nil
	public var items: [AutoType]
	public var hasMore = true
	let initialFetch: Int
	var limit: Int
	var offset = -1
	
	/// When using in a list we want to artificially limit the amount sent back to us. This way we can "fold" the list back to the initial amount.
	var restrictToInitial = false
	private let semaphore = Semaphore()
	/// Token to remove listener
	var listenerToken: ObjectIdentifier?
	
	// whoever is interested in changes can listen to this.
	var changePublisher = AsyncObserver<Void>()
	func didChange() async {
		await changePublisher.append(())
	}
	func changeObserver() async {
		for await _ in changePublisher {
			// there is an annoying warning here we cannot get rid of...
			if let me = self as? ObserverSubject {
				me.willChange()
			}
		}
		print("out!")
	}
	
	private enum CodingKeys: CodingKey {
		case query
		case storedArguments	// Value isn't Codable so we store arguments as strings instead.
		case initialFetch
		case limit
	}
	public init(_ query: String, arguments: [Sendable & Codable]? = nil, initial: Int = 5, limit: Int = 100) {
		self.query = query + " LIMIT %i OFFSET %i"
		items = []
		self.initialFetch = initial
		self.limit = limit
		do {
			self.arguments = try arguments?.map { try Value.fromAny($0) }
		} catch {
			print("Error for arguments: \(error)")
		}
		Task {
			await changeObserver()
		}
	}
	
	public init(from decoder: any Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		query = try container.decode(String.self, forKey: .query)
		initialFetch = try container.decode(Int.self, forKey: .initialFetch)
		limit = try container.decode(Int.self, forKey: .limit)
		items = []
		let storedArguments = try container.decodeIfPresent([String].self, forKey: .storedArguments)
		self.arguments = storedArguments?.compactMap { Value.fromSQLiteLiteral($0) }
	}
	
	public func encode(to encoder: any Encoder) throws {
		
		var container = encoder.container(keyedBy: CodingKeys.self)
		
		let storedArguments = self.arguments?.map { $0.sqliteLiteral() }
		try container.encodeIfPresent(storedArguments, forKey: CodingKeys.storedArguments)
		try container.encode(self.query, forKey: CodingKeys.query)
		try container.encode(self.initialFetch, forKey: CodingKeys.initialFetch)
		try container.encode(self.limit, forKey: CodingKeys.limit)
		
	}
	
	/// Automatically set owner if we are inside an AutoModelObject, which is the most common use-case.
	public typealias OwnerType = AutoType
	public func setOwner<OwnerType>(_ owner: OwnerType) where OwnerType: Sendable & AnyObject {
		let token = ObjectIdentifier(self)
		listenerToken = token
		Task {
			try await setCallbackOwner(owner, token)
			_ = try? await fetchItems()
		}
	}
	
	@discardableResult
	public func fetchItems(resetOffset: Bool = false) async throws -> [AutoType] {
		await semaphore.wait()
		defer { Task { await semaphore.signal() } }
		
		if offset == -1 || (resetOffset && offset == 0) {
			// setup first fetch
			let res = try await AutoType.fetchQuery(String(format: query, initialFetch, 0), arguments)
			offset = res.count
			hasMore = offset == initialFetch
			items = res
			await didChange()
		}
		if restrictToInitial {
			return Array(items[0..<min(items.count, initialFetch)])
		}
		return items
	}
	
	public func loadMore() async throws {
		await semaphore.wait()
		defer { Task { await semaphore.signal() } }
		
		var res = try await AutoType.fetchQuery(String(format: query, arguments: [limit, offset]), arguments)
		if res.isEmpty {
			return
		}
		let oldIds = Set(items.map { $0.id })
		let newIds = Set(res.map { $0.id })
		if newIds.isDisjoint(with: oldIds) == false {
			// we have changed our table in such a way that the new fetch contains old items - even if it shouldn't! Refetch from 0
			res = try await AutoType.fetchQuery(String(format: query, arguments: [offset + res.count, 0]), arguments)
			offset = res.count
			items = res
		} else {
			offset += res.count
			items.append(contentsOf: res)
		}
		
		hasMore = res.count == limit
		await didChange()
	}
}

#if canImport(Combine)
import Combine
@available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
extension AutoQuery: ObservableObject, ObserverSubject {
	func willChange() {
		objectWillChange.send()
	}
}
#endif
*/
#if canImport(Observation)
import Observation
/**
A query that fetches incrementally. Specify how many objects to fetch like this:
var cureAlbums = AutoQuery<Album>("WHERE artist = ?",  arguments: ["The Cure"], initial: 1, limit: 20)
NOTE: The query obviously cannot have limit or offset clauses of its own!
 
 Avoid using propertyWrappers if you can - they are not compatible with @Observable
 */
@available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
@Observable
public final class AutoQuery<AutoType: Model>: Codable, @unchecked Sendable, AnyRelation {
	public static func == (lhs: AutoQuery<AutoType>, rhs: AutoQuery<AutoType>) -> Bool {
		lhs.query == rhs.query && lhs.arguments == rhs.arguments
	}
	
	//public typealias OwnerType = AnyObject & Sendable
	
//	public typealias OwnerType = AutoModelObject
	
	
	
	//public typealias OwnerType = AutoModelObject
	/// Automatically set owner if we are inside an AutoModelObject, which is the most common use-case.
	public func setOwner<OwnerType: AnyObject & Sendable>(_ owner: OwnerType) {
		// when the owner deallocs, we must also dealloc.
		Task {
			try await startListening()
		}
	}
	
	@ObservationIgnored let query: String
	
	@ObservationIgnored var arguments: [SQLValue]? = nil	// Value isn't Codable so we store arguments as strings instead.
	
	public var items: [AutoType]
	public var hasMore = true
	
	/// When using in a list we want to artificially limit the amount sent back to us. This way we can "fold" the list back to the initial amount.
	var restrictToInitial = false
	
	@ObservationIgnored var offset = -1
	@ObservationIgnored private var fetchedIds: Set<AutoId> = []
	@ObservationIgnored let initialFetch: Int
	@ObservationIgnored var limit: Int
	@ObservationIgnored private let semaphore = Semaphore()
	
	private enum CodingKeys: CodingKey {
		case query
		case storedArguments
		case initialFetch
		case limit
	}
	
	public init(_ query: String, arguments: [Sendable & Codable]? = nil, initial: Int = 5, limit: Int = 100) {
		self.query = query + " LIMIT %i OFFSET %i"
		items = []
		self.initialFetch = initial
		self.limit = limit
		do {
			self.arguments = try arguments?.map { try SQLValue.fromAny($0) }
		} catch {
			print("Error for arguments: \(error)")
		}
	}
	
	public init(from decoder: any Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		query = try container.decode(String.self, forKey: .query)
		initialFetch = try container.decode(Int.self, forKey: .initialFetch)
		limit = try container.decode(Int.self, forKey: .limit)
		items = []
		let storedArguments = try container.decodeIfPresent([String].self, forKey: .storedArguments)
		self.arguments = storedArguments?.compactMap { SQLValue.fromSQLiteLiteral($0) }
	}
		
	public func encode(to encoder: any Encoder) throws {
		
		var container = encoder.container(keyedBy: CodingKeys.self)
		
		let storedArguments = self.arguments?.map { $0.sqliteLiteral() }
		try container.encodeIfPresent(storedArguments, forKey: CodingKeys.storedArguments)
		try container.encode(self.query, forKey: CodingKeys.query)
		try container.encode(self.initialFetch, forKey: CodingKeys.initialFetch)
		try container.encode(self.limit, forKey: CodingKeys.limit)
		
	}
	
	public func startListening() async throws {
		
		let listener = try await AutoType.changeObserver()
		Task { [weak self] in
			
			_ = try? await self?.fetchItems()
			
			for await change in listener {
				// must be weak inside the listener
				try await self?.listenerCallback(change.operation, change.id)
			}
		}
	}
	
	private func listenerCallback(_ operation: SQLiteOperation, _ rowId: AutoId) async throws {
		if operation == .insert, !hasMore, fetchedIds.contains(rowId) == false {
			hasMore = true
			if offset == 0 {
				// initial fetch failed
				_ = try await fetchItems(resetOffset: true)
			} else if offset <= initialFetch {
				// we know the next item - just fetch with id.
				try await fetchSpecific(rowId)
			}
		} else if operation == .delete {
			await semaphore.wait()
			defer { Task { await semaphore.signal() }}
			
			guard let deletedIndex = items.firstIndex(where: { $0.id == rowId }) else { return }
			items.remove(at: deletedIndex)
			fetchedIds.remove(rowId)
		}
	}
	
	@discardableResult
	public func fetchItems(resetOffset: Bool = false) async throws -> [AutoType] {
		await semaphore.wait()
		defer { Task { await semaphore.signal() } }
		
		if offset == -1 || (resetOffset && offset == 0) {
			// setup first fetch
			let res = try await AutoType.fetchQuery(String(format: query, initialFetch, 0), arguments)
			offset = res.count
			hasMore = offset == initialFetch
			items = res
			fetchedIds.formUnion(res.map(\.id))
		}
		if restrictToInitial {
			return Array(items[0..<min(items.count, initialFetch)])
		}
		return items
	}
	 
	public func loadMore() async throws {
		await semaphore.wait()
		defer { Task { await semaphore.signal() } }
		
		var res = try await AutoType.fetchQuery(String(format: query, arguments: [limit, offset]), arguments)
		if res.isEmpty {
			if hasMore {
				hasMore = false
			}
			return
		}
		let newIds = Set(res.map { $0.id })
		if newIds.isDisjoint(with: fetchedIds) == false {
			// we have changed our table in such a way that the new fetch contains old items - this is quite likely since you typically don't order items by creation-date. Refetch from 0 to get the new item in an updated list!
			res = try await AutoType.fetchQuery(String(format: query, arguments: [offset + res.count, 0]), arguments)
			offset = res.count
			items = res
		} else {
			offset += res.count
			items.append(contentsOf: res)
		}
		fetchedIds.formUnion(res.map(\.id))
		
		hasMore = res.count == limit
	}
	
	/// When you know the id of the next item, just fetch it and increment offset.
	public func fetchSpecific(_ id: AutoId) async throws {
		await semaphore.wait()
		defer { Task { await semaphore.signal() } }
		
		let item = try await AutoType.fetchId(id)
		items.append(item)
		fetchedIds.insert(item.id)
		offset += 1
		hasMore = false
	}
}

#endif
