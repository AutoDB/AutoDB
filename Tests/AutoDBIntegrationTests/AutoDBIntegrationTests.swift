import AutoDB
import Foundation
import XCTest

private enum IntegrationDatabase {
	static let path = URL(fileURLWithPath: NSTemporaryDirectory())
		.appendingPathComponent("AutoDBIntegrationTests.sqlite")
		.path
    
	static let settings = AutoDBSettings(
		path: path,
		iCloudBackup: false,
		inAppFolder: false,
		inCacheFolder: false
	)
	static let settingsKey = SettingsKey.specific(settings)
}

private final class SmokeArtist: Model, @unchecked Sendable {
	struct Value: Table {
		static let tableName = "SmokeArtist"
		static let autoDBSettings = IntegrationDatabase.settingsKey
		
		var id: AutoId = 0
		var name = ""
		var genre = ""
	}
	
	var value: Value {
		didSet { didSet(oldValue) }
	}
	
	init(_ value: Value) {
		self.value = value
	}
}

private final class SmokeAlbumArt: Model, @unchecked Sendable {
	struct Value: Table {
		static let tableName = "SmokeAlbumArt"
		static let autoDBSettings = IntegrationDatabase.settingsKey
		
		var id: AutoId = 0
		var title = ""
		var artist = OneRelation<SmokeArtist>()
	}
	
	var value: Value {
		didSet { didSet(oldValue) }
	}
	
	init(_ value: Value) {
		self.value = value
	}
}

private final class SmokeArticle: Model, @unchecked Sendable {
	struct Value: Table {
		static let tableName = "SmokeArticle"
		static let autoDBSettings = IntegrationDatabase.settingsKey
		
		var id: AutoId = 0
		var title = ""
		var body = ""
	}
	
	var value: Value {
		didSet { didSet(oldValue) }
	}
	
	var bodyIndex = FTSColumn<Value>("body")
	
	init(_ value: Value) {
		self.value = value
	}
	
}

final class AutoDBIntegrationTests: XCTestCase {
	func testPublicModelRoundTrip() async throws {
		try await SmokeArtist.truncateTable()
		
		let artist = await SmokeArtist.create()
		artist.value.name = "The Cure"
		artist.value.genre = "Post-punk"
		try await artist.save()
		
		let fetched = try await SmokeArtist.fetchId(artist.id)
		XCTAssertTrue(fetched === artist)
		XCTAssertEqual(fetched.value.genre, "Post-punk")
	}
	
	func testPublicOneRelationRoundTrip() async throws {
		try await SmokeArtist.truncateTable()
		try await SmokeAlbumArt.truncateTable()
		
		let artist = await SmokeArtist.create()
		artist.value.name = "Siouxsie and the Banshees"
		try await artist.save()
		
		let art = await SmokeAlbumArt.create()
		art.value.title = "Juju"
		await art.value.artist.setObject(artist)
		try await art.save()
		
		let fetched = try await SmokeAlbumArt.fetchId(art.id)
		let relatedArtist = try await fetched.value.artist.object
		XCTAssertEqual(relatedArtist.id, artist.id)
		XCTAssertEqual(relatedArtist.value.name, "Siouxsie and the Banshees")
	}
	
	func testPublicFTSSearch() async throws {
		try await SmokeArticle.truncateTable()
		
		let first = await SmokeArticle.create()
		first.value.title = "Disintegration"
		first.value.body = "Dark gothic pop with shimmering guitars"
		
		let second = await SmokeArticle.create()
		second.value.title = "Blue Monday"
		second.value.body = "Dance floor classic"
		
		try await [first, second].save()
		
		let matches = try await first.bodyIndex.search("gothic")
		XCTAssertEqual(matches.map(\.id), [first.id])
		XCTAssertEqual(matches.first?.body, "Dark gothic pop with shimmering guitars")
	}
}
