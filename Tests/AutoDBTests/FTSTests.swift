//
//  FTSTests.swift
//  AutoDB
//
//  Created by Olof Andersson-Thorén on 2024-12-12.
//

import Testing
import Foundation

@testable import AutoDB

/*
final class FTS: AutoModelObject, @unchecked Sendable {
	var id: AutoId = 1
	var name = 1
	var text = ""
	var somethingElse = ""
	
	var fts = FTSColumn<FTS>("text")
	var somethingElseFTS = FTSColumn<FTS>("somethingElse")
	//try? await query("SELECT text FROM FTS WHERE id = ?", arguments: [id]).first?.values.first?.stringValue
	
	@discardableResult
	static func create(_ id: AutoId? = nil, _ text: String, _ someThing: String = "") async throws -> Self {
		let item = await create(id)
		item.text = text
		item.somethingElse = someThing
		try await item.save()
		return item
	}
}

class FTSTests {
	
	//@Test
	func basic() async throws {
		try await FTS.create(1, "some long and boring story about the prince and the queen", "Ambition in the back of a black car").save()
		let item = try await FTS.fetchId(1)
		#expect(item.text.contains("some long"))
		
		try await FTS.query("DELETE from FTS where text LIKE '%magical%'")
		
		try await FTS.create(nil, "magical beings oaa they are cool").save()
		let someNew = try await FTS.create(nil, "magical beings")
		try await someNew.save()
		
		let result = try await FTSColumn<FTS>.search("long and boring", column: "text").first
		
		#expect(result?.id == 1)
		#expect(result == item)
		
		//now let's change it
		item.text = "ÖÄÅ"
		try await item.save()
		let other = try await FTS.fetchQuery("WHERE text LIKE '%ÖÄÅ%'").first
		#expect(other?.id == 1)
		
		// wait for change trigger in DB
		try await waitForCondition("should give us one result only - should not match oaa") {
			try await someNew.fts.search("ÖÄÅ").count == 1	//should give us one result - we need to discover changes and re-index! - delete on change!
		}
		try await waitForCondition("should not match öäå") {
			try await someNew.fts.search("oAA").count == 1
		}
		
		//we need a way to separate two indicies from each other even in a static function
		let ambition = try await FTSColumn<FTS>.search("Ambition", column: "somethingElse").first
		#expect(ambition?.somethingElse == "Ambition in the back of a black car")
		//try await Task.sleep(for: .seconds(2))
	}
	
	@Test func search() async throws {
		
	}
	
	@Test
	func testXTimes() async throws {
		for index in 0..<1000 {
			try await basic()
			if index % 100 == 0 {
				print("basic completed: \(index)")
			}
		}
	}
		
}
*/
