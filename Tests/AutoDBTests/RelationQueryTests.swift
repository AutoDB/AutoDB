//
//  RelationQueryClass.swift
//  AutoDB
//
//  Created by Olof Andersson-Thorén on 2024-12-05.
//
import Foundation
@testable import AutoDB
import Testing
import Combine

final class Album: Model, @unchecked Sendable {
	
	struct Value: Table {
		
		var id: AutoId = 0
		var name = ""
		var artist = ""
		
		static let tableName = "Album"
	}
	
	var value: Value
	init(_ value: Value) {
		self.value = value
	}
	//shorthand
	var name: String { value.name }
}

final class AlbumArt: Model, @unchecked Sendable {
	
	struct Value: Table {
		
		static let tableName = "AlbumArt"
		var id: AutoId = 0
		var data: Data? = nil
		
		// what album does this belong to?
		var album = OneRelation<Album>()
		
		static var autoDBSettings: SettingsKey {
			.cache
		}
	}
	
	var value: Value
	init(_ value: Value) {
		self.value = value
	}
	//shorthand
	var album: OneRelation<Album> { value.album }
}

@available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, *)
final class DeallocTest: @unchecked Sendable {
	
	init() {
		albums.setOwner(self)
	}
	
	var albums = RelationQuery<Album>("WHERE artist = ?", arguments: ["The Cure"], initial: 20000, limit: 3)
	var callback: (() -> Void)?
	deinit {
		callback?()
	}
}

@available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, *)
final class CureAlbums: Model, @unchecked Sendable {
	struct CureAlbumsTable: Table {
		static let tableName = "CureAlbums"
		
		var id: AutoId = 0
		var albums = RelationQuery<Album>("WHERE artist = ?", arguments: ["The Cure"], initial: 1, limit: 20)
	}
	var value: CureAlbumsTable
	init(_ value: CureAlbumsTable) {
		self.value = value
	}
}

@available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, *)
struct SaveFail: Table {
	var id: AutoId = 0
	var albums = RelationQuery<Album>("WHERE artist = ?", arguments: ["The Cure"], initial: 2, limit: 3)
}

final class CombineAlbum: Model, @unchecked Sendable, ObservableObject {
	
	//var albums = RelationQuery<Album>("WHERE artist = ?",  arguments: ["The Cure"], initial: 2, limit: 3)
	struct CombineAlbumTable: Table {
		
		var id: AutoId = 0
		var name = ""
		var artist = ""
	}
	
	@Published
	var value: CombineAlbumTable
	
	init(_ value: CombineAlbumTable) {
		self.value = value
		
		$value.sink { [self] _ in
			self.objectWillChange.send()
		}.store(in: &listeners)
	}
	var listeners = Set<AnyCancellable>()
}

// auto-call objectWillChange when changed.
final class CombineArtist: @unchecked Sendable, ObservableObject, RelationOwner {
	
	@Published
	var albums = RelationQuery<CombineAlbum.CombineAlbumTable>("WHERE artist = ?", arguments: ["The Cure"], initial: 2, limit: 3)
	
	func didChange() async {
		objectWillChange.send()
	}
}

@available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, *)
final class PagedCureAlbums: Model, @unchecked Sendable {
	struct Value: Table {
		static let tableName = "PagedCureAlbums"
		
		var id: AutoId = 0
		var albums = RelationQuery<Album>("WHERE artist = ?", arguments: ["The Cure"], initial: 2, limit: 2)
	}
	
	var value: Value
	init(_ value: Value) {
		self.value = value
	}
}

class CombineTester: @unchecked Sendable {
	
	var listeners = Set<AnyCancellable>()
	var gotMessage = false
	
	// will models be notified when values change or Relation-changes
	@Test func plainListener() async throws {
		try await AutoDBManager.shared.truncateTable(CombineAlbum.CombineAlbumTable.self)
		let item = await CombineAlbum.create()
		item.objectWillChange.sink { [self] _ in
			gotMessage = true
		}.store(in: &listeners)
		
		item.value.name = "Wild mood swings"
		
		try await waitForCondition {
			gotMessage
		}
		
		listeners.removeAll()
		gotMessage = false
		
		let artist = CombineArtist()
		artist.albums.setOwner(artist)
		try await artist.albums.fetchItems()
		artist.objectWillChange.sink { [self] _ in
			gotMessage = true
		}.store(in: &listeners)
		
		try await item.save()
		try await waitForCondition {
			gotMessage
		}
	}
}

