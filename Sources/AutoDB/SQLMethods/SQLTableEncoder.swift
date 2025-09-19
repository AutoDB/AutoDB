//
//  File.swift
//  
//
//  Created by Olof Thorén on 2021-07-06.
//

import Foundation

/// Setup and do migrations using the tableEncoder, it will then return a TableInfo we need to store for future use.
class SQLTableEncoder: Encoder, @unchecked Sendable {
    
	var columns = [Column]()
	var addedColumns: Set<String> = []
	var settings: AutoDBSettings?
	
	public var codingPath: [CodingKey]
	public var userInfo: [CodingUserInfoKey : Any]
	var singleValueEncoder = SingleValueEncoder()
	
	init(_ codingPath: [CodingKey] = [], _ userInfo: [CodingUserInfoKey : Any] = [:]) {
		self.codingPath = codingPath
		self.userInfo = userInfo
	}
	
	func setup<T: Table>(_ classType: T.Type, _ db: Database, _ settings: AutoDBSettings) async throws -> TableInfo {
		let instance = classType.init()
		let tableName = classType.typeName
		
		self.settings = settings
		
		//we automatically get all values, this will call container<Key>(keyedBy type: Key.Type) -> ...
		// and then encode<T>(_ value: T, forKey key: KeyType) for each value, including optionals with a default value.
		try instance.encode(to: self)
		
		// now we are missing all optionals with default nil-value, add all optionals again (we ignore duplicate keys)
		for (column, path) in instance.allKeyPaths {
			if let type = (instance[keyPath: path] as? OptionalProtocol)?.wrappedType(),
			   let (columnType, _) = SQLTableEncoder.getColumnType(type) {
				
				addColumn(column, columnType, type)
			}
		}
		
		// now we have all columns and can create our table
		let tableInfo = await TableInfo(settings: settings, tableName, columns)
		
		var columnsInDB: [Column] = []
		let query = "PRAGMA table_info('\(tableName)')"
		for row in try await db.query(query) {
			columnsInDB.append(try Column(row: row, tableName: tableName))
		}
		
		if columnsInDB.isEmpty {
			// table does not exist. Create it!
			try await db.execute(tableInfo.createTableSyntax())
			
			for statement in tableInfo.createIndexStatements(instance) {
				try await db.execute(statement)
			}
			return tableInfo
		}
		
		//self.fullTextIndex = nil
		let indicesInDB: [SQLIndex] = try await db.query("SELECT sql FROM sqlite_master WHERE type = 'index' AND tbl_name = ?", [tableName]).compactMap { row in
			guard let sql = row["sql"]?.stringValue else { return nil }
			return try SQLIndex(definition: sql)
		}
		
		// MARK: now compare tables to see what's needed
		
		// comparing as Sets to ignore differences in column/index order
		let targetColumns = Set(tableInfo.columns)
		let targetIndices = tableInfo.allIndices(instance)
		
		let changedIndices = Set(indicesInDB).subtracting(targetIndices)
		let changedColumns = Set(columnsInDB).subtracting(targetColumns)	// remove similar == non-changed
		let addedIndices = targetIndices.subtracting(indicesInDB)
		let addedColumns = targetColumns.filter { column in
			columnsInDB.contains { $0.name == column.name } == false
		}
		
		let needsSchemaChanges = !changedColumns.isEmpty || !changedIndices.isEmpty || !addedColumns.isEmpty || !addedIndices.isEmpty
		
		let changedTypes = changedColumns.filter { column in
			targetColumns.contains { $0.name == column.name }
		}
		/*
		 TODO: For testing/debugging - we have not completed all migration tests yet!
		for typeInDB in changedTypes {
			for target in targetColumns where target.name == typeInDB.name {
				print("equals? \(typeInDB == target)")
			}
		}
		*/
		
		// wait with FTS until the rest is up and running!
		//let needsFTSRebuild = try fullTextIndex?.needsRebuild(core: core) ?? false
		//let needsFTSDelete = try fullTextIndex == nil && FullTextIndexSchema.ftsTableExists(core: core, contentTableName: name)
		let needsFTSRebuild = false
		let needsFTSDelete = false
		
		try await db.transaction { db, token in
			
			var addedIndices = addedIndices
			// drop indices if needed
			for indexToDrop in changedIndices {
				do {
					try await db.query(token: token, "DROP INDEX `\(indexToDrop.name)`")
				} catch {
					print("ERROR: could not drop index: \(error)")
				}
			}
			
			// add new columns
			for columnToAdd in addedColumns {
				if !columnToAdd.mayBeNull, let valueType = columnToAdd.valueType, valueType is URL.Type {
					print("Cannot add non-NULL URL column `\(columnToAdd.name)` yet! Need to specify a valid default URL")
					throw TableError.impossibleUrlMigration
				}
				
				try await db.query(token: token, "ALTER TABLE `\(tableName)` ADD COLUMN \(columnToAdd.definition())")
			}
			
			if changedTypes.isEmpty == false {
				// This looks completely pointless since SQLite is dynamic and can return whatever for types, but this is a convinient way to update the table info.
				
				// nullability may have changed if so we need a new table - we can't insert null in a non-null column.
				let tempTableName = "_\(tableName)+temp+\(Int32.random(in: 0..<Int32.max))"
				try await db.query(token: token, tableInfo.createTableSyntax(tempTableName))
				
				let columnNames = tableInfo.columns.map { $0.name }
				let fieldList = "`\(columnNames.joined(separator: "`,`"))`"
				try await db.query(token: token, "INSERT OR REPLACE INTO `\(tempTableName)` (\(fieldList)) SELECT \(fieldList) FROM `\(tableName)`")
				try await db.query(token: token, "DROP TABLE `\(tableName)`")
				try await db.query(token: token, "ALTER TABLE `\(tempTableName)` RENAME TO `\(tableName)`")
				
				// re-add all indices
				for indexToAdd in targetIndices {
					try await db.query(token: token, indexToAdd.definition(tableName: tableName))
				}
				addedIndices.removeAll()
				
				// TODO: Now you'd want to convert all values if they need special handling (e.g. converting dates to strings)
			}
			else if needsSchemaChanges || needsFTSRebuild || needsFTSDelete {
				
				// drop columns
				for columnNameToDrop in changedColumns.map({ $0.name }) {
					try await db.query(token: token, "ALTER TABLE `\(tableName)` DROP COLUMN `\(columnNameToDrop)`")
				}
				
			/*
			 // TODO: drop fts or delete its data.
				if needsFTSRebuild { try fullTextIndex?.rebuild(core: core) }
				
				if needsFTSDelete {
					try core.query("DROP TRIGGER IF EXISTS `\(FullTextIndexSchema.insertTriggerName(name))`")
					try core.query("DROP TRIGGER IF EXISTS `\(FullTextIndexSchema.updateTriggerName(name))`")
					try core.query("DROP TRIGGER IF EXISTS `\(FullTextIndexSchema.deleteTriggerName(name))`")
					try core.query("DROP TABLE IF EXISTS `\(FullTextIndexSchema.ftsTableName(name))`")
				}
			}
			*/
			
			}
			
			// add new indices if needed
			for indexToAdd in addedIndices {
				do {
					try await db.query(token: token, indexToAdd.definition(tableName: tableName))
				} catch {
					print("ERROR: could not create index: \(error)")
				}
			}
		}
		
		return tableInfo
	}
    
