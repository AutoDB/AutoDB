import AutoDB
import Foundation
import Testing

/// The suite's own database file in the cache folder, deleted the first time a run uses it.
private enum IntegrationDatabase {
	static let settings: AutoDBSettings = {
		let path = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
			.appendingPathComponent("AutoDBTests/AutoDBIntegrationTests.db")
			.path
		for suffix in ["", "-wal", "-shm"] {
			try? FileManager.default.removeItem(atPath: path + suffix)
		}
		return AutoDBSettings(path: path, iCloudBackup: false, inAppFolder: false, inCacheFolder: false)
	}()
}

/// The app-wide recipe: every table in this module lives in the suite's file.
extension Table {
	static var autoDBSettings: AutoDBSettings { IntegrationDatabase.settings }
}

private final class SmokeArtist: Model, @unchecked Sendable {
	struct Value: Table {
		static let tableName = "SmokeArtist"
		
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

/// a group of tables sent elsewhere through a refined protocol, which beats the module-wide extension
private protocol SmokeCacheTable: Table {}
extension SmokeCacheTable {
	static var autoDBSettings: AutoDBSettings { .memory }
}

private struct SmokeCached: SmokeCacheTable {
	var id: AutoId = 0
	var name = ""
}

/// read the way AutoDB does, through the protocol witness
private func settings<T: Table>(_ type: T.Type) -> AutoDBSettings {
	T.autoDBSettings
}

@Suite(.serialized)
struct AutoDBIntegrationTests {
	@Test func testSettingsWitnessRanking() async throws {
		#expect(settings(SmokeArtist.Value.self) == IntegrationDatabase.settings)
		#expect(settings(SmokeCached.self) == .memory)
		
		var cached = await SmokeCached.create()
		cached.name = "kept in memory"
		try await cached.save()
		#expect(try await SmokeCached.fetchId(cached.id).name == "kept in memory")
	}
	
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