class ListenerHelp: @unchecked Sendable {
	var list: RowChangeObserver
	var gotMessage = false
	var gotIds = [AutoId]()
	var ending = false
	var callback: (@Sendable () -> Void)?
	let name: String
	init(list: RowChangeObserver, _ name: String) {
		self.list = list
		self.name = name
	}
	
	func stop() {
		startTask?.cancel()
	}
	
	var startTask: Task<Void, Error>?
	func start(_ waitForStop: Bool = false) async {
		startTask = Task { [weak self] in
			guard let list = self?.list else { return }
			self?.gotMessage = false
			let name = self?.name ?? "unknown"
			
			for await _ in list {
				if waitForStop {
					print("\(name) got message but waiting for stop")
				} else {
					print("\(name) got message and breaking")
					break
				}
			}
			if self?.list.isCancelled ?? false == false {
				print("\(name) stopping but list is not cancelled!")
			} else {
				print("\(name) stopping since list is cancelled!")
			}
			
			self?.gotMessage = true
		}
		do {
			try await startTask?.value
		} catch {
			print("cancelled: \(error)")
		}
		print("task finished: \(startTask?.isCancelled ?? false)")
	}
	
	deinit {
		callback?()
		print("\(name) dead!")
	}
}

// experimenting with publishers
actor RelationQueryPublisherTests {
	
	var count = 0
	
	func inc() {
		count += 1
	}
	
	@Test
	func exampleOfAsyncObserver() async throws {
		
		let observer = AsyncObserver<Int>()
		Task {
			// this task will never quit - it will "leak" until the observer is cancelled.
			for await num in observer {
				print("none-quitter got: \(num)")
				try await Task.sleep(for: .milliseconds(20))
			}
			print("This will never happen!")
		}
		let task = Task { @Sendable in
			// this task can be cancelled without needing to cancel everyone
			for await num in observer {
				print("cancellable task got: \(num)")
			}
			print("Finished observing: \(Task.isCancelled)")
			self.inc()
		}
		
		// somewhere else we are doing work:
		for index in 0..<10 {
			await observer.appendWait(index)
			try await Task.sleep(for: .milliseconds(10))
		}
		
		// we can stop both by calling: await observer.cancelAll()
		// but usually you only want to stop your own observer,
		// then just cancell the task:
		task.cancel()
		//try await Task.sleep(for: .milliseconds(10))
		
		try await waitForCondition {
			await countIsOne()
		}
	}
	
	func countIsOne() -> Bool {
		self.count == 1
	}
}

@Suite("RelationQueryTests", .serialized)
class RelationQueryTests {
	private func createAlbum(_ name: String, artist: String = "The Cure") async throws {
		let album = await Album.create()
		album.value.name = name
		album.value.artist = artist
		try await album.save()
	}
	
