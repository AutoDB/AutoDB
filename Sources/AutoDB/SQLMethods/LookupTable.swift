//
//  LookupTable.swift
//  
//
//  Created by Olof Thorén on 2021-07-05.
//

import Foundation

///Generic implementation of a table to lookup AutoModel objects that has changed, will be deleted and similar.
struct LookupTable {
	
	var changedObjects = [ObjectIdentifier: [AutoId: any AutoModel]]()
	var deleted = [ObjectIdentifier: Set<AutoId>]()
	
	/// Mark an object as deleted, we can now batch delete at a future time and prevent saves.
	mutating func setDeleted(_ ids: [AutoId], _ isDeleted: Bool, _ typeID: ObjectIdentifier) {
		
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
	
	mutating func objectHasChanged<T: AutoModel>(_ object: T, _ identifier: ObjectIdentifier? = nil) {
        
		objectHasChanged(object.id, object, identifier)
    }
    
	mutating func objectHasChanged<T: AutoModel>(_ id: UInt64, _ object: T, _ identifier: ObjectIdentifier?) {
		
		let identifier = identifier ?? ObjectIdentifier(T.self)
		if isDeleted(id, identifier) {
			return
		}
        if changedObjects[identifier] == nil {
			changedObjects[identifier] = [id: object]
        }
        else if changedObjects[identifier]?[object.id] == nil {
			changedObjects[identifier]?[id] = object
        }
    }
}

