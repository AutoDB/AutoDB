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
	var codingPath: [any CodingKey] = []
	var userInfo: [CodingUserInfoKey : Any] = [:]
	
	var values: [String: SQLValue] = [:]
	var defaultValues: [String: AnyDecodable] = [:]
	let tableInfo: TableInfo
	var usedKeys: [String] = []
	
	init<TableClass: Table>(_ classType: TableClass.Type, _ tableInfo: TableInfo, _ values: [String: SQLValue]? = nil) {
		self.tableInfo = tableInfo
		let base = TableClass.init()
		for (key, path) in base.allKeyPaths {
			// remove underscores from all properties, perhaps we can make this work in the future. - What is this and why are you doing it?
			let key = key.deleteUnderscorePrefix()
			let value = base[keyPath: path] as? AnyDecodable
			defaultValues[key] = value
		}
		if let values {
			self.values = values
		}
	}
	var relations: [AnyRelation] = []
	
	func getRawValue<R: RawRepresentable>(_ type: R.Type, _ key: String) -> Any? {
		if let decodableRaw = type.RawValue.self as? any Decodable.Type {
			guard let rawValue = getValue(decodableRaw, key) as? R.RawValue else {
				return nil
			}
			return R.init(rawValue: rawValue)
		}
		return nil
	}
	
	func getValue<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
		
		if let raw = type as? any RawRepresentable.Type {
			return getRawValue(raw, key) as? T
		}
		
		guard let value = values[key] ?? values[key.trimmingCharacters(in: prefixPropertyChars)] else {
			return nil
		}
		
		switch type {
			case is String.Type:
				return value.stringValue as? T
			case is Double.Type:
				return value.doubleValue as? T
			case is Float.Type:
				return value.doubleValue.flatMap { Float($0) } as? T
			case is Bool.Type:
				return value.boolValue as? T
			case is Int.Type:
				return value.intValue as? T
			case is Int8.Type:
				return value.intValue.flatMap{ Int8(clamping: $0) } as? T
			case is Int16.Type:
				return value.intValue.flatMap{ Int16(clamping: $0) } as? T
			case is Int32.Type:
				return value.intValue.flatMap{ Int32(clamping: $0) } as? T
			case is UInt.Type:
				return value.uintValue as? T
			case is UInt8.Type:
				return value.uint64Value.flatMap{ UInt8(clamping: $0) } as? T
			case is UInt16.Type:
				return value.uint64Value.flatMap{ UInt16(clamping: $0) } as? T
			case is UInt32.Type:
				return value.uint64Value.flatMap{ UInt32(clamping: $0) } as? T
			case is UInt64.Type:
				return value.uint64Value as? T
			case is Int64.Type:
				return value.int64Value as? T
			case is Date.Type:
				if let time = value.doubleValue {
					return Date(timeIntervalSince1970: time) as? T
				}
			default:
				if let data = value.dataValue {
					
					if let value = data as? T {
						return value
					}
					
					let value = try? JSONDecoder().decode(T.self, from: data)
					if let relation = value as? AnyRelation {
						relations.append(relation)
					}
					return value
				}
		}
		return nil
	}
	
	// default values are no longer needed since we take them straight from the DB. Should we keep this as safe-guard?
	func getDefaultValue<T>(_ type: T.Type, _ key: String) -> T? where T : Decodable {
		// not nest shows up as key... why does reflection tell us that?
		if let value = defaultValues[key] ?? defaultValues[key.trimmingCharacters(in: prefixPropertyChars)] {
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
		guard let value = values[key] ?? values[key.trimmingCharacters(in: prefixPropertyChars)],
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
