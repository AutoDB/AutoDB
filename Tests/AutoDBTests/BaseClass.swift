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
final class DataAndDate: Model, @unchecked Sendable {
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

struct BaseClass: Model {
	var id: UInt64 = 0
	var anOptInt: Int? = nil
    
    var arrayWithEncodables = [Int]()
	
}

@available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, *)
@Observable final class ObserveBasic: Model, @unchecked Sendable {
	
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

final class Mod: Model, @unchecked Sendable {
	var id: UInt64 = 0
	var string: String? = "some string"
	var bigInt: UInt64 = 0
}

@available(macOS 15.0, *)
final class IntTester: Model, @unchecked Sendable {
	
	var id: UInt64 = .max
	
	var integer: Int? = 0
	var integer32: Int32? = 0
	var integer16: UInt16? = 1
	var integer8: Int8? = 0
	var integeru8: UInt8? = 0
	var time: Date? = nil
	
	static func autoDBSettings() -> AutoDBSettings? {
		AutoDBSettings(shareDB: false)
	}
}

@available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, *)
@Observable final class Artist: ModelObject, @unchecked Sendable {
	
	struct Value: Model {
		var id: AutoId = 0	// all ids are of type UInt64, which makes it easy to handle uniqueness.
		var name: String = ""	// we must have default values or nil
	}
	var value: Value
	init(_ value: Value) {
		self.value = value
	}
	
	// note that all @Observables will show warning "Immutable property will not be decoded because ..." as long as there are no CodingKeys.
}

@available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, *)
@Observable
final class CodeWithKeys: Model, @unchecked Sendable {
	
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
@available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, *)
//@Observable
final class Parent: ModelObject, @unchecked Sendable {
	var value: Value
	struct Value: Model {
		
		var id: UInt64 = 0
		var name = ""
		var children = AutoRelation<Child>()
	}
	init(_ value: Value) {
		self.value = value
	}
}

struct Child: Model, @unchecked Sendable {
	var id: UInt64 = 0
	var name = "fox"
}

/*
/// A query that fetches incrementally. Specify how many objects to fetch like this:
/// var lords = AutoQuery<Album>("WHERE title = ?",  arguments: ["sir"], initial: 1, limit: 20)
///  NOTE: Query cannot have limit or offset clauses!
///  Avoid using propertyWrappers if you can - they are not compatible with @Observable
struct AutoQuery<AutoType: AutoDB> {
	
	let query: String	// must not contain limit or offset!
	var arguments: [Any]?
	var _items: [AutoType]
	var hasMore = true
	let initialFetch: Int
	var limit: Int
	var offset = -1
	/// When using in a list we want to artificially limit the amount sent back to us.
	var restrictToInitial = false
	
	public init(_ query: String, arguments: [Any]? = nil, initial: Int? = nil, limit: Int? = nil) {
		self.query = query + " LIMIT %i OFFSET %i"
		self.arguments = arguments
		_items = []
		initialFetch = initial ?? 5
		self.limit = limit ?? 100
	}
	
	mutating func items() -> [AutoType] {
		if offset == -1 {
			// setup first fetch
			let res = AutoType.fetchQuery(String(format: query, initialFetch, 0), arguments: arguments)?.rows as? [AutoType] ?? []
			offset = res.count
			hasMore = offset == initialFetch
			_items = res
		}
		if restrictToInitial {
			return _items[0..<min(_items.count, initialFetch)].array()
		}
		return _items
	}
	
	mutating func loadMore() {
		if !hasMore {
			return
		}
		let res = AutoType.fetchQuery(String(format: query, arguments: [limit, offset]), arguments: arguments)?.rows as? [AutoType] ?? []
		offset += res.count
		hasMore = res.count == limit
		_items.append(contentsOf: res)
	}
}
 */
