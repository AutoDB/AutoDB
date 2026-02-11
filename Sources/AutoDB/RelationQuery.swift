//
//  RelationQuery.swift
//  AutoDB
//
//  Created by Olof Andersson-Thorén on 2024-12-05.
//

//TODO: Think this through, there are a solution!
/*
protocol ObserverSubject {
	func willChange()
}
*/
/// Since swift forces the use of names, we cannot have one RelationQuery that with combine and the same with Observable - and then a third one with nothing. So instead we have a plain RelationQuery that is an exact copy of RelationQueryObservable but that also sends changes to an asyncPublisher called changePublisher
// TODO: just solve it with a protocoll!
/// non-observable version for use in other circumstanses, just a plain copy without @Observable

#if canImport(Combine)
// if using combine, we can just send objectWillChange when owners are ObservableObject
import Combine
@available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
extension RelationQuery: ObservableObject {	//ObserverSubject
	func didChange() {
		objectWillChange.send()
		if let owner = self.owner as? any ObservableObject, let objectWillChange = owner.objectWillChange as? ObjectWillChangePublisher {
			objectWillChange.send()
		}
		if let owner = self.owner as? any RelationOwner {
			Task {
				await owner.didChange()
			}
		}
	}
}
#else
extension RelationQuery {
	func didChange() {
		if let owner = self.owner as? any RelationOwner {
			Task {
				await owner.didChange()
			}
		}
	}
}
#endif

// When using observation, we need a mediator to relay the changes upwards, must solve the name issue or figure out something smart.
#if canImport(Observation)
import Observation
/**
 A Relation based on a query that fetches incrementally.
 Specify the relation and how many objects to fetch like this:
 var cureAlbums = RelationQuery<Album>("WHERE artist = ?",  arguments: ["The Cure"], initial: 4, limit: 20)
 Now this class holds a relation to all albums of The Cure, fetched when needed.
 
 NOTE: The query obviously cannot have limit or offset clauses of its own!
 
 */
@available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
@Observable
public final class RelationQuery<AutoType: TableModel>: Codable, @unchecked Sendable, Relation {
	public static func == (lhs: RelationQuery<AutoType>, rhs: RelationQuery<AutoType>) -> Bool {
		lhs.query == rhs.query && lhs.arguments == rhs.arguments
	}
	
	weak var owner: AnyObject?
	
	/// Automatically set owner if we are inside a Model object, which is a common use-case.
	public func setOwner<OwnerType: AnyObject & Sendable>(_ owner: OwnerType) {
		
		self.owner = owner
		Task {
			try? await startListening()
			if performInitialFetch {
				// Imagine a thousend objects loaded in a list, don't fetch anything here unless you know what you are doing.
				_ = try? await self.fetchItems()
			}
		}
	}
	
	@ObservationIgnored let query: String
	
	@ObservationIgnored var arguments: [SQLValue]? = nil	// Value isn't Codable so we store arguments as strings instead.
	
	// backing var to detect access and trigger first fetch
	var _items: [AutoType]?
	public var items: [AutoType] {
		get {
			if let _items { return _items }
			_items = []
			Task {
				_ = try? await fetchItems()
			}
			return []
		}
		set {
			_items = newValue
		}
	}
	
	public var hasMore = true
	
	/// When using in a list we want to artificially limit the amount sent back to us. This way we can "fold" the list back to the initial amount.
	var restrictToInitial = false
	
	@ObservationIgnored var offset = -1
	@ObservationIgnored private var fetchedIds: Set<AutoId> = []
	@ObservationIgnored let initialFetch: Int
	@ObservationIgnored var limit: Int
	@ObservationIgnored private let semaphore = Semaphore()
	@ObservationIgnored private var performInitialFetch: Bool
	
	private enum CodingKeys: CodingKey {
		case query
		case storedArguments
		case initialFetch
		case limit
		case performInitialFetch
	}
	
