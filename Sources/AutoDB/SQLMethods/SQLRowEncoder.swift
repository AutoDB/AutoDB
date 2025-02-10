//
//  SQLRowEncoder.swift
//  AutoDB
//
//  Created by Olof Andersson-Thorén on 2024-11-18.
//
import Foundation

typealias AnyEncodable = (any Encodable)
typealias AnyDecodable = (any Decodable)
let prefixPropertyChars = CharacterSet(charactersIn: "_")

extension String {
	func deleteUnderscorePrefix() -> String {
		guard self.hasPrefix("_"), self.hasPrefix("__") == false else { return self }
		return String(self.dropFirst(1))
	}
}

/// From an array of objects of the same type, create an insert statement with a list of values. Start with doing only one object.
public class SQLRowEncoder: Encoder, @unchecked Sendable {
	
	let database: AutoDB
	let tableClass: any AutoModel.Type
	let table: TableInfo
	let query: String
	let maxQueryVariableCount: Int
	var values: [String: AnyEncodable] = [:]
	var allValues: [SQLValue] = []
	static let jsonEncoder = JSONEncoder()
	
	public var codingPath: [CodingKey] = []
	public var userInfo: [CodingUserInfoKey : Any] = [:]
	
	/// take this before starting to encode
	let semaphore = Semaphore()
	
	init<TableClass: AutoModel>(_ classType: TableClass.Type) async {
		
		tableClass = classType
		guard let database = try? await AutoDBManager.shared.setupDB(classType) else {
			fatalError("Cannot setup table \(classType)")
		}
		self.database = database
		table = await AutoDBManager.shared.tableInfo(classType)
		maxQueryVariableCount = database.maxQueryVariableCount
		query = "INSERT OR REPLACE INTO `\(table.name)` (\(table.columnNameString)) VALUES "
	}
	
	func queryString(_ objectCount: Int) -> String {
		
		let questionMarks = AutoDBManager.questionMarksForQueriesWithObjects(objectCount, table.columns.count)
		return query + questionMarks
	}
	
	func commitRow() throws {
		if values.isEmpty {
			return
		}
		for column in table.columns {
			
			if let item = values[column.name] {
				
				/* TODO: remember the inverse of
				var wrappend: Value?
				switch column.columnType {
					case .integer:
						// remember if this is an Uint or not - then we don't need casting
						wrapped = try? Value.fromAny(item)
					case .real:
						// remember if this is a double, float or date
						wrapped = try? Value.fromAny(item)
					case .text:
						wrapped = try? Value.text(item)
					case .blob:
						// remember if this is a double, float or date
				}
				if let wrapped {
					allValues.append(wrapped)
				}
				*/
				
				if let wrapped = try? SQLValue.fromAny(item) {
					allValues.append(wrapped)
				} else if let encoded = try? SQLRowEncoder.jsonEncoder.encode(item) {
					allValues.append(SQLValue.data(encoded))
				} else {
					throw SQLValue.Error.cannotConvertToValue
				}
			} else {
				allValues.append(SQLValue.null)
			}
		}
		values.removeAll()
	}
	
	/// Insert encoded values into DB. The dbSemaphore re-entry token to allow us to call db-methods in a recursive manner.
	func commit(_ dbSemaphoreToken: AutoId? = nil) async throws {
		try commitRow()
		
		// if we have too many objects must split.
		let maxObjects = Int(floor(Double(maxQueryVariableCount) / Double(table.columns.count)) - 1)
		while allValues.isEmpty == false {
			
			let slice = min(maxObjects * table.columns.count, allValues.count)
			let args = allValues[0..<slice]
			allValues.removeFirst(slice)
			let objectCount = slice / table.columns.count
			try await database.query(token: dbSemaphoreToken, queryString(objectCount), Array(args))
		}
	}
	
	func addColumn(_ key: String, _ value: AnyEncodable?) {
		
		values[key.deleteUnderscorePrefix()] = value
	}
	
	func ignoreKey(_ column: String) -> Bool {
		table.settings?.ignoreProperties?.contains(column) ?? false
	}
	
	public func container<Key>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> where Key : CodingKey {
		// if we have started a new object
		try? commitRow()
		return KeyedEncodingContainer(Container(enc: self))
	}
	
	public func unkeyedContainer() -> UnkeyedEncodingContainer {
		fatalError()
	}
	
	public func singleValueContainer() -> SingleValueEncodingContainer {
		fatalError()
	}
	
	class Container<KeyType: CodingKey>: KeyedEncodingContainerProtocol {
		typealias Key = KeyType
		
		var enc: SQLRowEncoder
		
		var codingPath: [CodingKey] = []
		
		init(enc: SQLRowEncoder) {
			self.enc = enc
		}
		
		func encodeNil(forKey key: KeyType) throws { fatalError("All columns must have a value") }
		func encode(_ value: String, forKey key: KeyType) throws {
			if enc.ignoreKey(key.stringValue) {
				return
			}
			enc.addColumn(key.stringValue, value)
		}
		
		func encode<T>(_ value: T, forKey key: KeyType) throws where T : Encodable {
			
			if enc.ignoreKey(key.stringValue) {
				return
			}
			enc.addColumn(key.stringValue, value)
		}
		
		func encodeIfPresent<T>(_ value: T?, forKey key: KeyType) throws where T : Encodable {
			if enc.ignoreKey(key.stringValue) {
				return
			}
			if let value {
				try encode(value, forKey: key)
			} else {
				enc.addColumn(key.stringValue, nil)
			}
		}
		
		func nestedContainer<NestedKey>(keyedBy keyType: NestedKey.Type, forKey key: KeyType) -> KeyedEncodingContainer<NestedKey> where NestedKey: CodingKey { fatalError() }
		func nestedUnkeyedContainer(forKey key: KeyType) -> UnkeyedEncodingContainer { fatalError() }
		func superEncoder() -> Encoder { fatalError() }
		func superEncoder(forKey key: KeyType) -> Encoder { fatalError() }
	}
}
