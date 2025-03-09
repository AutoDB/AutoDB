//
//  SQLColumns.swift
//  AutoDB
//
// Copied from Blackbird, some bugfixes and changes but mostly 100% copied.

//
//           /\
//          |  |                       Blackbird
//          |  |
//         .|  |.       https://github.com/marcoarment/Blackbird
//         $    $
//        /$    $\          Copyright 2022–2023 Marco Arment
//       / $|  |$ \          Released under the MIT License
//      .__$|  |$__.
//           \/
//
//  Blackbird.swift
//  Created by Marco Arment on 11/6/22.
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
//

import Foundation
#if canImport(Darwin)
import SQLite3
#else
import SQLCipher
#endif

typealias EncodableSendable = Encodable & Sendable

// Convert Pragma table statemnts into columns
internal struct Column: Equatable, Hashable, Sendable {
	enum Error: Swift.Error {
		case cannotParseColumnDefinition(table: String, description: String)
	}
	
	// intentionally ignoring primaryKeyIndex since it's only used for internal sorting
	public static func == (lhs: Self, rhs: Self) -> Bool {
		lhs.name == rhs.name && lhs.columnType == rhs.columnType && lhs.mayBeNull == rhs.mayBeNull
	}
	
	public func hash(into hasher: inout Hasher) {
		hasher.combine(name)
		hasher.combine(columnType)
		hasher.combine(mayBeNull)
		// Should we care about the default value? No, they are always created by AutoDB - you can't store an object lacking their default values.
	}
	
	internal let name: String
	internal let columnType: ColumnType
	internal let valueType: Any.Type?
	internal let mayBeNull: Bool
	// data is created like this: "X'\(data.map { String(format: "%02hhX", $0) }.joined())'"
	internal let defaultValueString: String?
	
	internal let primaryKeyIndex: Int // Only used for sorting, not considered for equality
	
	internal func definition() -> String {
		let defValue = mayBeNull ? SQLValue.null.sqliteLiteral() : defaultValueString ?? SQLValue.null.sqliteLiteral()
		let str = "`\(name)` \(columnType.definition()) \(mayBeNull ? "NULL" : "NOT NULL") DEFAULT \(defValue)"
		return str
	}
	
	public init(name: String, columnType: ColumnType, valueType: Any.Type, mayBeNull: Bool = false, defaultValue: EncodableSendable?) {
		self.name = name.deleteUnderscorePrefix()
		self.columnType = columnType
		self.valueType = valueType
		self.mayBeNull = mayBeNull
		self.primaryKeyIndex = 0
		self.defaultValueString = defaultValue.flatMap { try? SQLValue.fromAny($0).ignoreDefault() }
	}
	
	internal init(row: Row, tableName: String) throws {
		guard
			let name = row["name"]?.stringValue,
			let typeStr = row["type"]?.stringValue,
			let notNull = row["notnull"]?.boolValue,
			let primaryKeyIndex = row["pk"]?.intValue
		else {
			throw Error.cannotParseColumnDefinition(table: tableName, description: "Unexpected format from PRAGMA table_info")
		}
		
		self.name = name
		self.columnType = ColumnType.parseType(typeStr)
		self.valueType = nil
		self.mayBeNull = !notNull
		self.primaryKeyIndex = primaryKeyIndex
		defaultValueString = row["dflt_value"]?.stringValue
	}
}

/// A wrapped data type supported by ``SQLColumn``.
public protocol SQLColumnWrappable: Hashable, Codable, Sendable {
	static func fromValue(_ value: SQLValue) -> Self?
}

// MARK: - Column storage-type protocols

/// Internally represents data types compatible with SQLite's `INTEGER` type.
///
/// `UInt` and `UInt64` are of course included since SQLite is a dynamic system - Int64 and UInt64 has the same size.
public protocol SQLStorableAsInteger: Codable {
	func unifiedRepresentation() -> Int64
	static func from(unifiedRepresentation: Int64) -> Self
}

public protocol SQLStorableAsUnsignedInteger: Codable {
	func unifiedRepresentation() -> UInt64
	static func from(unifiedRepresentation: UInt64) -> Self
}

