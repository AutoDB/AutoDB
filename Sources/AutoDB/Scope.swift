//
//  Scope.swift
//  AutoDB
//
//  Created by Olof Andersson-Thorén on 2026-10-20.
//

import Foundation

/// A model and the manager that created or fetched it - weak, so a dead model's slot can be told from a new object at the same address.
private struct ScopedObject: @unchecked Sendable {
	weak var object: AnyObject?
	let manager: AutoDBManager
}

/// Models that came from a manager other than `.shared`. Shared models are never stored, they fall back to `current`.
private let scopedObjects = Locked<[ObjectIdentifier: ScopedObject]>([:])
/// prune dead entries when the registry grows past this, then double it
private let scopedObjectsPruneAt = Locked<Int>(1024)

public extension AutoDBManager {
	
	/// The manager bound to this task by `withScope`, nil outside a scope.
	@TaskLocal static var scoped: AutoDBManager?
	
	/// The manager static calls use: the one bound by `withScope`, otherwise `.shared`.
	/// Task-locals flow into `Task { }` but not into `Task.detached`, DispatchQueue blocks or NotificationCenter observers - models remember their manager, so their `save()` and `delete()` still go to the right files from there.
	static var current: AutoDBManager {
		scoped ?? shared
	}
	
	/// Run operation with every AutoDB call inside it going to manager: its files, its caches and its changed objects.
	/// For tests (see the AutoDBTesting product) and for isolated databases like an import.
	/// When manager already is `current` nothing is bound, operation just runs - so the common case, a `.shared` model outside any scope, costs one comparison.
	@discardableResult
	nonisolated(nonsending) static func withScope<R>(_ manager: AutoDBManager, operation: nonisolated(nonsending) () async throws -> R) async rethrows -> R {
		if manager === current {
			return try await operation()
		}
		return try await $scoped.withValue(manager, operation: operation)
	}
	
	/// After this, every table that is not yet set up throws `AutoError.noScope` instead of opening a file through this manager.
	/// Call it on `.shared` once in a test target, so a test missing its scope fails at once instead of writing to the real database.
	func requireScope() {
		scopeRequired = true
	}
	
	/// A value that lives as long as this manager, made by `make` the first time it is asked for. Hang database-backed singletons here instead of in a static, so every scope gets its own.
	/// `make` runs outside the lock and may run twice when two callers race - the first value stored wins and every caller gets it.
	nonisolated func storage<T: Sendable>(for key: String, default make: () -> T) -> T {
		if let value = storageSlots.withLock({ $0[key] }) as? T {
			return value
		}
		let value = make()
		return storageSlots.withLock { slots in
			if let existing = slots[key] as? T {
				return existing
			}
			slots[key] = value
			return value
		}
	}
}

extension AutoDBManager {
	
	/// The manager object came from, or `current` for objects of `.shared` and objects no manager has seen.
	static func manager(of object: AnyObject?) -> AutoDBManager {
		guard let object else {
			return current
		}
		let entry = scopedObjects.withLock { $0[ObjectIdentifier(object)] }
		if let entry, entry.object === object {
			return entry.manager
		}
		return current
	}
	
	/// Remember that object belongs to this manager.
	nonisolated func remember(_ object: AnyObject) {
		if self === Self.shared {
			return
		}
		let count = scopedObjects.withLock { objects in
			objects[ObjectIdentifier(object)] = ScopedObject(object: object, manager: self)
			return objects.count
		}
		if count <= scopedObjectsPruneAt.withLock({ $0 }) {
			return
		}
		let alive = scopedObjects.withLock { objects in
			objects = objects.filter { $0.value.object != nil }
			return objects.count
		}
		scopedObjectsPruneAt.withLock { $0 = max(1024, alive * 2) }
	}
}

public extension Model {
	
	/// The manager this model came from: the one that created, fetched or registered it.
	var autoDBManager: AutoDBManager {
		AutoDBManager.manager(of: self)
	}
}
