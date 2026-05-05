//
//  CommonTest.swift
//  AutoDB
//
//  Created by Olof Andersson-Thorén on 2025-03-10.
//
import Foundation

enum WaitError: Error {
	case timeRanOut
	case reason(String)
}

final class WeakBox<T: AnyObject>: @unchecked Sendable {
	weak var value: T?
}

@available(macOS 14.0, iOS 15.0, *)
public func waitForCondition(delay: Double = 15, _ reason: String? = nil, _ closure: ( @Sendable () async throws -> Bool)) async throws {
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
