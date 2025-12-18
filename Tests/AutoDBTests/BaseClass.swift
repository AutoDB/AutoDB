//
//  File.swift
//  
//
//  Created by Olof Thorén on 2021-07-02.
//
import Foundation
import AutoDB
import Combine

// They must all implement AutoDB
// They must all not have an init OR an empty required one: required init() {... setup }, you may use convenience inits instead.
final class DataAndDate: Table, @unchecked Sendable {
	var anOptObject: DataAndDate? = nil
	var hasChanges: Bool = false
    
    @Published var compexPub = BaseClass()
    @Published var compexPubOpt: DataAndDate? = nil
    var anOptDate: Date? = nil
    var id: UInt64 = 1
    var dubDub2: Float = 1.0
    var dubDub: Double = 1.0
    @Published var timeStamp: Date = Date()
	@Published var intPub: Int = 1
    @Published var optionalIntArray: [Int]? = [1, 2, 3, 4]
    var dataWith9: Data = Data([9, 9, 9, 9])
    
    var ignoreThis = 1
}

struct BaseClass: Table {
	var id: UInt64 = 0
	var anOptInt: Int? = nil
    
    var arrayWithEncodables = [Int]()
}

final class UniqueString: Model, @unchecked Sendable {
	
	struct Value: Table {
		
		static let tableName: String = "UniqueString"
		var id: AutoId = .generateId()
		var string: String = ""
		static var uniqueIndices: [[String]] {
			[
				["string"]
			]
		}
	}
	var value: Value
	init(_ value: Value) {
		self.value = value
	}
	
	var string: String {
		get {
		value.string
		}
		set {
			value.string = newValue
		}
	}
}

@available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, *)
@Observable final class ObserveBasic: Table, @unchecked Sendable {
	
	var hasChanges: Bool = false
	var id: UInt64 = 0
	var string: String = ""
	var optString: String?
	var hejArray: [String] = ["hej"]
	var hejArrayOpt: [String]? = ["hejOpt"]
	var optStruct: Nested? = Nested(name: "Olof")
	
	static var uniqueIndices: [[String]] {
		[
			["string", "optString"]
		]
	}
	
	// Note that you must include CodingKeys if you are an @Observable object, otherwise we get underscores.
	private enum CodingKeys: String, CodingKey {
		case _id = "id"
		case _string = "string"
		case _optString = "optString"
		case _hejArray = "hejArray"
		case _hejArrayOpt = "hejArrayOpt"
		case _optStruct = "optStruct"
	}
}

struct Nested: Codable, Equatable {
	let name: String?
}

final class Mod: Table, @unchecked Sendable {
	var id: UInt64 = 0
	var string: String? = "some string"
	var bigInt: UInt64 = 0
}

@available(macOS 15.0, *)
final class IntTester: Table, @unchecked Sendable {
	
	var id: UInt64 = .max
	
	var integer: Int? = 0
	var integer32: Int32? = 0
	var integer16: UInt16? = 1
	var integer8: Int8? = 0
	var integeru8: UInt8? = 0
	var time: Date? = nil
	
	static func autoDBSettings() -> AutoDBSettings? {
		AutoDBSettings()
	}
}

@available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, *)
@Observable final class Artist: Model, @unchecked Sendable {
	
	struct Value: Table {
		var id: AutoId = 0	// all ids are of type UInt64, which makes it easy to handle uniqueness.
		var name: String = ""	// we must have default values or nil
		static let tableName: String = "Artist"
	}
	var value: Value
	init(_ value: Value) {
		self.value = value
	}
	
	// note that all @Observables will show warning "Immutable property will not be decoded because ..." as long as there are no CodingKeys.
}

@available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, *)
@Observable
final class CodeWithKeys: Table, @unchecked Sendable {
	
	var id: AutoId = 0
	var name: String = ""
	var nest = Nested(name: "kurt")
	var otherNest = Nested(name: "kurtis")
	
	// if we want to remove @Observeble warning for codable, data is from server or when users may not control the coding keys - or they just want different names in SQL for easier to read queries we must allow any CodingKey.
	private enum CodingKeys: String, CodingKey {
		case _otherNest = "notNestEither"
		case _id = "id"
		case _name = "somethingElse"
		case _nest = "notNest"
		
	}
}

// Building something to handle relations
//@available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, *) @Observable
final class Parent: Model, @unchecked Sendable {
	var value: Value
	struct Value: Table {
		
		var id: UInt64 = 0
		var name = ""
		var children = ManyRelation<Child>()
		static let tableName: String = "Parent"
	}
	
	init(_ value: Value) {
		self.value = value
	}
}

struct Child: Table, @unchecked Sendable {
	var id: UInt64 = 0
	var name = "fox"
	
	static let tableName: String = "Child"
}
