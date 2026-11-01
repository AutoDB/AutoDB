//
//  SQLQueryTests.swift
//  AutoDB
//

import Testing
@testable import AutoDB
import AutoDBTesting
import Foundation

struct SQLQueryItem: Table {
	var id: AutoId = 0
	var name = ""
	var nickname: String? = nil
}

@Suite(.autoDB, .serialized)
struct SQLQueryTests {
	
	@Test
	func interpolationBindsArguments() {
		let name = "Olof"
		let query: SQLQuery = "FROM \(verbatim: "T") WHERE name = \(name) AND n = \(5)"
		#expect(query.query == "FROM T WHERE name = ? AND n = ?")
		#expect(query.arguments.count == 2)
		#expect(query.arguments.first as? String == "Olof")
	}
	
	@Test
	func fetchTableWithInterpolation() async throws {
		try await AutoDBManager.current.truncateTable(SQLQueryItem.self)
		try await SQLQueryItem(id: 1, name: "O'Brien", nickname: "OB").save()
		try await SQLQueryItem(id: 2, name: "Other").save()
		
		let name = "O'Brien"
		let items = try await SQLQueryItem.fetchQuery("WHERE name = \(name)")
		#expect(items.map(\.id) == [1])
		
		// if the literal resolved to the String overload this would match all rows
		let injection = "x' OR '1'='1"
		let none = try await SQLQueryItem.fetchQuery("WHERE name = \(injection)")
		#expect(none.isEmpty)
		
		let rows = try await SQLQueryItem.query("SELECT name FROM \(verbatim: SQLQueryItem.tableName) WHERE name = \(name)")
		#expect(rows.first?["name"]?.stringValue == name)
		
		let nickname: String? = nil
		let withoutNickname = try await SQLQueryItem.fetchQuery("WHERE nickname IS \(nickname)")
		#expect(withoutNickname.map(\.id) == [2])
		
		let count: Int = try await SQLQueryItem.valueQuery("SELECT COUNT(*) FROM \(verbatim: SQLQueryItem.tableName) WHERE id > \(0)")
		#expect(count == 2)
		
		let changed = try await SQLQueryItem.executeAffectedRows("UPDATE \(verbatim: SQLQueryItem.tableName) SET nickname = \("New") WHERE id = \(2)")
		#expect(changed == 1)
	}
	
	@Test
	func fetchModelWithInterpolation() async throws {
		try await AutoDBManager.current.truncateTable(Parent.Value.self)
		try await Parent.Value(id: 1, name: "Olof").save()
		
		let name = "Olof"
		let parents = try await Parent.fetchQuery("WHERE name = \(name)")
		#expect(parents.map(\.id) == [1])
		
		let parentName: String = try await Parent.valueQuery("SELECT name FROM \(verbatim: Parent.Value.tableName) WHERE id = \(1)")
		#expect(parentName == name)
	}
}
