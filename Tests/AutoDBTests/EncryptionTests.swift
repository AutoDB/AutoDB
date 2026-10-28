//
//  EncryptionTests.swift
//  AutoDB
//
//  Tests for SQLCipher encryption, only built with the SQLCipher trait: swift test --traits SQLCipher
//  Each test opens the same file through several managers (writer, reader, wrong key...) so they make their own instead of using the suite's.

#if SQLCipher
	import Foundation
	import Testing
	
	@testable import AutoDB
	import AutoDBTesting
	
	private let plainSettings = AutoDBSettings.cache(path: "Encrypted.db")
	private let key = EncryptionKey.raw(Data(repeating: 7, count: 32))
	private let otherKey = EncryptionKey.raw(Data(repeating: 9, count: 32))
	
	/// counts the key fetches of the test that sets it, tests run in parallel so a global counter would mix them up
	private enum KeyFetches {
		@TaskLocal static var count: Locked<Int>?
	}
	
	private func encrypted(_ key: EncryptionKey) -> AutoDBSettings {
		plainSettings.encrypted {
			KeyFetches.count?.withLock { $0 += 1 }
			return key
		}
	}
	private let encryptedSettings = encrypted(key)
	
	private protocol NamedItem: Table {
		var name: String { get set }
	}
	
	private struct EncryptedItem: NamedItem {
		static let autoDBSettings = encryptedSettings
		var id: AutoId = 0
		var name = ""
	}
	
	/// the same table and file opened with other keys
	private struct OtherKeyItem: NamedItem {
		static let tableName = "EncryptedItem"
		static let autoDBSettings = encrypted(otherKey)
		var id: AutoId = 0
		var name = ""
	}
	
	private struct PassphraseItem: NamedItem {
		static let tableName = "EncryptedItem"
		static let autoDBSettings = encrypted(.passphrase("correct horse"))
		var id: AutoId = 0
		var name = ""
	}
	
	private struct ShortKeyItem: NamedItem {
		static let tableName = "EncryptedItem"
		static let autoDBSettings = encrypted(.raw(Data(repeating: 1, count: 16)))
		var id: AutoId = 0
		var name = ""
	}
	
	/// the same table before encryption was turned on
	private struct PlainItem: NamedItem {
		static let tableName = "EncryptedItem"
		static let autoDBSettings = plainSettings
		var id: AutoId = 0
		var name = ""
	}
	
	/// a folder of our own, emptied, so several managers can open the same file
	private func freshFolder(_ name: String) -> URL {
		let folder = AutoDBManager.shared.fileURL(for: .cache(path: "AutoDBTests/EncryptionTestsManual/\(name)"))!
		try? FileManager.default.removeItem(at: folder)
		return folder
	}
	
	private func header(_ manager: AutoDBManager) throws -> Data {
		let url = try #require(manager.fileURL(for: encryptedSettings))
		let file = try FileHandle(forReadingFrom: url)
		defer { try? file.close() }
		return try file.read(upToCount: 16) ?? Data()
	}
	
	private let plainHeader = Data("SQLite format 3\0".utf8)
	
	private func save<T: NamedItem>(_ name: String, _ id: AutoId, in manager: AutoDBManager, as type: T.Type = EncryptedItem.self) async throws {
		try await AutoDBManager.withScope(manager) {
			var item = await T.create(id)
			item.name = name
			try await item.save()
			try await T.db().closeNow()
		}
	}
	
	private func names<T: NamedItem>(_ type: T.Type = EncryptedItem.self, in folder: URL) async throws -> [String] {
		try await AutoDBManager.withScope(AutoDBManager(root: folder)) {
			try await T.fetchQuery("ORDER BY id").map(\.name)
		}
	}
	
	private func isWrongKey(_ error: any Error) -> Bool {
		if case Database.Error.wrongEncryptionKey = error {
			return true
		}
		return false
	}
	
	@Suite(.autoDB)
	struct EncryptionTests {
		
		@Test func roundTripIsEncryptedOnDisc() async throws {
			let folder = freshFolder("roundTrip")
			let writer = AutoDBManager(root: folder)
			try await save("secret", 1, in: writer)
			#expect(try header(writer) != plainHeader)
			
			#expect(try await names(in: folder) == ["secret"])
		}
		
		@Test func reopensAfterAutoClose() async throws {
			let calls = Locked(0)
			try await KeyFetches.$count.withValue(calls) {
				try await AutoDBManager.withScope(AutoDBManager(root: freshFolder("autoClose"))) {
					var item = await EncryptedItem.create(1)
					item.name = "first"
					try await item.save()
					let db = try await EncryptedItem.db()
					await db.setAutoClose(after: 0.05)
					try await waitForCondition(delay: 5, "auto-close") { await db.isClosed }
					
					#expect(try await EncryptedItem.fetchId(1).name == "first")
					// the reopen used the kept key, it was only fetched when the database was created
					#expect(calls.withLock { $0 } == 1)
				}
			}
		}
		
		@Test func openAfterCloseNowFetchesTheKeyAgain() async throws {
			let calls = Locked(0)
			try await KeyFetches.$count.withValue(calls) {
				try await AutoDBManager.withScope(AutoDBManager(root: freshFolder("closeNow"))) {
					var item = await EncryptedItem.create(1)
					item.name = "first"
					try await item.save()
					let db = try await EncryptedItem.db()
					await db.closeNow()
					try await db.open()
					#expect(try await EncryptedItem.fetchId(1).name == "first")
					#expect(calls.withLock { $0 } == 2)
				}
			}
		}
		
		@Test func wrongKeyThrows() async throws {
			let folder = freshFolder("wrongKey")
			try await save("secret", 1, in: AutoDBManager(root: folder))
			
			do {
				_ = try await names(OtherKeyItem.self, in: folder)
				Issue.record("opened with the wrong key")
			} catch {
				#expect(isWrongKey(error), "\(error)")
			}
		}
		
		@Test func keyIsNotPartOfEquality() {
			#expect(encrypted(key) == encrypted(otherKey))
			#expect(encrypted(key) != plainSettings)
			#expect(AutoDBSettings.memory.encrypted { key }.isEncrypted == false)
		}
		
		@Test func rawKeysMustBe32Bytes() async throws {
			do {
				_ = try await names(ShortKeyItem.self, in: freshFolder("shortKey"))
				Issue.record("opened with a short raw key")
			} catch Database.Error.invalidEncryptionKey {
			}
		}
		
		@Test func passphrase() async throws {
			let folder = freshFolder("passphrase")
			try await save("secret", 1, in: AutoDBManager(root: folder), as: PassphraseItem.self)
			#expect(try await names(PassphraseItem.self, in: folder) == ["secret"])
		}
		
		@Test func existingUnencryptedFileIsEncryptedInPlace() async throws {
			let folder = freshFolder("migration")
			let plain = AutoDBManager(root: folder)
			try await AutoDBManager.withScope(plain) {
				for (id, name) in [(1, "one"), (2, "two")] {
					var item = await PlainItem.create(AutoId(id))
					item.name = name
					try await item.save()
				}
				let db = try await PlainItem.db()
				// a virtual table must survive the export too
				_ = try await db.execute("CREATE VIRTUAL TABLE notes USING fts5(body)")
				_ = try await db.execute("INSERT INTO notes (body) VALUES ('full text search')")
				await db.closeNow()
			}
			let unencryptedHeader = try header(plain)
			#expect(unencryptedHeader == plainHeader)
			
			let encrypted = AutoDBManager(root: folder)
			#expect(try await names(in: folder) == ["one", "two"])
			try await AutoDBManager.withScope(encrypted) {
				let rows = try await EncryptedItem.db().query("SELECT body FROM notes WHERE notes MATCH 'search'")
				#expect(rows.count == 1)
			}
			#expect(try header(encrypted) != plainHeader)
			let url = try #require(encrypted.fileURL(for: encryptedSettings))
			#expect(FileManager.default.fileExists(atPath: url.path + ".encrypting") == false)
		}
		
		@Test func changeEncryptionKey() async throws {
			let folder = freshFolder("rekey")
			let writer = AutoDBManager(root: folder)
			try await AutoDBManager.withScope(writer) {
				var item = await EncryptedItem.create(1)
				item.name = "secret"
				try await item.save()
				try await writer.changeEncryptionKey(for: encryptedSettings, to: otherKey)
				try await EncryptedItem.db().closeNow()
			}
			
			#expect(try await names(OtherKeyItem.self, in: folder) == ["secret"])
			do {
				_ = try await names(in: folder)
				Issue.record("the old key still works")
			} catch {
				#expect(isWrongKey(error), "\(error)")
			}
		}
	}
#endif