	@available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, *)
	private func createRelationQueryOwner(limit: Int = 20) async throws -> CureAlbums {
		try await AutoDBManager.shared.truncateTable(CureAlbums.CureAlbumsTable.self)
		try await AutoDBManager.shared.truncateTable(Album.Value.self)
		
		let db = try await CureAlbums.db()
		try await CureAlbums.create(1).save()
		
		let count = try await db.query("Select count(*) From CureAlbums").first?.values.first?.intValue ?? 0
		#expect(count == 1)
		
		let cure = try await CureAlbums.fetchId(1)
		cure.value.albums.limit = limit
		return cure
	}
	
	@Test func deallocRelationQuery() async throws {
		//try await AutoDBManager.shared.truncateTable(DeallocTest.self)
		var owner: DeallocTest? = DeallocTest()
		weak let listener = owner?.albums
		nonisolated(unsafe) var didDealloc = false
		owner?.callback = {
			didDealloc = true
		}
		try await Album.create(1991).save()
		owner = nil
		try await waitForCondition {
			didDealloc
		}
		
		print("Is album listener nil?")
		try await waitForCondition {
			return listener == nil
		}
		// what happens when saving a new one?
		try await Album.create(1234).save()
		try await Task.sleep(for: .milliseconds(1000))
		
		#expect(didDealloc)
	}
	
	@Test
	func testRelationQueryXTimes() async throws {
		for index in 0..<500 {
			try await testRelationQuery()
			if index % 100 == 0 {
				print("autoQ completed: \(index)")
			}
		}
	}
	
	@Test
	func testOneRelationMultipleDBs() async throws {
		let mainDB = try await ObserveBasic.db()
		
		let cacheDB = try await AlbumArt.db()
		try await AlbumArt.truncateTable()
		try await Album.truncateTable()
		
		let faith = await Album.create()
		faith.value.name = "Faith"
		try await faith.save()
		
		let id: AutoId = 4
		var art: AlbumArt? = await AlbumArt.create(id)
		//let id = art!.id
		await art?.value.album.setObject(faith)
		try await art?.save()
		print("art: \(art!.value.album.id)")
		art = nil
		await Task.yield()
		
		let artObj = try await AlbumArt.fetchId(id)
		print("artObj: \(artObj.id) \(artObj.value.album.id)")
		
		if try await artObj.album.object != faith {
			throw AutoError.missingRelation
		}
		
		#expect(artObj.value.album._object == faith)
		#expect(mainDB !== cacheDB)
		
		// make sure we have two files with different tables:
		let q = "SELECT name FROM sqlite_master WHERE type='table';"
		let result = try await mainDB.query(q)
		for rows in result {
			#expect(rows.values.contains { $0.stringValue == "AlbumArt" } == false)
		}
		let cacheRes = try await cacheDB.query(q).compactMap({ $0.values.first })
		#expect(cacheRes.contains { $0.stringValue == "AlbumArt" })
	}
	
	@Test
	func catchWhenSaveFails() async throws {
		let db = try await SaveFail.db()
		
		// save sometimes fails, figure out why this happens!
		for i in 1...1000 {
			try await AutoDBManager.shared.truncateTable(SaveFail.self)
			try await SaveFail.create(1).save()
			let count = try await db.query("Select count(*) From SaveFail").first?.values.first?.intValue ?? 0
			if count == 0 {
				print("did fail!")
				try await Task.sleep(for: .milliseconds(1000))
				let count2 = try await db.query("Select count(*) From SaveFail").first?.values.first?.intValue ?? 0
				print("no! \(count) vs \(count2)")
				#expect(count > 0, "Should have saved! second time did work: \(count2)")
			}
			if i % 500 == 0 {
				print("Saved \(i)")
			}
			try await Task.sleep(for: .milliseconds(1))
		}
	}
	
	func testRelationQuery() async throws {
		let cure = try await createRelationQueryOwner()
		let tableName = CureAlbums.CureAlbumsTable.tableName
		#expect("CureAlbums" == tableName)
		
		let firstFetch = try await cure.value.albums.fetchItems()
		#expect(firstFetch.isEmpty)
		#expect(cure.value.albums.hasMore == false)
		
		for name in ["Seventeen Seconds", "Faith"] {
			try await createAlbum(name)
		}
		
		try await waitForCondition {
			cure.value.albums.items.count == 1 && cure.value.albums.hasMore == true
		}
		
		try await cure.value.albums.fetchMore()
		#expect(cure.value.albums.items.count == 2)
		#expect(cure.value.albums.hasMore == false)
		
		try await createAlbum("Pornography")
		try await waitForCondition {
			cure.value.albums.items.count == 2 && cure.value.albums.hasMore == true
		}
		
		try await cure.value.albums.fetchMore()
		#expect(cure.value.albums.items.count == 3)
		#expect(cure.value.albums.hasMore == false)
	}
	
	@Test
	func deleteRefreshesVisibleWindow() async throws {
		try await AutoDBManager.shared.truncateTable(PagedCureAlbums.Value.self)
		try await AutoDBManager.shared.truncateTable(Album.Value.self)
		try await PagedCureAlbums.create(1).save()
		
		let cure = try await PagedCureAlbums.fetchId(1)
		for name in ["Seventeen Seconds", "Faith", "Pornography"] {
			try await createAlbum(name)
		}
		
		let firstPage = try await cure.value.albums.fetchItems()
		#expect(firstPage.count == 2)
		#expect(cure.value.albums.hasMore == true)
		
		let firstVisible = cure.value.albums.items.first
		let deletedName = firstVisible?.name
		try await firstVisible?.delete()
		
		try await waitForCondition {
			let names = Set(cure.value.albums.items.map(\.name))
			guard cure.value.albums.items.count == 2, cure.value.albums.hasMore == false else {
				return false
			}
			guard names.contains("Pornography") else {
				return false
			}
			if let deletedName {
				return names.contains(deletedName) == false
			}
			return true
		}
		
		let names = Set(cure.value.albums.items.map(\.name))
		#expect(names.contains("Pornography"))
		if let deletedName {
			#expect(names.contains(deletedName) == false)
		}
	}
}
