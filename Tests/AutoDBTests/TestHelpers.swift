//
//  CommonTest.swift
//  AutoDB
//
//  Created by Olof Andersson-Thorén on 2025-03-10.
//
import Foundation
import AutoDB

/// Every suite keeps its tables in a database file of its own in the cache folder, so suites never touch each other's tables and can run in parallel.
/// Point each Table of a suite at it: `static let autoDBSettings = TestDatabase.mySuite`.
/// A file is deleted the first time a run uses it, so every run starts from empty tables - the last run's file stays for inspection.
enum TestDatabase {
	static let autoDB = file("AutoDBTests")
	static let codable = file("CodableTests")
	static let delayConfig = file("DelayConfigTests")
	static let fts = file("FTSTests")
	static let manyRelation = file("ManyRelationTest")
	static let migration = file("MigrationTests")
	static let migrationContract = file("MigrationContractTests")
	static let partialRowDecode = file("PartialRowDecodeTests")
	static let relationQuery = file("RelationQueryTests")
	/// RelationQueryTests also checks relations between two database files
	static let relationQueryCache = file("RelationQueryTestsCache")
	static let saveLockOrder = file("SaveLockOrderTests")
	static let storedModel = file("StoredModelTests")
	static let taskLocalToken = file("TaskLocalTokenTests")
	static let transaction = file("TransactionTests")
	static let typeCoverage = file("TypeCoverageTests")
	
	private static func file(_ name: String) -> SettingsKey {
		let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("AutoDBTests")
		let path = folder.appendingPathComponent("\(name).db").path
		for suffix in ["", "-wal", "-shm"] {
			try? FileManager.default.removeItem(atPath: path + suffix)
		}
		return .specific(AutoDBSettings(path: path, iCloudBackup: false, inAppFolder: false, inCacheFolder: false))
	}
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