	public init(_ query: String, arguments: [Sendable & Codable]? = nil, initial: Int = 5, limit: Int = 100, initFetch: Bool = false) {
		self.query = query + " LIMIT %i OFFSET %i"
		self.initialFetch = initial
		self.limit = limit
		performInitialFetch = initFetch
		
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
		performInitialFetch = (try? container.decodeIfPresent(Bool.self, forKey: .performInitialFetch)) ?? false
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
		try container.encode(self.performInitialFetch, forKey: CodingKeys.performInitialFetch)
		
	}
	
	public func startListening() async throws {
		do {
			let listener = try await AutoType.tableChangeObserver()
			Task { [weak self] in
				
				for await operation in listener {
					// must be weak inside the listener
					try? await self?.listenerCallback(operation)
				}
				print("we lost our listener!")
			}
		} catch {
			print("error: \(error)")
		}
	}
	
	private func listenerCallback(_ operation: SQLiteOperation) async throws {
		
		// note that db will always call us twice
		try await dbStateChanged(operation)
		
		// Either we must send the new objectIds and check against the query somehow, or have a little delay and fetch twice.
		//TODO: There should also be a method to add newly created objects directly, if we know this query would match against them and being used. E.g. a list with all objects, whenever a new one is created should just send it directly.
	}
	
	func dbStateChanged(_ operation: SQLiteOperation) async throws {
		
		if operation == .insert {
			// always fetch this one if offset is 0 since then it is the first item.
			// or if we have more we will get this one at next fetch, otherwise if we don't already have it - fetch it if not initialFetch amount is reached.
			if offset == 0 || hasMore == false {
				// we can't know if this query actually has more items to fetch, but this allows for the db to signal that there may be more to fetch
				hasMore = true
				if offset == 0 {
					// initial fetch failed
					_ = try await fetchItems(resetOffset: true)
				} else if offset <= initialFetch {
					// we cannot know if these new items matches our query so all we can do is trigger a basic fetch. Here is room for improvement, e.g. just check if the query is empty.
					try await fetchMore()
				} else {
					didChange()
				}
			}
		} else if operation == .delete {
			
			await semaphore.wait()
			defer { Task { await semaphore.signal() }}
			
			for index in items.indices.reversed() {
				if await items[index].isDeleted {
					fetchedIds.remove(items[index].id)
					items.remove(at: index)
					didChange()
				}
			}
		}
	}
	
	/// get the current set of items, fetching the first batch if needed
	@discardableResult
	public func fetchItems(resetOffset: Bool = false) async throws -> [AutoType] {
		await semaphore.wait()
		defer { Task { await semaphore.signal() } }
		
		if offset == -1 || (resetOffset && offset == 0) {
			// setup first fetch
			let res = try await AutoType.fetchQuery(token: nil, String(format: query, initialFetch, 0), arguments, sqlArguments: nil)
			offset = res.count
			hasMore = offset == initialFetch	// there is probably more if limit was reached
			items = res
			fetchedIds.formUnion(res.map(\.id))
			didChange()
		}
		if restrictToInitial {
			return Array(items[0..<min(items.count, initialFetch)])
		}
		return items
	}
	
	/// fetch the next batch of items if possible
	public func fetchMore() async throws {
		if offset == -1 || restrictToInitial {
			// if called before initial fetch
			_ = try await fetchItems()
			return
		}
		await semaphore.wait()
		defer { Task { await semaphore.signal() } }
		
		var res = try await AutoType.fetchQuery(token: nil, String(format: query, arguments: [limit, offset]), arguments, sqlArguments: nil)
		if res.isEmpty {
			if hasMore && items.count == offset {
				hasMore = false
				didChange()
			}
			return
		}
		hasMore = res.count == limit	// there is probably more if limit was reached
		
		let newIds = Set(res.map { $0.id })
		if newIds.isDisjoint(with: fetchedIds) == false {
			// we have changed our table in such a way that the new fetch contains old items - this is quite likely since you typically don't order items by creation-date. Refetch from 0 to get the new item in an updated list!
			res = try await AutoType.fetchQuery(token: nil, String(format: query, arguments: [offset + res.count, 0]), arguments, sqlArguments: nil)
			offset = res.count
			items = res
			
		} else {
			offset += res.count
			items.append(contentsOf: res)
		}
		fetchedIds.formUnion(res.map(\.id))
		didChange()
	}
}

#endif
