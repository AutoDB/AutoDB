//
//  SQLRowEncoder.swift
//  AutoDB
//
//  Created by Olof Andersson-Thorén on 2024-11-18.
//
//
//             _______
//           _|       |_
//          | |  O O  | |                         AutoDB
//          |_|   ^   |_|
//            \  'U' /                   https://github.com/AutoDB
//       []    |--∞--|    []
//        \   |   o   |   /       Copyright 2025 - ∞ Olof Andersson-Thorén
//         \ /    o    \ /             Released under the MIT License
//          |     o     |
//         /______|______\               The paradise is automatic
//            ||    ||
//            ||    ||
//            ~~    ~~
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in all
//  copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//  SOFTWARE.

import Foundation

class SQLRowDecoder: Decoder {
	enum DecodePlan {
		case textTransform((String) -> Any?)
		case integerTransform((Int64) -> Any?)
		case unsignedIntegerTransform((UInt64) -> Any?)
		case doubleTransform((Double) -> Any?)
		case dataTransform((Data) -> Any?)
		case rawRepresentable
		case jsonBlob
	}

	static let jsonDecoder = JSONDecoder()

	var codingPath: [any CodingKey] = []
	var userInfo: [CodingUserInfoKey : Any] = [:]
	
	var values: [String: SQLValue] = [:]
	var defaultValues: [String: AnyDecodable] = [:]
	let decodePlans: [String: DecodePlan]
	let tableInfo: TableInfo
	var usedKeys: [String] = []
	
	init<TableClass: Table>(_ classType: TableClass.Type, _ tableInfo: TableInfo, _ values: [String: SQLValue]? = nil) {
		self.tableInfo = tableInfo
		var plans: [String: DecodePlan] = [:]
		let base = TableClass.init()
		for (key, path) in base.allKeyPaths {
			// remove underscores from all properties, perhaps we can make this work in the future. - What is this and why are you doing it?
			let key = key.deleteUnderscorePrefix()
			let rawValue = base[keyPath: path]
			let value = rawValue as? AnyDecodable
			defaultValues[key] = value
			let valueType: Any.Type
			if let optional = rawValue as? OptionalProtocol {
				valueType = optional.wrappedType()
			} else {
				valueType = type(of: rawValue)
			}
			if let plan = Self.makeDecodePlan(for: valueType) {
				plans[key] = plan
			}
		}
		self.decodePlans = plans
		if let values {
			self.values = values
		}
	}
	var relations: [AnyRelation] = []
	
	private static func makeDecodePlan(for type: Any.Type) -> DecodePlan? {
		if type is any RawRepresentable.Type {
			return .rawRepresentable
		}
		if let textType = type as? any SQLStorableAsText.Type {
			return .textTransform { textType.from(unifiedRepresentation: $0) }
		}
		if let integerType = type as? any SQLStorableAsInteger.Type {
			return .integerTransform { integerType.from(unifiedRepresentation: $0) }
		}
		if let unsignedIntegerType = type as? any SQLStorableAsUnsignedInteger.Type {
			return .unsignedIntegerTransform { unsignedIntegerType.from(unifiedRepresentation: $0) }
		}
		if let doubleType = type as? any SQLStorableAsDouble.Type {
			return .doubleTransform { doubleType.from(unifiedRepresentation: $0) }
		}
		if let dataType = type as? any SQLStorableAsData.Type {
			return .dataTransform { dataType.from(unifiedRepresentation: $0) }
		}
		if type is any Decodable.Type {
			return .jsonBlob
		}
		return nil
	}
	
	private func normalizedKey(_ key: String) -> String {
		key.deleteUnderscorePrefix()
	}

	func getRawValue<R: RawRepresentable>(_ type: R.Type, from value: SQLValue) -> Any? {
		if let rawType = R.RawValue.self as? any SQLStorableAsText.Type,
		   let text = value.stringValue,
		   let rawValue = rawType.from(unifiedRepresentation: text) as? R.RawValue {
			return R.init(rawValue: rawValue)
		}
		if let rawType = R.RawValue.self as? any SQLStorableAsInteger.Type,
		   let integer = value.int64Value,
		   let rawValue = rawType.from(unifiedRepresentation: integer) as? R.RawValue {
			return R.init(rawValue: rawValue)
		}
		if let rawType = R.RawValue.self as? any SQLStorableAsUnsignedInteger.Type,
		   let integer = value.uint64Value,
		   let rawValue = rawType.from(unifiedRepresentation: integer) as? R.RawValue {
			return R.init(rawValue: rawValue)
		}
		if let rawType = R.RawValue.self as? any SQLStorableAsDouble.Type,
		   let double = value.doubleValue,
		   let rawValue = rawType.from(unifiedRepresentation: double) as? R.RawValue {
			return R.init(rawValue: rawValue)
		}
		if let rawType = R.RawValue.self as? any SQLStorableAsData.Type,
		   let data = value.dataValue,
		   let rawValue = rawType.from(unifiedRepresentation: data) as? R.RawValue {
			return R.init(rawValue: rawValue)
		}
		return nil
	}

