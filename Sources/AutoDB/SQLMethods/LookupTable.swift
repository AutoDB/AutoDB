//
//  LookupTable.swift
//
//
//  Created by Olof Thorén on 2021-07-05.
//

import Foundation

class AnyChangedModelBucket: @unchecked Sendable {
	var count: Int { 0 }
	
	func removeValue(forKey id: AutoId) {}
	
	func saveChanges(token: AutoId?) async throws {}
}

final class ChangedModelBucket<T: Model>: AnyChangedModelBucket, @unchecked Sendable {
	private var values = [AutoId: T]()
	
	override var count: Int { values.count }
	
	func insert(_ id: AutoId, _ object: T) {
		if values[object.id] == nil {
			values[object.id] = object
		}
	}
	
	override func removeValue(forKey id: AutoId) {
		values.removeValue(forKey: id)
	}
	
	override func saveChanges(token: AutoId?) async throws {
		let pendingValues = Array(values.values)
		guard pendingValues.isEmpty == false else {
			return
		}
		try await T.saveList(token: token, pendingValues)
	}
}

///Generic implementation of a table to lookup AutoModel objects that has changed, will be deleted and similar.
struct LookupTable {
	
	var changedObjects = [ObjectIdentifier: AnyChangedModelBucket]()
	var deleted = [ObjectIdentifier: Set<AutoId>]()
	var deleteLater = [ObjectIdentifier: Set<AutoId>]()
	
	private mutating func changedBucket<T: Model>(
		for identifier: ObjectIdentifier,
		as type: T.Type = T.self
	) -> ChangedModelBucket<T> {
		if let bucket = changedObjects[identifier] as? ChangedModelBucket<T> {
			return bucket
		}
		
		let bucket = ChangedModelBucket<T>()
		changedObjects[identifier] = bucket
		return bucket
	}
	
	/// Mark an object as deleted, prevent save for any lingering objects
	mutating func setDeleted(_ ids: [AutoId], _ typeID: ObjectIdentifier) {
		
		if deleted[typeID] == nil {
			deleted[typeID] = Set(ids)
		} else {
			deleted[typeID]?.formUnion(ids)
		}
		for id in ids {
			changedObjects[typeID]?.removeValue(forKey: id)
		}
	}
	
	mutating func removeDeleted(_ identifier: ObjectIdentifier, _ toRemove: Set<AutoId>) {
		deleted[identifier]?.subtract(toRemove)
		for id in toRemove {
			changedObjects[identifier]?.removeValue(forKey: id)
		}
	}
	
	func isDeleted(_ id: AutoId, _ identifier: ObjectIdentifier) -> Bool {
		deleted[identifier]?.contains(id) ?? false
	}
	
	/// Mark an object as deleted, but don't delete it - we can now batch delete at a future time and prevent saves.
	mutating func setDeleteLater(_ ids: [AutoId], _ typeID: ObjectIdentifier) {
		
		if deleteLater[typeID] == nil {
			deleteLater[typeID] = Set(ids)
		} else {
			deleteLater[typeID]?.formUnion(ids)
		}
		setDeleted(ids, typeID)
	}
	
	mutating func removeDeleteLater(_ identifier: ObjectIdentifier, _ toRemove: Set<AutoId>) {
		deleteLater[identifier]?.subtract(toRemove)
	}
	
	mutating func objectHasChanged<T: Model>(_ object: T, _ identifier: ObjectIdentifier? = nil) {
		
		objectHasChanged(object.id, object, identifier)
	}
	
	mutating func objectHasChanged<T: Model>(_ id: UInt64, _ object: T, _ identifier: ObjectIdentifier?) {
		
		let identifier = identifier ?? ObjectIdentifier(T.self)
		if isDeleted(id, identifier) {
			return
		}
		
		let bucket = changedBucket(for: identifier, as: T.self)
		bucket.insert(id, object)
	}
	
	mutating func clear(_ identifier: ObjectIdentifier) {
		changedObjects[identifier] = nil
		deleted[identifier] = nil
		deleteLater[identifier] = nil
	}
}