/// Internally represents data types compatible with SQLite's `DOUBLE` type.
public protocol SQLStorableAsDouble: Codable {
	func unifiedRepresentation() -> Double
	static func from(unifiedRepresentation: Double) -> Self
}

/// Internally represents data types compatible with SQLite's `TEXT` type.
public protocol SQLStorableAsText: Codable {
	func unifiedRepresentation() -> String
	static func from(unifiedRepresentation: String) -> Self
}

/// Internally represents data types compatible with SQLite's `BLOB` type.
public protocol SQLStorableAsData: Codable {
	func unifiedRepresentation() -> Data
	static func from(unifiedRepresentation: Data) -> Self
}

extension Double: SQLColumnWrappable, SQLStorableAsDouble {
	public func unifiedRepresentation() -> Double { self }
	public static func from(unifiedRepresentation: Double) -> Self { unifiedRepresentation }
	public static func fromValue(_ value: SQLValue) -> Self? { value.doubleValue }
}

extension Float: SQLColumnWrappable, SQLStorableAsDouble {
	public func unifiedRepresentation() -> Double { Double(self) }
	public static func from(unifiedRepresentation: Double) -> Self { Float(unifiedRepresentation) }
	public static func fromValue(_ value: SQLValue) -> Self? { if let d = value.doubleValue { return Float(d) } else { return nil } }
}

extension Date: SQLColumnWrappable, SQLStorableAsDouble {
	public func unifiedRepresentation() -> Double { self.timeIntervalSince1970 }
	public static func from(unifiedRepresentation: Double) -> Self { Date(timeIntervalSince1970: unifiedRepresentation) }
	public static func fromValue(_ value: SQLValue) -> Self? { if let d = value.doubleValue { return Date(timeIntervalSince1970: d) } else { return nil } }
}

extension Data: SQLColumnWrappable, SQLStorableAsData {
	public func unifiedRepresentation() -> Data { self }
	public static func from(unifiedRepresentation: Data) -> Self { unifiedRepresentation }
	public static func fromValue(_ value: SQLValue) -> Self? { value.dataValue }
}

extension String: SQLColumnWrappable, SQLStorableAsText {
	public func unifiedRepresentation() -> String { self }
	public static func from(unifiedRepresentation: String) -> Self { unifiedRepresentation }
	public static func fromValue(_ value: SQLValue) -> Self? { value.stringValue }
}

extension URL: SQLColumnWrappable, SQLStorableAsText {
	public func unifiedRepresentation() -> String { self.absoluteString }
	public static func from(unifiedRepresentation: String) -> Self { URL(string: unifiedRepresentation)! }
	public static func fromValue(_ value: SQLValue) -> Self? { if let s = value.stringValue { return URL(string: s) } else { return nil } }
}

extension Bool: SQLColumnWrappable, SQLStorableAsInteger {
	public func unifiedRepresentation() -> Int64 { Int64(self ? 1 : 0) }
	public static func from(unifiedRepresentation: Int64) -> Self { unifiedRepresentation == 0 ? false : true }
	public static func fromValue(_ value: SQLValue) -> Self? { value.boolValue }
}

extension Int: SQLColumnWrappable, SQLStorableAsInteger {
	public func unifiedRepresentation() -> Int64 { Int64(self) }
	public static func from(unifiedRepresentation: Int64) -> Self { Int(unifiedRepresentation) }
	public static func fromValue(_ value: SQLValue) -> Self? { value.intValue }
}

extension Int8: SQLColumnWrappable, SQLStorableAsInteger {
	public func unifiedRepresentation() -> Int64 { Int64(self) }
	public static func from(unifiedRepresentation: Int64) -> Self { Int8(unifiedRepresentation) }
	public static func fromValue(_ value: SQLValue) -> Self? { if let i = value.intValue { return Int8(i) } else { return nil } }
}

extension Int16: SQLColumnWrappable, SQLStorableAsInteger {
	public func unifiedRepresentation() -> Int64 { Int64(self) }
	public static func from(unifiedRepresentation: Int64) -> Self { Int16(unifiedRepresentation) }
	public static func fromValue(_ value: SQLValue) -> Self? { if let i = value.intValue { return Int16(i) } else { return nil } }
}