	func getValue<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
		let key = normalizedKey(key)
		
		guard let value = values[key] else {
			return nil
		}
		
		switch decodePlans[key] ?? Self.makeDecodePlan(for: T.self) {
			case .textTransform(let transform):
				return value.stringValue.flatMap(transform) as? T
			case .integerTransform(let transform):
				return value.int64Value.flatMap(transform) as? T
			case .unsignedIntegerTransform(let transform):
				return value.uint64Value.flatMap(transform) as? T
			case .doubleTransform(let transform):
				return value.doubleValue.flatMap(transform) as? T
			case .dataTransform(let transform):
				return value.dataValue.flatMap(transform) as? T
			case .rawRepresentable:
				if let raw = type as? any RawRepresentable.Type {
					return getRawValue(raw, from: value) as? T
				}
			case .jsonBlob:
				if let data = value.dataValue {
					if let value = data as? T {
						return value
					}
					let value = try? Self.jsonDecoder.decode(T.self, from: data)
					if let relation = value as? AnyRelation {
						relations.append(relation)
					}
					return value
				}
			case nil:
				break
		}
		return nil
	}
	
	// default values are no longer needed since we take them straight from the DB. Should we keep this as safe-guard?
	func getDefaultValue<T>(_ type: T.Type, _ key: String) -> T? where T : Decodable {
		let key = normalizedKey(key)
		// not nest shows up as key... why does reflection tell us that?
		if let value = defaultValues[key] {
			return value as? T
		}
		
		let guessess: [(key: String, value: AnyDecodable)] = defaultValues.compactMap { tuple in
			//don't count any used keys!
			if usedKeys.contains(where: { tuple.key == $0 }) {
				return nil
			}
			return tuple.value is T ? tuple : nil
		}
		guard let first = guessess.first else {
			return nil
		}
		
		// there is no point in guessing on the name, if we have multiple variables of the same type and none is matching the key: just take the first. If default values are important, make sure the order of CodingKeys are the same as the variables
		usedKeys.append(first.key)
		return first.value as? T
	}
	
	func hasValue(_ key: String) -> Bool {
		guard let value = values[normalizedKey(key)],
			  value != .null
		else {
			return false
		}
		return true
	}
	
	func container<Key>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> where Key : CodingKey {
		usedKeys.removeAll()
		relations.removeAll()
		return KeyedDecodingContainer(Container(self))
	}
	
	func unkeyedContainer() throws -> any UnkeyedDecodingContainer {
		fatalError()
	}
	
	func singleValueContainer() throws -> any SingleValueDecodingContainer {
		fatalError()
	}
	
	class Container<KeyType: CodingKey>: KeyedDecodingContainerProtocol {
		var allKeys: [KeyType] = []
		
		func contains(_ key: KeyType) -> Bool {
			true
		}
		
		func decodeNil(forKey key: KeyType) throws -> Bool {
			dec.hasValue(key.stringValue) == false
		}
		
		func nestedContainer<NestedKey>(keyedBy type: NestedKey.Type, forKey key: KeyType) throws -> KeyedDecodingContainer<NestedKey> where NestedKey : CodingKey {
			fatalError()
		}
		
		func nestedUnkeyedContainer(forKey key: KeyType) throws -> any UnkeyedDecodingContainer {
			fatalError()
		}
		
		func superDecoder(forKey key: KeyType) throws -> any Decoder {
			fatalError()
		}
		
		typealias Key = KeyType
		var codingPath: [any CodingKey] = []
		func superDecoder() throws -> any Decoder { fatalError() }
		var dec: SQLRowDecoder
		
		init(_ dec: SQLRowDecoder) {
			self.dec = dec
		}
		
		func decode(_ type: String.Type, forKey key: KeyType) throws -> String {
			if let item = dec.getValue(type, key.stringValue) {
				return item
			} else if let value = dec.getDefaultValue(type, key.stringValue) {
				return value
			}
			// couldn't guess on default value, but we know it's a string so just return that
			return ""
		}
		
		func decode<T>(_ type: T.Type, forKey key: KeyType) throws -> T where T : Decodable {
			if let item = dec.getValue(type, key.stringValue) {
				return item
			} else if let value = dec.getDefaultValue(type, key.stringValue) {
				return value
			}
			// couldn't guess on default value, and if struct or other complex type we can't create one
			throw DecodedError.cannotGuessVariable(key.stringValue)
		}
		
		func decodeIfPresent<T>(_ type: T.Type, forKey key: KeyType) throws -> T? where T : Decodable {
			if let item = dec.getValue(type, key.stringValue) {
				return item
			} else {
				return nil
			}
		}
		
		func decodeIfPresent(_ type: String.Type, forKey key: KeyType) throws -> String? {
			if let item = dec.getValue(type, key.stringValue) {
				return item
			} else {
				return nil
			}
		}
	}
}

enum DecodedError: Error {
	case cannotGuessVariable(String)
}
