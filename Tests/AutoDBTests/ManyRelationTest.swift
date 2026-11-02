//
//  ManyRelationTest.swift
//  AutoDB
//
//  Created by Olof Andersson-Thorén on 2025-12-18.
//

import Testing
@testable import AutoDB
import AutoDBTesting
import Foundation

@Suite(.autoDB, .serialized)
class ManyRelationTest {
	
	@Test
	func testStructsInitFetch() async throws {
		try await AutoDBManager.current.truncateTable(ParentStruct.self)
		try await AutoDBManager.current.truncateTable(Child.self)
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
	
	@Test
	func testPagedFetchStopsAtTotalCount() async throws {
		try await AutoDBManager.current.truncateTable(PagedParentStruct.self)
		try await AutoDBManager.current.truncateTable(Child.self)
		
		let parent = await PagedParentStruct.create(1)
		let names = ["A", "B", "C"]
		var children = [Child]()
		for (index, name) in names.enumerated() {
			var child = await Child.create(AutoId(index + 1))
			child.name = name
			try await child.save()
			children.append(child)
		}
		
		await parent.children.append(children)
		try await parent.save()
		
		let fetched = try await PagedParentStruct.fetchId(1)
		let firstPage = try await fetched.children.firstFetch()
		#expect(firstPage.count == 2)
		#expect(fetched.children.hasMore)
		
		let secondPage = try await fetched.children.fetch()
		#expect(secondPage.count == 3)
		#expect(fetched.children.hasMore == false)
	}
	
	@Test
	func testIdsCanBeSetAndReplacedWithoutFetching() async throws {
		try await AutoDBManager.current.truncateTable(PagedParentStruct.self)
		try await AutoDBManager.current.truncateTable(Child.self)
		
		for (index, name) in ["A", "B", "C"].enumerated() {
			var child = await Child.create(AutoId(index + 1))
			child.name = name
			try await child.save()
		}
		let parent = await PagedParentStruct.create(1)
		await parent.children.set(ids: [1, 2, 1])
		#expect(parent.children.allIds == [1, 2, 1])
		#expect(parent.children.contains(2))
		#expect(parent.children.contains(3) == false)
		
		await parent.children.replace(1, with: 3)
		#expect(parent.children.allIds == [3, 2, 3])
		try await parent.save()
		
		let fetched = try await PagedParentStruct.fetchId(1)
		#expect(fetched.children.allIds == [3, 2, 3])
		let names = try await fetched.children.firstFetch().map(\.name)
		#expect(names == ["C", "B"])
	}
	
	@Test
	func testForgottenIdIsNeitherCachedNorSaved() async throws {
		try await AutoDBManager.current.truncateTable(Parent.Value.self)
		try await AutoDBManager.current.truncateTable(Child.self)
		
		let parent = await Parent.create(10)
		parent.value.name = "Old"
		try await parent.save()
		
		// another id for the same row, the way a sync re-keys it with SQL
		try await Parent.query("UPDATE Parent SET id = 11 WHERE id = 10")
		await AutoDBManager.current.forget([10], Parent.Value.self)
		#expect(await AutoDBManager.current.cached(Parent.self, 10) == nil)
		
		// the stale object must not bring the old row back
		parent.value.name = "Stale"
		try await parent.save()
		let rows = try await Parent.query("SELECT id FROM Parent ORDER BY id")
		#expect(rows.map { $0["id"]?.uint64Value } == [11])
		#expect(try await Parent.fetchId(11).value.name == "Old")
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
	
	@Test func testRelations() async throws {
		try await AutoDBManager.current.truncateTable(Parent.Value.self)
		try await AutoDBManager.current.truncateTable(Child.self)
		
		var item: Parent? = await Parent.create(1)
		try await item?.value.children.fetch()
		
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.prettyPrinted]
		
		if let item, item.value.children.items.isEmpty {
			item.value.name = "Olof"
			
			var gunnar = await Child.create()
			gunnar.name = "Gunnar"
			var bertil = await Child.create()
			bertil.name = "Bertil"
			await item.value.children.append([gunnar, bertil])
			
			// we must save these separately
			try await item.value.children.items.save()
			try await item.save()
		} else {
			#expect(item != nil)
			#expect(item?.value.children.items.isEmpty == false)
			#expect(item?.value.children.items.first?.name == "Gunnar")
			#expect(item?.value.children.items.last?.name == "Bertil")
		}
		item = nil
		await Task.yield()
		
		let children = try await Child.fetchQuery()
		#expect(children.count == 2)
		
		let parent = try await Parent.fetchQuery("WHERE name = ?", ["Olof"]).first!
		#expect(parent.value.children != nil)
		
		let data = try encoder.encode(parent.value.children)
		print(String(data: data, encoding: .utf8)!)
		
		try await waitForCondition {
			parent.value.children.items.count == 2
		}
		
		#expect(parent.value.children.items.first?.name == "Gunnar")
		#expect(parent.value.children.items.last?.name == "Bertil")
		
		#expect(parent.value.children.owner != nil)
	}
}

struct PagedParentStruct: Table {
	var id: UInt64 = 0
	var children = ManyRelation<Child>(initial: 2, limit: 2, initFetch: false)
}

struct ParentStruct: Table {
	var id: UInt64 = 0
	var name = ""
	var children = ManyRelation<Child>(initFetch: false)
	//static let tableName: String = "Parent"
}
