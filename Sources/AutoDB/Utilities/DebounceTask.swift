//
//  DebounceTask.swift
//  AutoDB
//
//  Created by Olof Andersson-Thorén on 2025-12-15.
//

public actor Debounce {
	
	static let shared = Debounce()
	private var debounceTasks: [String: Task<Void, Never>] = [:]
	
	func debounce(id: AnyHashable = #function, delay: Double = 3, _ action: @escaping @Sendable () async -> Void) {
		
		let id = String(describing: id)
		debounceTasks[id]?.cancel()
		
		let debounceTask = Task {
			try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
			if Task.isCancelled == false {
				// don't inherit a transaction token from the caller - delayed actions must never re-enter a still-open transaction's lock
				await SemaphoreToken.detached {
					await action()
				}
				remove(id)
			}
		}
		
		debounceTasks[id] = debounceTask
	}
	
	private func remove(_ id: String) {
		debounceTasks[id] = nil
	}
}