	/// add a column that defaults to non-nil, can still be optional
	func addColumn<T: EncodableSendable>(_ column: String, _ type: ColumnType, _ valueType: Any.Type, _ nullable: Bool, _ defaultValue: T?) {
		let column = column.deleteUnderscorePrefix()
		if addedColumns.contains(column) || column.hasPrefix("_$") || column.hasPrefix("$") || column.hasPrefix("__") {
			//print("ignoring \(column)")
			return
		}
		if addedColumns.insert(column).inserted {
			columns.append(Column(name: column, columnType: type, valueType: valueType, mayBeNull: nullable, defaultValue: defaultValue))
		}
    }
	
	/// add an optional column that defaults to nil
	func addColumn(_ column: String, _ type: ColumnType, _ valueType: Any.Type) {
		let column = column.deleteUnderscorePrefix()
		if addedColumns.contains(column) || column.hasPrefix("_$") || column.hasPrefix("$") || column.hasPrefix("__") {
			//print("ignoring \(column)")
			return
		}
		if addedColumns.insert(column).inserted {
			columns.append(Column(name: column, columnType: type, valueType: valueType, mayBeNull: true, defaultValue: nil))
		}
	}
    
    public func container<Key>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> where Key : CodingKey {
        
        return KeyedEncodingContainer(Container(enc: self))
    }
    
    func unkeyedContainer() -> UnkeyedEncodingContainer {
        return singleValueEncoder
    }
    func singleValueContainer() -> SingleValueEncodingContainer {
        return singleValueEncoder
    }
	