extension Int32: SQLColumnWrappable, SQLStorableAsInteger {
	public func unifiedRepresentation() -> Int64 { Int64(self) }
	public static func from(unifiedRepresentation: Int64) -> Self { Int32(unifiedRepresentation) }
	public static func fromValue(_ value: SQLValue) -> Self? { if let i = value.intValue { return Int32(i) } else { return nil } }
}

extension Int64: SQLColumnWrappable, SQLStorableAsInteger {
	public func unifiedRepresentation() -> Int64 { self }
	public static func from(unifiedRepresentation: Int64) -> Self { unifiedRepresentation }
	public static func fromValue(_ value: SQLValue) -> Self? { if let i = value.int64Value { return Int64(i) } else { return nil } }
}

extension UInt: SQLColumnWrappable, SQLStorableAsUnsignedInteger {
	public func unifiedRepresentation() -> UInt64 { UInt64(self) }
	public static func from(unifiedRepresentation: UInt64) -> Self { UInt(unifiedRepresentation) }
	public static func fromValue(_ value: SQLValue) -> Self? { if let i = value.uint64Value { return UInt(i) } else { return nil } }
}

extension UInt8: SQLColumnWrappable, SQLStorableAsInteger {
	public func unifiedRepresentation() -> Int64 { Int64(self) }
	public static func from(unifiedRepresentation: Int64) -> Self { UInt8(unifiedRepresentation) }
	public static func fromValue(_ value: SQLValue) -> Self? { if let i = value.intValue { return UInt8(i) } else { return nil } }
}

extension UInt16: SQLColumnWrappable, SQLStorableAsInteger {
	public func unifiedRepresentation() -> Int64 { Int64(self) }
	public static func from(unifiedRepresentation: Int64) -> Self { UInt16(unifiedRepresentation) }
	public static func fromValue(_ value: SQLValue) -> Self? { if let i = value.intValue { return UInt16(i) } else { return nil } }
}

extension UInt32: SQLColumnWrappable, SQLStorableAsInteger {
	public func unifiedRepresentation() -> Int64 { Int64(self) }
	public static func from(unifiedRepresentation: Int64) -> Self { UInt32(unifiedRepresentation) }
	public static func fromValue(_ value: SQLValue) -> Self? { if let i = value.int64Value { return UInt32(i) } else { return nil } }
}

extension UInt64: SQLColumnWrappable, SQLStorableAsUnsignedInteger {
	public func unifiedRepresentation() -> UInt64 { self }
	public static func from(unifiedRepresentation: UInt64) -> Self { unifiedRepresentation }
	public static func fromValue(_ value: SQLValue) -> Self? { if let i = value.uint64Value { return UInt64(i) } else { return nil } }
}

// MARK: - Enums, hacks for optionals

protocol OptionalProtocol {
	func wrappedType() -> Any.Type
}
extension Optional : OptionalProtocol {
	func wrappedType() -> Any.Type {
		return Wrapped.self
	}
}

/// Declares an enum as compatible with SQL column storage, with a raw type of `String` or `URL`.
public protocol SQLStringEnum: RawRepresentable, CaseIterable, SQLColumnWrappable where RawValue: SQLStorableAsText {
	associatedtype RawValue
}

/// Declares an enum as compatible with SQL column storage, with a SQL-compatible raw integer type such as `Int`.
public protocol SQLIntegerEnum: RawRepresentable, CaseIterable, SQLColumnWrappable where RawValue: SQLStorableAsInteger {
	associatedtype RawValue
	static func unifiedRawValue(from unifiedRepresentation: Int64) -> RawValue
}

extension SQLStringEnum {
	public static func fromValue(_ value: SQLValue) -> Self? { if let s = value.stringValue { return Self(rawValue: RawValue.from(unifiedRepresentation: s)) } else { return nil } }
	
	internal static func defaultPlaceholderValue() -> Self { allCases.first! }
}

