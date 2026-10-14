//
//  DelayConfigTests.swift
//  AutoDB
//
//  Tests for the configurable debounce delays: saveChangesLater and deleteLater.
//

import Testing
import Foundation

@testable import AutoDB

final class DelayModel: Model, @unchecked Sendable {
	struct Value: Table {
		static let autoDBSettings = TestDatabase.delayConfig
		static let tableName = "DelayModel"
		
		var id: AutoId = 0
		var name: String = ""
	}
	
	var value: Value {
		didSet {
			didSet(oldValue)
		}
	}
	
	init(_ value: Value) {
		self.value = value
	}
	
	var name: String {
		get { value.name }
		set { value.name = newValue }
	}
}

// serialized since the delays are global state on AutoDBManager
@Suite(.serialized) class DelayConfigTests: @unchecked Sendable {
	
	@Test func saveLaterHonorsConfiguredDelay() async throws {
		await AutoDBManager.shared.setSaveLaterDelay(0.2)
		defer { Task { await AutoDBManager.shared.setSaveLaterDelay(AutoDBManager.defaultWaitTime) } }
		
		let id = AutoId.generateId()
		let object = await DelayModel.create(id)
		object.name = "savedLater"
		DelayModel.saveChangesLater()
		
		// must hit the DB well before the 3 second default would
		try await waitForCondition(delay: 1.5, "saveChangesLater should save after the configured 0.2 seconds") {
			let rows = try await DelayModel.db().query("SELECT name FROM DelayModel WHERE id = ?", [id])
			return rows.first?["name"]?.stringValue == "savedLater"
		}
	}
	
	@Test func deleteLaterHonorsConfiguredDelay() async throws {
		await AutoDBManager.shared.setDeleteLaterDelay(0.2)
		defer { Task { await AutoDBManager.shared.setDeleteLaterDelay(AutoDBManager.defaultWaitTime) } }
		
		let id = AutoId.generateId()
		let object = await DelayModel.create(id)
		object.name = "deleteMe"
		try await object.save()
		
		await DelayModel.deleteIdsLater([id])
		
		// must be gone well before the 3 second default would delete it
		try await waitForCondition(delay: 1.5, "deleteLater should delete after the configured 0.2 seconds") {
			let rows = try await DelayModel.db().query("SELECT id FROM DelayModel WHERE id = ?", [id])
			return rows.isEmpty
		}
	}
}