	static func alwaysIgnoreType<T>(_ value: T) -> Bool {
#if canImport(Darwin) && canImport(Observation)
		if #available(macOS 14.0, *), #available(iOS 17.0, *) {
			if type(of: value) is Observation.ObservationRegistrar.Type {
				// all observed objects get this, we ignore it
				return true
			}
		}
#endif
		return false
	}
    
    /// Must convert each type to SQLite-types, note that they are dynamic so SQL doesn't really care what type we claim it to be.
	static func getColumnType<T>(_ value: T) -> (ColumnType, Bool)? {
        
		if alwaysIgnoreType(value) {
			return nil
		}
        var columnType:ColumnType? = nil
		var nullable = false
		switch value {
            //we can have values
            case is String:
                columnType = .text
            case is Data:
                columnType = .blob
            case is Double, is Float, is Date:
                columnType = .real
            case is Int, is Int8, is Int16, is Int64, is Int32,
                 is UInt, is UInt8, is UInt16, is UInt64, is UInt32:
                columnType = .integer
            
            //or types
            case is String.Type:
                columnType = .text
            case is Data.Type:
                columnType = .blob
            case is Double.Type, is Float.Type, is Date.Type:
                columnType = .real
            case is Int.Type, is Int8.Type, is Int16.Type, is Int64.Type, is Int32.Type,
                 is UInt.Type, is UInt8.Type, is UInt16.Type, is UInt64.Type, is UInt32.Type:
                columnType = .integer
                
            //or types that are optional
            case is String?.Type:
                columnType = .text
				nullable = true
            case is Data?.Type:
                columnType = .blob
				nullable = true
            case is Double?.Type, is Float?.Type, is Date?.Type:
                columnType = .real
				nullable = true
            case is Int?.Type, is Int8?.Type, is Int16?.Type, is Int64?.Type, is Int32?.Type,
                 is UInt?.Type, is UInt8?.Type, is UInt16?.Type, is UInt64?.Type, is UInt32?.Type:
                columnType = .integer
				nullable = true
            default:
                //All other gets JSON format since we know they are enodable
                //.blob
                break
        }
		if let columnType {
			return (columnType, nullable)
		}
		return nil
    }
    
    /// This is used for Encoding, so that we can leverage Swifts Codable to get the values and types.
    class Container<KeyType: CodingKey>: KeyedEncodingContainerProtocol {
		typealias Key = KeyType
		
		var enc: SQLTableEncoder
		
        var codingPath: [CodingKey] = []
		
		init(enc: SQLTableEncoder) {
			self.enc = enc
		}
        
		func encodeNil(forKey key: KeyType) throws { fatalError("This will not happen, but if it does - give it a default value.") }
        func encode(_ value: String, forKey key: KeyType) throws {
			enc.addColumn(key.stringValue, .text, String.self, false, value)
        }
        
        func encode<T>(_ value: T, forKey key: KeyType) throws where T : EncodableSendable {
            
            if SQLTableEncoder.alwaysIgnoreType(value) {
				return
			}
            if let (sqlType, nullable) = SQLTableEncoder.getColumnType(value) {
				enc.addColumn(key.stringValue, sqlType, type(of: value), nullable, value)
            }
            else {
				//If not of basic type, we can still encode it as blob.
				let encoder = JSONEncoder()
				encoder.outputFormatting = .sortedKeys	//sort keys so the data will look the same for the same values.
				let data = (try? encoder.encode(value)) ?? Data()
				//print("encoding: \(type(of: value)) for: \(key.stringValue)")
				//print("result: " + String(data: data, encoding: .utf8)!)
				enc.addColumn(key.stringValue, .blob, Data.self, false, data)
            }
        }
		
		func encodeIfPresent(_ value: String?, forKey key: KeyType) throws {
			if let (sqlType, _) = SQLTableEncoder.getColumnType(type(of: value)) {
				enc.addColumn(key.stringValue, sqlType, String.self, true, value)
			}
		}
		
		func encodeIfPresent<T>(_ value: T?, forKey key: KeyType) throws where T : EncodableSendable {
			if SQLTableEncoder.alwaysIgnoreType(value) {
				return
			}
			let metaType = type(of: value)
			if let (sqlType, _) = SQLTableEncoder.getColumnType(metaType) {
				enc.addColumn(key.stringValue, sqlType, metaType, true, value)
			} else {
				//If not of basic type, we can still encode it as blob.
				enc.addColumn(key.stringValue, .blob, metaType, true, value)
			}
		}

        func nestedContainer<NestedKey>(keyedBy keyType: NestedKey.Type, forKey key: KeyType) -> KeyedEncodingContainer<NestedKey> where NestedKey: CodingKey { fatalError() }
        func nestedUnkeyedContainer(forKey key: KeyType) -> UnkeyedEncodingContainer { fatalError() }
        func superEncoder() -> Encoder { fatalError() }
        func superEncoder(forKey key: KeyType) -> Encoder { fatalError() }
    }
    
    class SingleValueEncoder: SingleValueEncodingContainer, UnkeyedEncodingContainer {
        
        enum EncodingError: Error {
            ///We don't know how to store nil columns - typically an error when decoding optionals
            case nilEncoding
        }
        
        var lastType: ColumnType?
		var lastNullable: Bool?
        func encode<T>(_ value: T) throws where T : Encodable {
			if let tuple = SQLTableEncoder.getColumnType(value) {
				(lastType, lastNullable) = tuple
			}
        }
        var codingPath: [CodingKey] = []
        var count: Int = 1
        
        func encodeNil() throws {
            throw EncodingError.nilEncoding
        }
        
        func nestedContainer<NestedKey>(keyedBy keyType: NestedKey.Type) -> KeyedEncodingContainer<NestedKey> where NestedKey : CodingKey {
            fatalError()
        }
        
        func nestedUnkeyedContainer() -> UnkeyedEncodingContainer {
            fatalError()
        }
        
        func superEncoder() -> Encoder {
                    
            fatalError()
        }
    }
    
}