extension SQLIntegerEnum {
	public static func unifiedRawValue(from unifiedRepresentation: Int64) -> RawValue { RawValue.from(unifiedRepresentation: unifiedRepresentation) }
	public static func fromValue(_ value: SQLValue) -> Self? { if let i = value.int64Value { return Self(rawValue: Self.unifiedRawValue(from: i)) } else { return nil } }
	internal static func defaultPlaceholderValue() -> Self { allCases.first! }
}

/// A wrapper for SQLite's column data types.
public enum SQLValue: Sendable, ExpressibleByStringLiteral, ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral, Hashable, Comparable {
	public static func < (lhs: SQLValue, rhs: SQLValue) -> Bool {
		switch lhs {
			case .null:           return false
			case let .uinteger(i): return i < rhs.uint64Value ?? 0
			case let .integer(i): return i < rhs.int64Value ?? 0
			case let .double(d):  return d < rhs.doubleValue ?? 0
			case let .text(s):    return s < rhs.stringValue ?? ""
			case let .data(b):    return b.count < rhs.dataValue?.count ?? 0
		}
	}
	
	case null
	case uinteger(UInt64)
	case integer(Int64)
	case double(Double)
	case text(String)
	case data(Data)
	
	public enum Error: Swift.Error {
		case cannotConvertToValue
	}
	
	public func hash(into hasher: inout Hasher) {
		hasher.combine(sqliteLiteral())
	}
	
	public static func fromAny(_ value: Any?) throws -> SQLValue {
		guard let value else { return .null }
		
		// it may make mistakes and fail to convert unsignedIntegers.
		if let v = value as? any SQLStorableAsUnsignedInteger {
			return .uinteger(v.unifiedRepresentation())
		}
		
		switch value {
			case _ as NSNull: return .null
			case let v as SQLValue: return v
			case let v as any StringProtocol: return .text(String(v))
			//case let v as any SQLStorableAsUnsignedInteger: return .uinteger(v.unifiedRepresentation())
			case let v as any SQLStorableAsInteger: return .integer(v.unifiedRepresentation())
			case let v as any SQLStorableAsDouble: return .double(v.unifiedRepresentation())
			case let v as any SQLStorableAsText: return .text(v.unifiedRepresentation())
			case let v as any SQLStorableAsData: return .data(v.unifiedRepresentation())
			case let v as any SQLIntegerEnum: return .integer(v.rawValue.unifiedRepresentation())
			case let v as any SQLStringEnum: return .text(v.rawValue.unifiedRepresentation())
			default: throw Error.cannotConvertToValue
		}
	}
	
	public init(stringLiteral value: String) { self = .text(value) }
	public init(floatLiteral value: Double)  { self = .double(value) }
	public init(integerLiteral value: Int64) { self = .integer(value) }
	public init(booleanLiteral value: Bool)  { self = .integer(value ? 1 : 0) }
	
	public func sqliteLiteral() -> String {
		switch self {
			case let .uinteger(i): 	return String(i)
			case let .integer(i):	return String(i)
			case let .double(d):  	return String(d)
			case let .text(s):    	return "'\(s.replacingOccurrences(of: "'", with: "''"))'"
			case let .data(b):    	return "X'\(b.map { String(format: "%02hhX", $0) }.joined())'"
			case .null:           	return "NULL"
		}
	}
	
	/// SQLite needs a default value when we are not null - but we can't ever store an AutoModel without a default value. So having a duplicate value stored in the DB is pointless. Sometimes you also don't want that, e.g. when default should be Date.now()
	public func ignoreDefault() -> String {
		switch self {
			case .uinteger(_): 	return "1"
			case .integer(_): 	return "1"
			case .double(_):  	return "1.0"
			case .text(_):    	return "''"
			case .data(_):    	return "X''"
			case .null:			return "NULL"
		}
	}
	
