//
//  MigrationTests.swift
//  AutoDB
//
//  Created by Olof Andersson-Thorén on 2024-12-10.
//

import Testing
import Foundation

@testable import AutoDB

struct Mig: Table {
	var id: AutoId = 1
	var name = 1
	var plain = "plain"

	static var uniqueIndices: [[String]] { [["name"]] }
	static var indices: [[String]] { [["plain"]] }
}

class MigrationTests {

	@Test func changeIndex() async throws {
		//let db = try await ObserveBasic.setupDB(); try await AutoDBManager.shared.dropTable(Mig.self)
		_ = try await Mig.db()
		// let query = "PRAGMA table_info('Mig')"
		//try await db.query("insert into Mig (id, name3) values (2, 'hej')")
	}

	@Test
	func FTSTableStringMapping() async throws {
		
		// when searching in dbs you want to remove diacretics so that "greve" matches "grevé". But you don't want to remove umlauts that defines completely different vowels - which can be hard to know if you are not familiar with the northern languages. Searching for "Öl" should never give hits on a word like "Olympiade" - there is no link between these words. Basically searching for "Bee" and getting hits on "Boo" - replacing a vowel seemingly at random.
		// Insead we normalize and replace all unicode strings into a decent normal mapping of regular letters kept but diacritics stripped.
		let regular = Set("äöåÖÄÅüÜ".precomposedStringWithCanonicalMapping)
		let out = "ëêéöäåøØæÆ".precomposedStringWithCanonicalMapping.map { regular.contains($0) ? $0 : String($0).folding(options: .diacriticInsensitive, locale: nil).first! }
		print(out)
		#expect(String(out) == "eeeöäåøØæÆ")
		
	}
}

