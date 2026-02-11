//
//  CodableTests.swift
//  AutoDB
//
//  Created by Olof Andersson-Thorén on 2025-09-23.
//

import Testing
@testable import AutoDB

public enum Status: UInt, Sendable, Codable {
	case ok = 1
}

// build support for SQLUIntegerEnum

public struct OptionState: OptionSet, Sendable, Codable, Hashable {
	public let rawValue: UInt
	
	public init(rawValue: UInt) {
		self.rawValue = rawValue
	}
	
	public static func == (lhs: OptionState, rhs: OptionState) -> Bool
	{
		return lhs.rawValue == rhs.rawValue
	}
	
	public static let isFavorite = OptionState(rawValue: 1)
	public static let long = OptionState(rawValue: 9837875)
	public static let changedValue = OptionState(rawValue: 6)
}

public enum StringEnum: String, Codable, Sendable {
	case firstValue = "first"
	case changedValue = "changed"
}

struct OptionTable: Table {
	static let tableName = "optiontable"
	var id: AutoId = 1
	var state: OptionState = .isFavorite
	var name: StringEnum = .firstValue
}

class CodableTests {
	
	@Test func testEnumCodable() async throws {
		
		try await OptionTable.truncateTable()
		var option: OptionTable? = await OptionTable.create()
		option?.name = .changedValue
		option?.state = .changedValue
		try await option?.save()
		option = nil
		AutoDBManager.shared.cachedObjects
		
		option = try await OptionTable.fetchQuery("WHERE name = ?", [StringEnum.changedValue]).first
		// we have changed them, encoder may pick default values if failing to decode:
		#expect(option?.state == .changedValue)
		#expect(option?.name == .changedValue)
		
		option = try await OptionTable.fetchQuery("WHERE state = \(OptionState.changedValue.rawValue)").first
		#expect(option != nil)
		#expect(option?.state == .changedValue)
		#expect(option?.name == .changedValue)
		
		option = try await OptionTable.fetchQuery("WHERE state & \(OptionState.changedValue.rawValue) > 0").first
		#expect(option != nil)
		#expect(option?.state == .changedValue)
		#expect(option?.name == .changedValue)
	}
	
}
