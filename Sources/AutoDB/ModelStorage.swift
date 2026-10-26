//
//  ModelStorage.swift
//  AutoDB
//
//  Created by Olof Andersson-Thorén on 2026-08-21.
//

import Foundation
#if canImport(Observation)
	import Observation
#endif

// MARK: - ModelStorage

/// Thread-safe backing store for a Model's table value.
/// Models keep their value in a ModelStorage and have no mutable stored properties of their own,
/// so they conform to Sendable without @unchecked - the compiler then verifies all other stored properties.
/// The lock behind it is `Locked`: Synchronization.Mutex when the runtime has it, otherwise os_unfair_lock (Apple) or pthread_mutex (Linux/Android).
/// The storage is Observable: reading the value through a model registers access, every change notifies observers - so SwiftUI tracks models without @Observable.
public final class ModelStorage<T: Table>: Sendable {
	
	/// The id can never change after init, cache it so Identifiable/Hashable don't need to take the lock.
	public let id: AutoId
	
	private let storage: Locked<T>
	#if canImport(Observation)
		private let registrar = ObservationRegistrar()
	#endif
	
	public init(_ value: T) {
		self.id = value.id
		self.storage = Locked(value)
	}
	
	/// A copy of the current value.
	public func snapshot() -> T {
		#if canImport(Observation)
			registrar.access(self, keyPath: \.observedValue)
		#endif
		return observedValue
	}
	
	/// The whole value is one observable property.
	private var observedValue: T {
		storage.withLock { $0 }
	}
	
	/// Atomically read-modify-write the value. Returns the closure's result and whether the value changed.
	public func mutate<R>(_ body: (inout T) throws -> R) rethrows -> (result: R, changed: Bool) {
		let (result, changed) = try storage.withLock { value in
			let oldValue = value
			let result = try body(&value)
			return (result, oldValue != value)
		}
		if changed {
			notifyObservers()
		}
		return (result, changed)
	}
	
	/// Outside the lock, observers may read the value right away. Sent after the change since only then do we know if it changed.
	private func notifyObservers() {
		#if canImport(Observation)
			registrar.willSet(self, keyPath: \.observedValue)
			registrar.didSet(self, keyPath: \.observedValue)
		#endif
	}
}

#if canImport(Observation)
	extension ModelStorage: Observable {}
#endif

/// Shows the value in the debugger (po, Quick Look, Print Description).
/// Reads it without the lock, a paused thread - or the current one inside withValue - may hold it.
extension ModelStorage: CustomDebugStringConvertible {
	public var debugDescription: String {
		String(reflecting: storage.unsafeValue)
	}
}
