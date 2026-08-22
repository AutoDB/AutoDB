//
//  RelationQuery.swift
//  AutoDB
//
//  Created by Olof Andersson-Thorén on 2024-12-05.
//

import Foundation

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
	extension RelationQuery: ObservableObject {  //ObserverSubject
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
				// don't inherit a transaction token (we may be created while decoding inside a transaction) - the fetch should wait for the transaction, not join it
				await SemaphoreToken.detached {
					await ensureListening()
					if performInitialFetch {
						// Imagine a thousend objects loaded in a list, don't fetch anything here unless you know what you are doing.
						_ = try? await self.fetchItems()
					}
				}
			}
		}
		
		@ObservationIgnored let query: String
		
		@ObservationIgnored var arguments: [SQLValue]? = nil  // Value isn't Codable so we store arguments as strings instead.
		
		// backing var to detect access and trigger first fetch
		var _items: [AutoType]?
		public var items: [AutoType] {
			get {
				if let _items { return _items }
				_items = []
				Task {
					// don't inherit a transaction token from whoever read this property - the fetch should wait for the transaction, not join it
					await SemaphoreToken.detached {
						_ = try? await fetchItems()
					}
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
		@ObservationIgnored private var listenerTask: Task<Void, Never>?
		@ObservationIgnored private var listenerSetupTask: Task<Void, Never>?
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
		
		private func ensureListening() async {
			if listenerTask != nil {
				return
			}
			await semaphore.wait()
			defer { Task { await semaphore.signal() } }
			
			if let listenerSetupTask {
				await listenerSetupTask.value
				return
			}
			
			let setupTask: Task<Void, Never> = Task { [weak self] in
				try? await self?.startListening()
			}
			listenerSetupTask = setupTask
			await setupTask.value
		}
		
		public func startListening() async throws {
			if listenerTask != nil {
				return
			}
			
			let listener = try await AutoType.tableChangeObserver()
			let iterator = listener.makeAsyncIterator()
			listenerTask = Task { [weak self] in
				let iterator = iterator

				// long-lived listener: scrub any inherited transaction token, it would otherwise be pinned (stale) for this object's whole lifetime
				await SemaphoreToken.detached {
					while let operation = await iterator.next() {
						// must be weak inside the listener
						try? await self?.listenerCallback(operation)
					}
				}
			}
		}
		
		private func listenerCallback(_ operation: SQLiteOperation) async throws {
			
			// note that db will always call us twice
			try await dbStateChanged(operation)
			
			// Either we must send the new objectIds and check against the query somehow, or have a little delay and fetch twice.
			//TODO: There should also be a method to add newly created objects directly, if we know this query would match against them and being used. E.g. a list with all objects, whenever a new one is created should just send it directly.
		}
		
		func dbStateChanged(_ operation: SQLiteOperation) async throws {
			guard offset != -1 else {
				return
			}
			
			switch operation {
			case .insert, .delete:
				await semaphore.wait()
				defer { Task { await semaphore.signal() } }
				_ = try await refreshVisibleWindowLocked(targetVisibleCount: currentVisibleCount())
			default:
				break
			}
		}
		
		private func currentVisibleCount() -> Int {
			if offset == -1 {
				return initialFetch
			}
			return max(offset, _items?.count ?? 0, initialFetch)
		}
		
		private func fetchWindow(limit: Int, offset: Int) async throws -> [AutoType] {
			try await AutoType.fetchQuery(token: nil, String(format: query, arguments: [limit, offset]), arguments, sqlArguments: nil)
		}
		
		@discardableResult
		private func refreshVisibleWindowLocked(targetVisibleCount: Int) async throws -> [AutoType] {
			let visibleCount = max(targetVisibleCount, 0)
			let fetchCount = max(visibleCount, 1) + 1
			let res = try await fetchWindow(limit: fetchCount, offset: 0)
			let visibleItems = Array(res.prefix(visibleCount))
			
			offset = visibleItems.count
			hasMore = res.count > visibleItems.count
			items = visibleItems
			fetchedIds = Set(visibleItems.map(\.id))
			didChange()
			
			if restrictToInitial {
				return Array(visibleItems.prefix(initialFetch))
			}
			return visibleItems
		}
		
		/// get the current set of items, fetching the first batch if needed
		@discardableResult
		public func fetchItems(resetOffset: Bool = false) async throws -> [AutoType] {
			await ensureListening()
			await semaphore.wait()
			defer { Task { await semaphore.signal() } }
			
			if offset == -1 || resetOffset {
				return try await refreshVisibleWindowLocked(targetVisibleCount: initialFetch)
			}
			if restrictToInitial {
				return Array(items[0..<min(items.count, initialFetch)])
			}
			return items
		}
		
		/// fetch the next batch of items if possible
		public func fetchMore() async throws {
			// must be here if we are expecting listener callbacks, this has to do with task scheduling of setOwner - there are smarter ways to do this, will update in the future but it has no real performance hit so not pressing.
			await ensureListening()
			if offset == -1 || restrictToInitial {
				// if called before initial fetch
				_ = try await fetchItems()
				return
			}
			await semaphore.wait()
			defer { Task { await semaphore.signal() } }
			
			let currentOffset = offset
			let res = try await fetchWindow(limit: limit + 1, offset: currentOffset)
			let nextPage = Array(res.prefix(limit))
			if nextPage.isEmpty {
				hasMore = false
				didChange()
				return
			}
			
			let newIds = Set(nextPage.map(\.id))
			if newIds.isDisjoint(with: fetchedIds) == false {
				_ = try await refreshVisibleWindowLocked(targetVisibleCount: currentOffset + limit)
				return
			}
			
			offset = currentOffset + nextPage.count
			hasMore = res.count > nextPage.count
			items.append(contentsOf: nextPage)
			fetchedIds.formUnion(nextPage.map(\.id))
			didChange()
		}
	}

#endif
