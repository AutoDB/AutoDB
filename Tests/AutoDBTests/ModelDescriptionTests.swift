//
//  ModelDescriptionTests.swift
//  AutoDB
//

import Testing
@testable import AutoDB

struct ModelDescriptionTests {
	
	@Test func printsValue() {
		let model = TrackedModel(TrackedModel.Value(id: 7, name: "Olof"))
		#expect(model.description == String(describing: model.value))
		#expect("\(model)".contains("Olof"))
	}
	
	@Test func storedModelPrintsValue() {
		let model = StoredPerson(StoredPerson.Value(id: 3, name: "Stored", counter: 2))
		#expect(String(describing: model) == String(describing: model.value))
		#expect("\(model)".contains("Stored"))
	}
}
