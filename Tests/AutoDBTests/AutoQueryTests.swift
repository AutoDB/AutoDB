//
//  AutoQueryClass.swift
//  AutoDB
//
//  Created by Olof Andersson-Thorén on 2024-12-05.
//
import Foundation
@testable import AutoDB
import Testing

final class Album: AutoModel, @unchecked Sendable {
	
	var id: AutoId = 0
	var name = ""
	var artist = ""
}

final class AlbumArt: AutoModel, @unchecked Sendable {
	
	var id: AutoId = 0
	var album = OneRelation<Album>()
}

@available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, *)
final class CureAlbums: AutoModel, @unchecked Sendable {
	var id: AutoId = 0
	var albums = AutoQuery<Album>("WHERE artist = ?",  arguments: ["The Cure"], initial: 1, limit: 20)
}

@available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, *)
final class SaveFail: AutoModel, @unchecked Sendable {
	var id: AutoId = 0
	var albums = AutoQuery<Album>("WHERE artist = ?",  arguments: ["The Cure"], initial: 2, limit: 3)
}

@available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, *)
final class DeallocTest: AutoModel, @unchecked Sendable {
	var id: AutoId = 0
	var albums = AutoQuery<Album>("WHERE artist = ?",  arguments: ["The Cure"], initial: 20000, limit: 3)
	var callback: (() -> Void)?
	deinit {
		callback?()
	}
	
	enum CodingKeys: CodingKey {
		case id
		case albums
	}
}

/*
final class CombineTest: AutoModel, @unchecked Sendable, ObservableObject {
	var id: AutoId = 0
	@Published
	var albums = AutoQuery<Album>("WHERE artist = ?",  arguments: ["The Cure"], initial: 2, limit: 3)
	var listeners = Set<AnyCancellable>()
	var someInt: Int = 1
	
	enum CodingKeys: CodingKey {
		case id
		case albums
		case someInt
	}
	
	convenience init(type: Int) {
		self.init()
		albums.objectWillChange.sink { [self] _ in
			self.objectWillChange.send()
		}.store(in: &listeners)
	}
}
 */

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

import Combine

// experimenting with publishers
class AutoQueryTests2: @unchecked Sendable {
	var gotMessage = false
	
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

class AutoQueryTests {
	
	var listeners = Set<AnyCancellable>()
	var gotMessage = false
	
	/*
	@Test func plainListener() async throws {
		try await AutoDBManager.shared.truncateTable(Album.self)
		try await AutoDBManager.shared.truncateTable(CombineTest.self)
		let item = CombineTest(type: 1)
		item.objectWillChange.sink { [self] _ in
			gotMessage = true
		}.store(in: &listeners)
		
		_ = try await item.albums.fetchItems()
		
		let album = await Album.create()
		album.name = "Wild mood swings"
		album.artist = "The Cure"
		try await album.save()
		
		try await waitForCondition {
			gotMessage
		}
	}
	*/
	
	@Test func deallocAutoQuery() async throws {
		try await AutoDBManager.shared.truncateTable(DeallocTest.self)
		var owner: DeallocTest? = await DeallocTest.create(1)
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
		
		//owner?.albums never deallocs...
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
	func testAutoQueryXTimes() async throws {
		for index in 0..<300 {
			try await testAutoQuery()
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
	
	func testAutoQuery() async throws {
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
		
		let isEmpty = try await CureAlbums.fetchId(1).albums.fetchItems().isEmpty
		#expect(isEmpty)
		for name in ["Seventeen Seconds", "Faith"] {
			let album = await Album.create()
			album.name = name
			album.artist = "The Cure"
			await album.didChange()
		}
		try await Album.saveChanges()
		
		// newly fetched from DB should have items already populated (after a short delay).
		let cure = try await CureAlbums.fetchId(1)
		try await waitForCondition {
			cure.albums.items.isEmpty == false
		}
		try await cure.albums.loadMore()
		count = cure.albums.items.count
		#expect(count == 2, "count is \(count)")
		
		#expect(cure.albums.hasMore == false)
		let album = await Album.create()
		album.name = "Pornography"
		album.artist = "The Cure"
		try await album.save()
		try await waitForCondition(delay: 5) {
			cure.albums.hasMore == true
		}
		
		// There was no problem with save - error was only with callback!
		try await cure.albums.loadMore()
		#expect(cure.albums.hasMore == false && cure.albums.items.count > 2)
	}
}

enum WaitError: Error {
	case timeRanOut
	case reason(String)
}

@available(macOS 14.0, iOS 15.0, *)
public func waitForCondition(delay: Double = 15, _ reason: String? = nil, _ closure: (() async throws -> Bool)) async throws {
	let endDate = Date.now.addingTimeInterval(delay)
	while Date.now < endDate {
		if try await closure() {
			return
		}
		try await Task.sleep(for: .milliseconds(10))
	}
	if try await closure() {
		return
	}
	if let reason = reason {
		throw WaitError.reason(reason)
	}
	throw WaitError.timeRanOut
}
