//
//  Locked.swift
//  AutoDB
//
//  Created by Olof Andersson-Thorén on 2026-08-22.
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

// MARK: - lock implementations

/// Abstract synchronized box holding a value, subclasses supply the actual lock.
/// The best available lock is picked at init by Locked.makeBox().
/// Subclasses mark `value` @exclusivity(unchecked): the lock already makes access exclusive, and the runtime check
/// would trap unsafeValue when the debugger reads it inside withLock.
private class LockBox<Value: Sendable>: @unchecked Sendable {
	func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R {
		fatalError("abstract")
	}
	
	/// The value read without taking the lock, see Locked.unsafeValue.
	var unsafeValue: Value {
		fatalError("abstract")
	}
}

#if canImport(Synchronization)
	/// First choice on all platforms: Synchronization.Mutex - a futex/os_unfair_lock-backed mutex.
	/// The mutex only guards `()` and the value is a plain stored property: Mutex keeps its value in a raw-layout cell
	/// that the debugger can't read, this way the value shows up in Xcode's variables view.
	@available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
	private final class MutexBox<Value: Sendable>: LockBox<Value>, @unchecked Sendable {
		private let mutex = Mutex(())
		@exclusivity(unchecked) private var value: Value
		
		init(_ value: Value) {
			self.value = value
		}
		
		override func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R {
			try mutex.withLock { _ in
				try body(&value)
			}
		}
		
		override var unsafeValue: Value {
			value
		}
	}
#endif

#if canImport(os)
	/// Apple platforms below the Synchronization floor: os_unfair_lock.
	/// It must never move after init, so it lives behind a stable heap allocation.
	private final class UnfairLockBox<Value: Sendable>: LockBox<Value>, @unchecked Sendable {
		private let lock: os_unfair_lock_t
		@exclusivity(unchecked) private var value: Value
		
		init(_ value: Value) {
			self.lock = os_unfair_lock_t.allocate(capacity: 1)
			self.lock.initialize(to: os_unfair_lock())
			self.value = value
		}
		
		deinit {
			lock.deinitialize(count: 1)
			lock.deallocate()
		}
		
		override func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R {
			os_unfair_lock_lock(lock)
			defer { os_unfair_lock_unlock(lock) }
			return try body(&value)
		}
		
		override var unsafeValue: Value {
			value
		}
	}
#elseif canImport(Glibc) || canImport(Musl) || canImport(Android)
	/// Linux/Android without the Synchronization module: pthread_mutex.
	/// Futex-backed and unfair on these platforms - the same class of lock as os_unfair_lock.
	/// (A userspace spinlock would burn CPU under contention, pthread_mutex spins briefly then parks.)
	/// pthread_mutex_t must never move after init, so it lives behind a stable heap allocation.
	private final class PthreadMutexBox<Value: Sendable>: LockBox<Value>, @unchecked Sendable {
		private let mutex: UnsafeMutablePointer<pthread_mutex_t>
		@exclusivity(unchecked) private var value: Value
		
		init(_ value: Value) {
			self.mutex = UnsafeMutablePointer<pthread_mutex_t>.allocate(capacity: 1)
			pthread_mutex_init(mutex, nil)
			self.value = value
		}
		
		deinit {
			pthread_mutex_destroy(mutex)
			mutex.deallocate()
		}
		
		override func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R {
			pthread_mutex_lock(mutex)
			defer { pthread_mutex_unlock(mutex) }
			return try body(&value)
		}
		
		override var unsafeValue: Value {
			value
		}
	}
#else
	/// Last resort for platforms without os or pthread (Windows, WASI): Foundation's NSLock.
	private final class NSLockBox<Value: Sendable>: LockBox<Value>, @unchecked Sendable {
		private let lock = NSLock()
		@exclusivity(unchecked) private var value: Value
		
		init(_ value: Value) {
			self.value = value
		}
		
		override func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R {
			lock.lock()
			defer { lock.unlock() }
			return try body(&value)
		}
		
		override var unsafeValue: Value {
			value
		}
	}
#endif

// MARK: - Locked

/// A lock-protected value that can be read and mutated synchronously from any thread or actor.
/// Uses Synchronization.Mutex when the runtime has it, otherwise os_unfair_lock (Apple) or pthread_mutex (Linux/Android).
public final class Locked<Value: Sendable>: Sendable {
	
	private let box: LockBox<Value>
	
	public init(_ value: Value) {
		self.box = Self.makeBox(value)
	}
	
	private static func makeBox(_ value: Value) -> LockBox<Value> {
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
	
	/// Read or mutate the value while holding the lock.
	public func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R {
		try box.withLock(body)
	}
	
	/// The value read without taking the lock - only for debugger output, where the lock may be held by a paused thread (or the current one).
	/// Racy: never use it in app code.
	var unsafeValue: Value {
		box.unsafeValue
	}
}
