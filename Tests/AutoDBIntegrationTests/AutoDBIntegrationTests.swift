import AutoDB
import Foundation
import Testing

/// The suite's own database file in the cache folder (same layout as TestDatabase in AutoDBTests), deleted the first time a run uses it.
private enum IntegrationDatabase {
	static let settingsKey: SettingsKey = {
		let path = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
			.appendingPathComponent("AutoDBTests/AutoDBIntegrationTests.db")
			.path
		for suffix in ["", "-wal", "-shm"] {
			try? FileManager.default.removeItem(atPath: path + suffix)
		}
		return .specific(AutoDBSettings(path: path, iCloudBackup: false, inAppFolder: false, inCacheFolder: false))
	}()
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

@Suite(.serialized)
struct AutoDBIntegrationTests {
	@Test func testPublicModelRoundTrip() async throws {
		try await SmokeArtist.truncateTable()
		
		let artist = await SmokeArtist.create()
		artist.value.name = "The Cure"
		artist.value.genre = "Post-punk"
		try await artist.save()
		
		let fetched = try await SmokeArtist.fetchId(artist.id)
		#expect(fetched === artist)
		#expect(fetched.value.genre == "Post-punk")
	}
	
	@Test func testPublicOneRelationRoundTrip() async throws {
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
		#expect(relatedArtist.id == artist.id)
		#expect(relatedArtist.value.name == "Siouxsie and the Banshees")
	}
	
	@Test func testPublicFTSSearch() async throws {
		try await SmokeArticle.truncateTable()
		
		let first = await SmokeArticle.create()
		first.value.title = "Disintegration"
		first.value.body = "Dark gothic pop with shimmering guitars"
		
		let second = await SmokeArticle.create()
		second.value.title = "Blue Monday"
		second.value.body = "Dance floor classic"
		
		try await [first, second].save()
		
		let matches = try await first.bodyIndex.search("gothic")
		#expect(matches.map(\.id) == [first.id])
		#expect(matches.first?.body == "Dark gothic pop with shimmering guitars")
	}
}
