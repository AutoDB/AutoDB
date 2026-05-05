//
//  FTSTests.swift
//  AutoDB
//
//  Created by Olof Andersson-Thorén on 2024-12-12.
//

import Testing
import Foundation

@testable import AutoDB

struct FTS: Table {
	var id: AutoId = 1
	var name = 1
	var text = ""
	var somethingElse = ""
	
	var fts = FTSColumn<FTS>("text")
	var somethingElseFTS = FTSColumn<FTS>("somethingElse")
	//try? await query("SELECT text FROM FTS WHERE id = ?", arguments: [id]).first?.values.first?.stringValue
	
	@discardableResult
	static func create(_ id: AutoId? = nil, _ text: String, _ someThing: String = "") async throws -> Self {
		var item = await create(id)
		item.text = text
		item.somethingElse = someThing
		try await item.save()
		return item
	}
}

final class Post: Model, @unchecked Sendable, FTSCallbackOwner {
	struct PostTable: Table {
		var id: AutoId = 1
		var title: String = "Untitled"
		var body: String = "Once upon a time..."
		var createdAt: Date = Date()
	}
	
	var value: PostTable
	init(_ value: PostTable) {
		self.value = value
	}
	
	// probably smarter to put index in the owner, both should work
	var ownerIndex = FTSColumn<PostTable>("Index")
	static func textCallback(_ ids: [AutoId]) async -> [AutoId: String] {
		var result: [AutoId: String] = [:]
		let list = (try? await PostTable.fetchIds(ids)) ?? []
		for item in list {
			result[item.id] = item.title + " " + item.body
		}
		return result
	}
}

@Suite(.serialized)
class FTSTests {
	
	private func resetFTS() async throws {
		try await FTS.truncateTable()
	}

	@discardableResult
	private func seedFTSData() async throws -> (primary: FTS, magical: FTS, secondary: FTS) {
		try await resetFTS()
		let primary = try await FTS.create(1, "some long and boring story about the prince and the queen", "Ambition in the back of a black car")
		let magical = try await FTS.create(2, "magical beings oaa they are cool")
		let secondary = try await FTS.create(3, "magical beings")
		return (primary, magical, secondary)
	}
	
	@Test func search() async throws {
		let seeded = try await seedFTSData()

		let result = try await FTSColumn<FTS>.search("long and boring", column: "text").first
		#expect(result?.id == seeded.primary.id)
		#expect(result == seeded.primary)

		let ambition = try await FTSColumn<FTS>.search("Ambition", column: "somethingElse").first
		#expect(ambition?.id == seeded.primary.id)
		#expect(ambition?.somethingElse == "Ambition in the back of a black car")
	}

	@Test
	func reindexesAfterUpdateAndDelete() async throws {
		let seeded = try await seedFTSData()
		var updated = try await FTS.fetchId(seeded.primary.id)
		updated.text = "ÖÄÅ"
		try await updated.save()
		let updatedID = updated.id

		try await waitForCondition("updated text should be searchable and old text removed from the FTS index") {
			let updatedMatches = try await FTSColumn<FTS>.search("ÖÄÅ", column: "text")
			let oldMatches = try await FTSColumn<FTS>.search("long and boring", column: "text")
			return updatedMatches.count == 1 && updatedMatches.first?.id == updatedID && oldMatches.isEmpty
		}

		try await waitForCondition("diacritic folding should not collapse Nordic vowels into unrelated words") {
			try await FTSColumn<FTS>.search("oAA", column: "text").count == 1
		}

		try await seeded.magical.delete()
		try await seeded.secondary.delete()
		try await waitForCondition("deleted rows should disappear from the FTS index") {
			try await FTSColumn<FTS>.search("magical", column: "text").isEmpty
		}
	}
	
	@Test
	func testXTimes() async throws {
		for index in 0..<1000 {
			let seeded = try await seedFTSData()
			let result = try await FTSColumn<FTS>.search("long and boring", column: "text").first
			#expect(result?.id == seeded.primary.id)
			if index % 100 == 0 {
				print("fts completed: \(index)")
			}
		}
	}
	
	@Test func modelHandling() async throws {
		try await Post.truncateTable()
		var post: Post? = await Post.create()
		let title = "Little red riding hood"
		post?.value.title = title
		try await post?.save()
		post = nil
		
		let table = try await Post.PostTable.fetchQuery("WHERE title = ?", [title]).first
		#expect(table != nil)
		await Task.yield()
		
		post = try await Post.fetchQuery("WHERE title = ?", [title]).first
		#expect(post != nil)
		
		#expect(post?.ownerIndex != nil)
		#expect(post?.ownerIndex.owner != nil)
		
		//TODO: THINK: should we return the owner or the table? We should return the owner (Model) if exists!
		let fetchedPost = try await post?.ownerIndex.search("once").first
		#expect(fetchedPost?.title == title)
		let cached: Post? = await AutoDBManager.shared.modelForTable(fetchedPost)
		#expect(cached === post)
	}
		
}
