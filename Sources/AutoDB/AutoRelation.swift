//
//  AutoRelation.swift
//  AutoDB
//
//  Created by Olof Andersson-Thorén on 2024-12-05.
//

import Foundation
#if canImport(SwiftUI)
import SwiftUI
#endif

public protocol AnyRelation {
	associatedtype OwnerType: AutoModelObject
	mutating func setOwner<OwnerType: AutoModelObject>(_ owner: OwnerType)
}


/**
 Contain fetching and saving in one place, having a optional backing var to know if we have fetched or not.
 A relation is an array of non-unique items of one single AutoDB type.
 Note that it will automatically call the owner of the relation when something is changed, this way you don't need to keep track of changes yourself.
 When fetching from DB this will contain no objects, you must call initFetch/Fetch first to populate the list.
 
 Usage:
final class Parent: AutoDB, @unchecked Sendable {
	
	var id: UInt64 = 0
	var name = ""
	var children = AutoRelation<Child>()
}

final class Child: AutoDB, @unchecked Sendable {
	var id: UInt64 = 0
	var name = "fox"
}
 
 let parent = try await Parent.fetchQuery(...)
 try await parent.children.fetch()
 // now items are populated with children in the order we created it:
 for child in parent.children.items {
	...
 }
 */

// Note that this cannot be an actor since we need Encodable, it can't be a struct since we then can't modify the owner's relations directly.
public final class AutoRelation<AutoType: AutoModelObject>: Codable, AnyRelation, @unchecked Sendable {
	
	public typealias OwnerType = AutoType
	
	public init(initial: Int = 150, limit: Int = 50) {
		self.initial = initial
		self.limit = limit
		ids = []
		items = []
	}
	
	// mutating funcs must be thread-safe, that is ensured by an actor-semaphore. With low congestion it only adds an extra increment of an int (and comparison) 2 extra clock cycles (and calling an actor whatever that may cost).
	private let semaphore = Semaphore()
	
	weak var owner: (any AutoModelObject)? = nil
	var limit: Int
	let initial: Int
	var hasMore = false
	
	private var ids: [AutoId]
	public var totalCount: Int {
		ids.count
	}
	
	private var _items: [AutoType]?
	public var items: [AutoType] {
		get {
			_items ?? []
		}
		set {
			_items = newValue
			owner?.didChange()
		}
	}
	
	/// This is called automatically when creating an object or when fetching from DB.
	public func setOwner<OwnerType: AutoModelObject>(_ owner: OwnerType) {
		self.owner = owner
		Task {
			try? await firstFetch()
		}
	}
	
	/// Only perform initial fetch, use when first loading or fetching from DB - to never fetch more than needed but always have some data
	@discardableResult
	public func firstFetch() async throws -> [AutoType] {
		await semaphore.wait()
		defer { Task { await semaphore.signal() } }
		
		if _items != nil {
			return items
		}
		
		let end = min(ids.count, initial)
		let idsToFetch = Array(ids[0..<end])
		_items = try await AutoType.fetchIds(idsToFetch)
		hasMore = _items?.count == initial
		
		return items
	}
	
	/// Continuesly fetch as long as there are more data
	@discardableResult
	public func fetch() async throws -> [AutoType] {
		await semaphore.wait()
		defer { Task { await semaphore.signal() } }
		
		if !hasMore {
			return items
		} else if _items == nil {
			return try await firstFetch()
		}
		
		// this is the easiest way of doing it since we want to fetch them in order.
		let fetchStep = limit
		let start = _items?.count ?? 0
		let end = min(ids.count, fetchStep)
		let idsToFetch = Array(ids[start..<end])
		let fetched = try await AutoType.fetchIds(idsToFetch)
		hasMore = fetched.count == fetchStep
		_items?.append(contentsOf: fetched)
		
		return items
	}
	
	/// Replace the items, with new items
	public func set(_ items: [AutoType]) {
		ids = items.map { $0.id }
		_items = items
		hasMore = false
		owner?.didChange()
	}
	
	/// Append more items to your relation, if not all are fetched they will not show up in the list until fetched
	public func append(_ items: any Collection<AutoType>) async {
		await semaphore.wait()
		defer { Task { await semaphore.signal() } }
		
		if hasMore {
			ids.append(contentsOf: items.map { $0.id })
			await owner?.didChange()
			return
		}
		ids.append(contentsOf: items.map { $0.id })
		if _items == nil {
			_items = Array(items)
		} else {
			_items?.append(contentsOf: items)
		}
		await owner?.didChange()
	}
	
	public func insert(contentsOf: any Collection<AutoType>, at: Int) async {
		await semaphore.wait()
		defer { Task { await semaphore.signal() } }
		
		if _items == nil {
			_items = []
		}
		_items?.insert(contentsOf: contentsOf, at: at)
		ids.insert(contentsOf: contentsOf.map { $0.id }, at: at)
		await owner?.didChange()
	}
	
	@discardableResult
	public func remove(at: Int) async -> AutoType? {
		await semaphore.wait()
		defer { Task { await semaphore.signal() } }
		
		if _items == nil {
			_items = []
		}
		let item = _items?.remove(at: at)
		if let item, let index = ids.firstIndex(of: item.id) {
			ids.remove(at: index)
		}
		await owner?.didChange()
		return item
	}
	
	/// Remove items with id, you don't need to have fetched all values before using this function
	public func remove(ids: [AutoId]) async {
		await semaphore.wait()
		defer { Task { await semaphore.signal() } }
		
		for id in ids {
			if let index = _items?.firstIndex(where: { $0.id == id }) {
				_items?.remove(at: index)
			}
			if let index = self.ids.firstIndex(of: id) {
				self.ids.remove(at: index)
			}
		}
		await owner?.didChange()
	}

#if canImport(SwiftUI)
		// TODO: make your own version of move
	public func move(fromOffsets: IndexSet, toOffset: Int) async {
		await semaphore.wait()
		defer { Task { await semaphore.signal() } }
		
		_items?.move(fromOffsets: fromOffsets, toOffset: toOffset)
		ids.move(fromOffsets: fromOffsets, toOffset: toOffset)
		await owner?.didChange()
	}
#endif
 
	private enum CodingKeys: CodingKey {
		case ids
		case initial
		case limit
	}
	
	public init(from decoder: any Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		self.ids = try container.decode([AutoId].self, forKey: .ids)
		self.initial = try container.decode(Int.self, forKey: .initial)
		self.limit = try container.decode(Int.self, forKey: .limit)
	}
	
	public func encode(to encoder: any Encoder) throws {
		var container = encoder.container(keyedBy: CodingKeys.self)
		
		try container.encode(ids, forKey: .ids)
		try container.encode(initial, forKey: .initial)
		try container.encode(limit, forKey: .limit)
	}
}
