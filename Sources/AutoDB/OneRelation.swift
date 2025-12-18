//
//  OneRelation.swift
//  AutoDB
//
//  Created by Olof Andersson-Thorén on 2024-12-06.
//

// Note that this cannot be an actor since we need Encodable, it must be a class in order to set its owner automatically.
/// A one-to-one relation, typically a parent in a parent-child relation. 
public final class OneRelation<AutoType: TableModel>: Codable, RelationToOne, @unchecked Sendable {
	
	private func didChange() {
		if let owner = owner as? RelationOwner {
			Task {
				await owner.didChange()
			}
		}
	}
	
	public static func == (lhs: OneRelation<AutoType>, rhs: OneRelation<AutoType>) -> Bool {
		lhs.id == rhs.id
	}
	
	public init(_ id: AutoId = 0) {
		self.id = id
	}
	
	/// The id of the related property, note that the relation itself does not have a table.
	public var id: AutoId = 0
	public var _object: AutoType?
	weak var owner: (any Owner)? = nil
	
	// All mutations must be thread-safe
	private var semaphore = Semaphore()
	
	// we only need to store the id
	private enum CodingKeys: String, CodingKey {
		
		case id = "id"
	}
	
	public var object: AutoType {
		get async throws {
			if let _object {
				return _object
			}
			return try await fetch()
		}
		// note that 'set' accessor is not allowed on property with 'get' accessor that is 'async' or 'throws'
	}
	
	/// Populate the relation safely using locks, they do not impact performance unless congested. And then you need locks.
	/// @Throws AutoError.missingId if not set. missingRelation if object couldn't be fetched (typically due to not being saved).
	@discardableResult
	public func fetch() async throws -> AutoType {
		await semaphore.wait()
		defer { Task { await semaphore.signal() } }
		if id == 0 {
			throw AutoError.missingId
		}
		
		if let _object {
			return _object
		}
		_object = try await AutoType.fetchId(token: nil, id, nil)
		
		if let _object {
			return _object
		}
		throw AutoError.missingRelation
	}
	
	/// safely set object
	public func setObject(_ object: AutoType) async {
		await semaphore.wait()
		defer { Task { await semaphore.signal() } }
		
		_object = object
		id = object.id
		didChange()
	}
	
	/// Unsafe set - without using locks, locks does not impact performance unless congested. And then you need locks.
	public func setObject(_ object: AutoType) {
		_object = object
		id = object.id
		didChange()
	}
	
	public func setOwner<OwnerType>(_ owner: OwnerType) where OwnerType : Owner {
		self.owner = owner
	}
	
	/// Batch fetch multiple objects, use like this:
	/// let objects = ... // fetch an array of items containing a OneRelation
	/// try await objects.fetchAll(\.album) //use a keypath to unfold the relation, in this case album.
	public func fetchAll(_ list: [OneRelation]) async throws {
		if list.isEmpty { return }
		let autoType = list[0].objectType
		let typeID = ObjectIdentifier(autoType)
		let ids: [AutoId] = list.map(\.id)
		
		var fail = false
		let objects: [AutoId: AutoType] = try await autoType.fetchIds(token: nil, ids, typeID).dictionary()
		for relation in list {
			if let obj = objects[relation.id] {
				relation._object = obj
			} else {
				fail = true
			}
		}
		if fail {
			throw AutoError.missingId
		}
	}
	
	public var objectType: AutoType.Type { AutoType.self }
}
