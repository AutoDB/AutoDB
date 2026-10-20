//
//  AutoDBTrait.swift
//  AutoDBTesting
//
//  Created by Olof Andersson-Thorén on 2026-10-20.
//

import Foundation
import Testing
import AutoDB

/// Runs a suite or test against databases of its own, so suites using the same Table types can run in parallel without seeing each other's rows.
///
/// ```
/// @Suite(.autoDB)
/// struct FeedTests {
///     @Test func save() async throws {
///         let item = await FeedItem.create()   // lands in Caches/AutoDBTests/FeedTests/
///     }
/// }
/// ```
/// It runs the suite inside `AutoDBManager.withScope` with a manager from `AutoDBManager.testManager(_:)`, rooted at `Caches/AutoDBTests/<name>/`.
/// On a suite, every test and nested suite shares that manager. On a single test, that test gets its own.
/// The folder is deleted the first time a run uses it, so every run starts empty and the last run's files stay for inspection.
/// Names must be unique within a test process: two scopes in one folder would open the same files twice.
public struct AutoDBTrait: SuiteTrait, TestTrait, TestScoping {
	
	/// the folder name, nil uses the suite's or test's name
	let name: String?
	
	public var isRecursive: Bool { false }
	
	/// Once around a suite and everything in it, once around a test function and all of its cases.
	public func scopeProvider(for test: Test, testCase: Test.Case?) -> AutoDBTrait? {
		if test.isSuite || testCase == nil {
			return self
		}
		return nil
	}
	
	public func provideScope(for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void) async throws {
		let manager = AutoDBManager.testManager(name ?? test.id.nameComponents.joined(separator: "."))
		try await AutoDBManager.withScope(manager) {
			try await function()
		}
	}
}

extension Trait where Self == AutoDBTrait {
	
	/// Databases of its own in `Caches/AutoDBTests/<suite or test name>/`, see AutoDBTrait.
	public static var autoDB: AutoDBTrait {
		AutoDBTrait(name: nil)
	}
	
	/// Databases of its own in `Caches/AutoDBTests/<name>/`, see AutoDBTrait.
	public static func autoDB(_ name: String) -> AutoDBTrait {
		AutoDBTrait(name: name)
	}
}