	public static func fromSQLiteLiteral(_ literalString: String?) -> Self? {
		guard let literalString else { return nil }
		if literalString == "NULL" { return .null }
		
		if literalString.hasPrefix("'"), literalString.hasSuffix("'") {
			let start = literalString.index(literalString.startIndex, offsetBy: 1)
			let end = literalString.index(literalString.endIndex, offsetBy: -1)
			return .text(literalString[start..<end].replacingOccurrences(of: "''", with: "'"))
		}
		
		if literalString.hasPrefix("X'"), literalString.hasSuffix("'") {
			let start = literalString.index(literalString.startIndex, offsetBy: 2)
			let end = literalString.index(literalString.endIndex, offsetBy: -1)
			let hex = literalString[start..<end].replacingOccurrences(of: "''", with: "'")
			
			let hexChars = hex.map { $0 }
			let hexPairs = stride(from: 0, to: hexChars.count, by: 2).map { String(hexChars[$0]) + String(hexChars[$0 + 1]) }
			let bytes = hexPairs.compactMap { UInt8($0, radix: 16) }
			return .data(Data(bytes))
		}
		
		if let i = UInt64(literalString) { return .uinteger(i) }
		if let i = Int64(literalString) { return .integer(i) }
		if let d = Double(literalString) { return .double(d) }
		return nil
	}
	
	public var boolValue: Bool? {
		switch self {
			case .null:           return nil
			case let .integer(i): return i > 0
			case let .uinteger(i): return i > 0
			case let .double(d):  return d > 0
			case let .text(s):    return (Int(s) ?? 0) != 0
			case let .data(b):    if let str = String(data: b, encoding: .utf8), let i = Int(str) { return i != 0 } else { return nil }
		}
	}
	
	public var dataValue: Data? {
		switch self {
			case .null:           return nil
			case let .data(b):    return b
			case let .uinteger(i): return String(i).data(using: .utf8)
			case let .integer(i): return String(i).data(using: .utf8)
			case let .double(d):  return String(d).data(using: .utf8)
			case let .text(s):    return s.data(using: .utf8)
		}
	}
	
	public var doubleValue: Double? {
		switch self {
			case .null:           return nil
			case let .double(d):  return d
			case let .uinteger(i): return Double(i)
			case let .integer(i): return Double(i)
			case let .text(s):    return Double(s)
			case let .data(b):    if let str = String(data: b, encoding: .utf8) { return Double(str) } else { return nil }
		}
	}
	
	public var intValue: Int? {
		switch self {
			case .null:           return nil
			case let .uinteger(i): return Int(bitPattern: UInt(i))
			case let .integer(i): return Int(i)
			case let .double(d):  return Int(d)
			case let .text(s):    return Int(s)
			case let .data(b):    if let str = String(data: b, encoding: .utf8) { return Int(str) } else { return nil }
		}
	}
	
	public var int64Value: Int64? {
		switch self {
			case .null:           return nil
			case let .integer(i): return i
			case let .uinteger(i): return Int64(bitPattern: i)
			case let .double(d):  return Int64(d)
			case let .text(s):    return Int64(s)
			case let .data(b):    if let str = String(data: b, encoding: .utf8) { return Int64(str) } else { return nil }
		}
	}
	
	public var uint64Value: UInt64? {
		switch self {
			case .null:				return nil
			case let .integer(i):	return UInt64(bitPattern: i)
			case let .uinteger(i):	return i
			case let .double(d):	return UInt64(bitPattern: Int64(d))
			case let .text(s):    	return UInt64(s)
			case let .data(b):    	if let str = String(data: b, encoding: .utf8) { return UInt64(str) } else { return nil }
		}
	}
	
	public var stringValue: String? {
		switch self {
			case .null:           return nil
			case let .text(s):    return s
			case let .integer(i): return String(i)
			case let .uinteger(i): return String(i)
			case let .double(d):  return String(d)
			case let .data(b):    return String(data: b, encoding: .utf8)
		}
	}
	
	private static let copyValue = unsafeBitCast(-1, to: sqlite3_destructor_type.self) // a.k.a. SQLITE_TRANSIENT
	
