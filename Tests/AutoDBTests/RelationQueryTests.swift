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

struct Album: Table {
	
	var id: AutoId = 0
	var name = ""
	var artist = ""
}

final class AlbumArt: Model, @unchecked Sendable {
	
	struct AlbumArtValue: Table {
		
		var id: AutoId = 0
		var name = ""
		var artist = ""
		
		// in here to save to DB!
		var album = OneRelation<Album>()
	}
	
	var value: AlbumArtValue
	init(_ value: AlbumArtValue) {
		self.value = value
	}
}

@available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, *)
final class DeallocTest: @unchecked Sendable {
	
	init() {
		albums.setOwner(self)
	}
	
	var albums = RelationQuery<Album>("WHERE artist = ?",  arguments: ["The Cure"], initial: 20000, limit: 3)
	var callback: (() -> Void)?
	deinit {
		callback?()
	}
}



@available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, *)
final class CureAlbums: Model, @unchecked Sendable {
	struct CureAlbumsTable: Table {
		var id: AutoId = 0
		var albums = RelationQuery<Album>("WHERE artist = ?",  arguments: ["The Cure"], initial: 1, limit: 20)
	}
	var value: CureAlbumsTable
	init(_ value: CureAlbumsTable) {
		self.value = value
	}
}

@available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, *)
struct SaveFail: Table {
	var id: AutoId = 0
	var albums = RelationQuery<Album>("WHERE artist = ?",  arguments: ["The Cure"], initial: 2, limit: 3)
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
	var albums = RelationQuery<CombineAlbum.CombineAlbumTable>("WHERE artist = ?",  arguments: ["The Cure"], initial: 2, limit: 3)
	
	func didChange() async {
		objectWillChange.send()
	}
}

class CombineTester {
	
	var listeners = Set<AnyCancellable>()
	var gotMessage = false
	
	// will models be notified when values change or Relation-changes
	@Test func plainListener() async throws {
		try await AutoDBManager.shared.truncateTable(CombineAlbum.self)
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
	var list: ChangeObserver
	var gotMessage = false
	var gotIds = [AutoId]()
	var ending = false
	var callback: (@Sendable () -> Void)?
	let name: String
	init(list: ChangeObserver, _ name: String) {
		self.list = list
		self.name = name
	}
	
	func stop() {
		startTask?.cancel()
		list.cancel()
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
class RelationQueryPublisherTests: @unchecked Sendable {
	
	func exampleOfAsyncObserver() async throws {
		let observer = AsyncObserver<Int>()
		Task {
			// this task will never quit - it will "leak" until the observer is cancelled.
			for await num in observer {
				print("none-quitter got: \(num)")
			}
			print("This will never happen!")
		}
		let task = Task {
			// this task can be cancelled without needing to cancel everyone
			for await num in observer {
				print("num was: \(num)")
			}
			print("Finished observing")
		}
		
		// somewhere else we are doing work:
		for index in 0..<10 {
			await observer.append(index)
			try await Task.sleep(for: .milliseconds(10))
		}
		
		// we can stop both by calling: await observer.cancelAll()
		// but usually you only want to stop your own observer,
		// then the task must be cancelled first and the observer get the cancel message after:
		task.cancel()
		await observer.cancel()
		try await Task.sleep(for: .milliseconds(10000))
	}
}

class RelationQueryTests {
	
	@Test func deallocRelationQuery() async throws {
		//try await AutoDBManager.shared.truncateTable(DeallocTest.self)
		var owner: DeallocTest? = DeallocTest()
		weak var listener = owner?.albums
		var didDealloc = false
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
		for index in 0..<300 {
			try await testRelationQuery()
			if index % 100 == 0 {
				print("autoQ completed: \(index)")
			}
		}
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
		try await AutoDBManager.shared.truncateTable(CureAlbums.self)
		try await AutoDBManager.shared.truncateTable(Album.self)
		//try await Album.db().setDebug()
		let db = try await CureAlbums.db()
		
		try await CureAlbums.create(1).save()
		var count = try await db.query("Select count(*) From CureAlbums").first?.values.first?.intValue ?? 0
		if count == 0 {

			try await Task.sleep(for: .milliseconds(100))
			count = try await db.query("Select count(*) From CureAlbums").first?.values.first?.intValue ?? 0
			print("no! \(count)")
		}
		
		let isEmpty = try await CureAlbums.fetchId(1).value.albums.fetchItems().isEmpty
		#expect(isEmpty)
		for name in ["Seventeen Seconds", "Faith"] {
			var album = await Album.create()
			album.name = name
			album.artist = "The Cure"
			try await album.save()
		}
		
		// newly fetched from DB should have items already populated (after a short delay).
		let cure = try await CureAlbums.fetchId(1)
		try await waitForCondition {
			cure.value.albums.items.isEmpty == false
		}
		try await cure.value.albums.fetchMore()
		count = cure.value.albums.items.count
		#expect(count == 2, "count is \(count)")
		
		#expect(cure.value.albums.hasMore == false)
		var album = await Album.create()
		album.name = "Pornography"
		album.artist = "The Cure"
		try await album.save()
		try await waitForCondition(delay: 5) {
			cure.value.albums.hasMore == true
		}
		
		// There was no problem with save - error was only with callback!
		try await cure.value.albums.fetchMore()
		#expect(cure.value.albums.hasMore == false && cure.value.albums.items.count > 2)
	}
}

