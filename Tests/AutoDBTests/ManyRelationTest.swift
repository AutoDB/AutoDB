//
//  ManyRelationTest.swift
//  AutoDB
//
//  Created by Olof Andersson-Thorén on 2025-12-18.
//

import Testing
@testable import AutoDB
import Foundation

class ManyRelationTest {
	
	@Test
	func testStructsInitFetch() async throws {
		try await AutoDBManager.shared.truncateTable(ParentStruct.self)
		try await AutoDBManager.shared.truncateTable(Child.self)
		try await createData()
		
		await Task.yield()
		
		let children = try await Child.fetchQuery()
		#expect(children.count == 2)
		
		let parent = try await ParentStruct.fetchQuery("WHERE name = ?", ["Olof"]).first!
		
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.prettyPrinted]
		let data = try encoder.encode(parent.children)
		print(String(data: data, encoding: .utf8)!)
		#expect(parent.children.items.isEmpty == true)
		
		try await parent.children.fetch()
		
		#expect(parent.children.items.first?.name == "Gunnar")
		#expect(parent.children.items.last?.name == "Bertil")
		
		// parent must be a Model for owner to be set automatically.
		//#expect(parent.children.owner != nil)
	}
	
	func createData() async throws {
		var item: ParentStruct = await ParentStruct.create(1)
		try await item.children.fetch()
		
		if item.children.items.isEmpty {
			item.name = "Olof"
			
			var gunnar = await Child.create()
			gunnar.name = "Gunnar"
			var bertil = await Child.create()
			bertil.name = "Bertil"
			await item.children.append([gunnar, bertil])
			
			// we must save these separately
			try await item.children.items.save()
			try await item.save()
		}
	}
}

struct ParentStruct: Table {
	var id: UInt64 = 0
	var name = ""
	var children = ManyRelation<Child>(initFetch: false)
	//static let tableName: String = "Parent"
}
