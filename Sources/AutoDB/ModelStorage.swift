//
//  ModelStorage.swift
//  AutoDB
//
//  Created by Olof Andersson-Thorén on 2026-08-21.
//

import Foundation
#if canImport(Synchronization)
	import Synchronization
#endif
#if canImport(os)
	import os
#elseif canImport(Glibc)
	import Glibc
#elseif canImport(Musl)
	import Musl
#elseif canImport(Android)
	import Android
#endif

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

// MARK: - lock implementations

/// Abstract synchronized box holding a table value, subclasses supply the actual lock.
/// The best available lock is picked at init by ModelStorage.makeBox().
private class ValueBox<T: Table>: @unchecked Sendable {
	func snapshot() -> T {
		fatalError("abstract")
	}
	func mutate<R>(_ body: (inout T) throws -> R) rethrows -> (result: R, changed: Bool) {
		fatalError("abstract")
	}
}

#if canImport(Synchronization)
	/// First choice on all platforms: Synchronization.Mutex - a fully checked, futex/os_unfair_lock-backed mutex.
	@available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
	private final class MutexBox<T: Table>: ValueBox<T>, @unchecked Sendable {
		private let mutex: Mutex<T>
		
		init(_ value: T) {
			self.mutex = Mutex(value)
		}
		
		override func snapshot() -> T {
			mutex.withLock { $0 }
		}
		
		override func mutate<R>(_ body: (inout T) throws -> R) rethrows -> (result: R, changed: Bool) {
			// Mutex.withLock requires a sending result, so keep the caller's R outside the closure.
			var result: R?
			let changed = try mutex.withLock { value -> Bool in
				let oldValue = value
				result = try body(&value)
				return oldValue != value
			}
			return (result!, changed)
		}
	}
#endif

#if canImport(os)
	/// Apple platforms below the Synchronization floor: os_unfair_lock.
	/// It must never move after init, so it lives behind a stable heap allocation.
	private final class UnfairLockBox<T: Table>: ValueBox<T>, @unchecked Sendable {
		private let lock: os_unfair_lock_t
		private var value: T
		
		init(_ value: T) {
			self.lock = os_unfair_lock_t.allocate(capacity: 1)
			self.lock.initialize(to: os_unfair_lock())
			self.value = value
		}
		
		deinit {
			lock.deinitialize(count: 1)
			lock.deallocate()
		}
		
		override func snapshot() -> T {
			os_unfair_lock_lock(lock)
			defer { os_unfair_lock_unlock(lock) }
			return value
		}
		
		override func mutate<R>(_ body: (inout T) throws -> R) rethrows -> (result: R, changed: Bool) {
			os_unfair_lock_lock(lock)
			defer { os_unfair_lock_unlock(lock) }
			let oldValue = value
			let result = try body(&value)
			return (result, oldValue != value)
		}
	}
#elseif canImport(Glibc) || canImport(Musl) || canImport(Android)
	/// Linux/Android without the Synchronization module: pthread_mutex.
	/// Futex-backed and unfair on these platforms - the same class of lock as os_unfair_lock.
	/// (A userspace spinlock would burn CPU under contention, pthread_mutex spins briefly then parks.)
	/// pthread_mutex_t must never move after init, so it lives behind a stable heap allocation.
	private final class PthreadMutexBox<T: Table>: ValueBox<T>, @unchecked Sendable {
		private let mutex: UnsafeMutablePointer<pthread_mutex_t>
		private var value: T
		
		init(_ value: T) {
			self.mutex = UnsafeMutablePointer<pthread_mutex_t>.allocate(capacity: 1)
			pthread_mutex_init(mutex, nil)
			self.value = value
		}
		
		deinit {
			pthread_mutex_destroy(mutex)
			mutex.deallocate()
		}
		
		override func snapshot() -> T {
			pthread_mutex_lock(mutex)
			defer { pthread_mutex_unlock(mutex) }
			return value
		}
		
		override func mutate<R>(_ body: (inout T) throws -> R) rethrows -> (result: R, changed: Bool) {
			pthread_mutex_lock(mutex)
			defer { pthread_mutex_unlock(mutex) }
			let oldValue = value
			let result = try body(&value)
			return (result, oldValue != value)
		}
	}
#else
	/// Last resort for platforms without os or pthread (Windows, WASI): Foundation's NSLock.
	private final class NSLockBox<T: Table>: ValueBox<T>, @unchecked Sendable {
		private let lock = NSLock()
		private var value: T
		
		init(_ value: T) {
			self.value = value
		}
		
		override func snapshot() -> T {
			lock.lock()
			defer { lock.unlock() }
			return value
		}
		
		override func mutate<R>(_ body: (inout T) throws -> R) rethrows -> (result: R, changed: Bool) {
			lock.lock()
			defer { lock.unlock() }
			let oldValue = value
			let result = try body(&value)
			return (result, oldValue != value)
		}
	}
#endif

// MARK: - ModelStorage

/// Thread-safe backing store for a Model's table value.
/// Models that keep their value in a ModelStorage (see StoredModel) have no mutable stored properties,
/// so they can conform to Sendable without @unchecked - the compiler then verifies all other stored properties.
/// Uses Synchronization.Mutex when the runtime has it, otherwise os_unfair_lock (Apple) or pthread_mutex (Linux/Android).
public final class ModelStorage<T: Table>: Sendable {
	
	/// The id can never change after init, cache it so Identifiable/Hashable don't need to take the lock.
	public let id: AutoId
	
	private let box: ValueBox<T>
	
	public init(_ value: T) {
		self.id = value.id
		self.box = Self.makeBox(value)
	}
	
	private static func makeBox(_ value: T) -> ValueBox<T> {
		#if canImport(Synchronization)
			if #available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *) {
				return MutexBox(value)
			}
		#endif
		#if canImport(os)
			return UnfairLockBox(value)
		#elseif canImport(Glibc) || canImport(Musl) || canImport(Android)
			return PthreadMutexBox(value)
		#else
			return NSLockBox(value)
		#endif
	}
	
	/// A copy of the current value.
	public func snapshot() -> T {
		box.snapshot()
	}
	
	/// Atomically read-modify-write the value. Returns the closure's result and whether the value changed.
	public func mutate<R>(_ body: (inout T) throws -> R) rethrows -> (result: R, changed: Bool) {
		try box.mutate(body)
	}
}
