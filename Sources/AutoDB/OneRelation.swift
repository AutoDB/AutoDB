//
//  OneRelation.swift
//  AutoDB
//
//  Created by Olof Andersson-Thorén on 2024-12-06.
//

// Note that this cannot be an actor since we need Encodable, it must be a class in order to set its owner automatically.
/// A one-to-one relation,
public final class OneRelation<AutoType: Model>: Codable, AnyRelation, @unchecked Sendable {
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
			try await fetch()
		}
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
		_object = try await AutoType.fetchId(id)
		
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
}
