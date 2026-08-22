//
//  ModelStorage.swift
//  AutoDB
//
//  Created by Olof Andersson-Thorén on 2026-08-21.
//

import Foundation

/// Opt-in alternative to storing `value` directly: keep it in a ModelStorage instead.
/// You get `value`, an atomic `withValue` and automatic change-tracking for free (no didSet boilerplate),
/// and since the storage is the only stored property your class can drop @unchecked from Sendable:
/// ```
/// final class Person: StoredModel {
///     struct Value: Table {
///         var id: AutoId = 0
///         var name: String = ""
///     }
///     let storage: ModelStorage<Value>
///     init(_ value: Value) {
///         self.storage = ModelStorage(value)
///     }
/// }
/// ```
public protocol StoredModel: Model {
	/// The synchronized backing value, store as a `let`.
	var storage: ModelStorage<TableType> { get }
}

public extension StoredModel {
	
	/// The id is cached in the storage - no lock is taken.
	var id: AutoId {
		storage.id
	}
	
	/// Snapshot read / whole-value write, change-tracking is automatic - no need for didSet.
	/// Note that field mutation through this property (`model.value.name = "x"`) is a get-modify-set and not atomic; use withValue when competing writers are possible.
	var value: TableType {
		get {
			storage.snapshot()
		}
		set {
			if storage.mutate({ $0 = newValue }).changed {
				didChange()
			}
		}
	}
	
	/// Atomically read or modify the value, fires change-tracking when the value changed.
	@discardableResult
	func withValue<R>(_ body: (inout TableType) throws -> R) rethrows -> R {
		let (result, changed) = try storage.mutate(body)
		if changed {
			didChange()
		}
		return result
	}
}

// MARK: - ModelStorage

/// Thread-safe backing store for a Model's table value.
/// Models that keep their value in a ModelStorage (see StoredModel) have no mutable stored properties,
/// so they can conform to Sendable without @unchecked - the compiler then verifies all other stored properties.
/// The lock behind it is `Locked`: Synchronization.Mutex when the runtime has it, otherwise os_unfair_lock (Apple) or pthread_mutex (Linux/Android).
public final class ModelStorage<T: Table>: Sendable {
	
	/// The id can never change after init, cache it so Identifiable/Hashable don't need to take the lock.
	public let id: AutoId
	
	private let storage: Locked<T>
	
	public init(_ value: T) {
		self.id = value.id
		self.storage = Locked(value)
	}
	
	/// A copy of the current value.
	public func snapshot() -> T {
		storage.withLock { $0 }
	}
	
	/// Atomically read-modify-write the value. Returns the closure's result and whether the value changed.
	public func mutate<R>(_ body: (inout T) throws -> R) rethrows -> (result: R, changed: Bool) {
		try storage.withLock { value in
			let oldValue = value
			let result = try body(&value)
			return (result, oldValue != value)
		}
	}
}
