//
//  CommonTest.swift
//  AutoDB
//
//  Created by Olof Andersson-Thorén on 2025-03-10.
//
import Foundation
import AutoDB

/// Every suite runs with `@Suite(.autoDB)`, which gives it databases of its own in `Caches/AutoDBTests/<suite>/`, so suites run in parallel even when they use the same tables.
/// Tables that should live in another file than this declare their own settings, like `static let autoDBSettings = AutoDBSettings.cache`.
extension Table {
	static var autoDBSettings: AutoDBSettings { .regular }
}

enum WaitError: Error {
	case timeRanOut
	case reason(String)
}

final class WeakBox<T: AnyObject>: @unchecked Sendable {
	weak var value: T?
}

@available(macOS 14.0, iOS 15.0, *)
public func waitForCondition(delay: Double = 15, _ reason: String? = nil, _ closure: (@Sendable () async throws -> Bool)) async throws {
	let endDate = Date.now.addingTimeInterval(delay)
	while Date.now < endDate {
		if try await closure() {
			return
		}
		try await Task.sleep(for: .milliseconds(10))
	}
	if try await closure() {
		return
	}
	if let reason = reason {
		throw WaitError.reason(reason)
	}
	throw WaitError.timeRanOut
}