	internal func bind(database: isolated Database, statement: OpaquePointer, index: Int32, for query: String) throws {
		var result: Int32
		switch self {
			case     .null:       result = sqlite3_bind_null(statement, index)
			case let .integer(i): result = sqlite3_bind_int64(statement, index, Int64(i))
			case let .uinteger(i): result = sqlite3_bind_int64(statement, index, Int64(bitPattern: i))
			case let .double(d):  result = sqlite3_bind_double(statement, index, d)
			case let .text(s):    result = sqlite3_bind_text(statement, index, s, -1, SQLValue.copyValue)
			case let .data(d):    result = d.withUnsafeBytes { bytes in sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), SQLValue.copyValue) }
		}
		if result != SQLITE_OK { throw Database.Error.queryArgumentValueError(query: query, description: database.errorDesc(database.dbHandle)) }
	}
	
	internal func bind(database: isolated Database, statement: OpaquePointer, name: String, for query: String) throws {
		let idx = sqlite3_bind_parameter_index(statement, name)
		if idx == 0 { throw Database.Error.queryArgumentNameError(query: query, name: name) }
		return try bind(database: database, statement: statement, index: idx, for: query)
	}
}

internal struct SQLIndex: Equatable, Hashable, Sendable {
	public enum Error: Swift.Error {
		case cannotParseIndexDefinition(definition: String, description: String)
	}
	
	public static func == (lhs: Self, rhs: Self) -> Bool { return lhs.name == rhs.name && lhs.unique == rhs.unique && lhs.columnNames == rhs.columnNames }
	public func hash(into hasher: inout Hasher) {
		hasher.combine(name)
		hasher.combine(unique)
		hasher.combine(columnNames)
	}
	
	private static let parserIgnoredCharacters: CharacterSet = .whitespacesAndNewlines.union(CharacterSet(charactersIn: "`'\""))
	
	internal let name: String
	internal let unique: Bool
	internal let columnNames: [String]
	
	internal func definition(tableName: String) -> String {
		if columnNames.isEmpty { fatalError("Indexes require at least one column") }
		return "CREATE \(unique ? "UNIQUE " : "")INDEX `\(tableName)+index+\(name)` ON \(tableName) (\(columnNames.joined(separator: ",")))"
	}
	
	public init(columnNames: [String], unique: Bool = false) {
		guard !columnNames.isEmpty else { fatalError("No columns specified") }
		self.columnNames = columnNames
		self.unique = unique
		self.name = columnNames.joined(separator: "+")
	}
	
	internal init(definition: String) throws {
		let scanner = Scanner(string: definition)
		scanner.charactersToBeSkipped = Self.parserIgnoredCharacters
		scanner.caseSensitive = false
		guard scanner.scanString("CREATE") != nil else { throw Error.cannotParseIndexDefinition(definition: definition, description: "Expected 'CREATE'") }
		unique = scanner.scanString("UNIQUE") != nil
		guard scanner.scanString("INDEX") != nil else { throw Error.cannotParseIndexDefinition(definition: definition, description: "Expected 'INDEX'") }
		
		guard let indexName = scanner.scanUpToString(" ON")?.trimmingCharacters(in: Self.parserIgnoredCharacters), !indexName.isEmpty else {
			throw Error.cannotParseIndexDefinition(definition: definition, description: "Expected index name")
		}
		
		let nameScanner = Scanner(string: indexName)
		_ = nameScanner.scanUpToString("+index+")
		if nameScanner.scanString("+index+") == "+index+" {
			self.name = String(indexName.suffix(from: nameScanner.currentIndex))
		} else {
			throw Error.cannotParseIndexDefinition(definition: definition, description: "Index name does not match expected format")
		}
		
		guard scanner.scanString("ON") != nil else { throw Error.cannotParseIndexDefinition(definition: definition, description: "Expected 'ON'") }
		
		guard let tableName = scanner.scanUpToString("(")?.trimmingCharacters(in: Self.parserIgnoredCharacters), !tableName.isEmpty else {
			throw Error.cannotParseIndexDefinition(definition: definition, description: "Expected table name")
		}
		guard scanner.scanString("(") != nil, let columnList = scanner.scanUpToString(")"), scanner.scanString(")") != nil, !columnList.isEmpty else {
			throw Error.cannotParseIndexDefinition(definition: definition, description: "Expected column list")
		}
		
		columnNames = columnList.components(separatedBy: ",").map { $0.trimmingCharacters(in: Self.parserIgnoredCharacters) }.filter { !$0.isEmpty }
		guard !columnNames.isEmpty else { throw Error.cannotParseIndexDefinition(definition: definition, description: "No columns specified") }
	}
}
