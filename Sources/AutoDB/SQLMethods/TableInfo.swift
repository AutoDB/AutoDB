//
//  TableInfo.swift
//  AutoDB
//
//  Created by Olof Andersson-Thorén on 2024-11-27.
//

import Foundation

//TODO: encode all unknown formats to data, JSON or some faster/smaller format

public enum ColumnType: Int32, Sendable {
	
	//Notice that date doesn't exist in SQLite, and we don't care since Codable handles conversion for us
	case integer
	case real
	case text
	case blob
	/*
	 case json   //also data but with jsonEncoding - use a better format and convert to built in support in the future if that happens.
	 //we also need optional types
	 
	 Having a bool for nullable makes cases smaller!
	 case integerOpt
	 case realOpt
	 case textOpt
	 case blobOpt
	 case jsonOpt
	 
	 case error
	 */
	
	internal static func parseType(_ str: String) -> ColumnType {
		//if str.hasPrefix("TEXT") || str.uppercased().hasPrefix("VARCHAR") || str.uppercased().hasPrefix("CHAR") { return .text }
		if str.hasPrefix("INT") || str.hasPrefix("BOOL") { return .integer }
		if str.hasPrefix("FLOAT") || str.hasPrefix("DOUBLE") || str.hasPrefix("REAL") || str.hasPrefix("NUMERIC") { return .real }
		if str.hasPrefix("BLOB") { return .blob }
		// it doesn't really matter to SQLite what types we tell ourselves there is.
		return .text
	}
	
	internal func definition() -> String {
		switch self {
			case .integer: return "INTEGER"
			case .real: return "DOUBLE"
			case .text: return "TEXT"
			case .blob: return "BLOB"
		}
	}
	
	// we don't need to encode default values into the database.
	internal func defaultValue() -> SQLValue {
		switch self {
			case .integer: return .integer(0)
			case .real: return .double(0)
			case .text: return .text("")
			case .blob: return .data(Data())
		}
	}
}

struct TableInfo: Sendable {
	
	init(settings: AutoDBSettings?, _ name: String, _ columns: [Column]) {
		self.settings = settings
		self.name = name
		self.columns = columns
		columnNameString = "`\(columns.map{ $0.name }.joined(separator: "`,`"))`"
		deleteQuery = "DELETE FROM `\(name)` WHERE id IN (%@)"
	}
	
	/// The class/table name
	let name: String
	let columns: [Column]
	let settings: AutoDBSettings?
	/// Cached delete query
	let deleteQuery: String
	
	var columnNames: [String] {
		columns.map { $0.name }
	}
	
	let columnNameString: String
	
	/// Cache the string for fetching
	// var selectQuery: String!
	
	func createTableSyntax(_ overrideTableName: String? = nil) -> String {
		let columnDefs = columns.map { $0.definition() }.joined(separator: ",")
		let primaryKey = ",PRIMARY KEY (`id`)"
		
		return "CREATE TABLE `\(overrideTableName ?? name)` (\(columnDefs)\(primaryKey))"
	}
	
	func allIndices<T: Table>(_ emptyInstance: T) -> Set<SQLIndex> {
		var indices: [SQLIndex] = T.indices.compactMap { keyPaths in
			// get the names for each keyPath
			SQLIndex(columnNames: keyPaths, unique: false, table: name)
		}
		
		let uniqueIndicies: [SQLIndex] = T.uniqueIndices.compactMap { keyPaths in
			// get the names for each keyPath
			SQLIndex(columnNames: keyPaths, unique: true, table: name)
		}
		indices.append(contentsOf: uniqueIndicies)
		return Set(indices)
	}
	
	func createIndexStatements<T: Table>(_ emptyInstance: T) -> [String] {
		// we want it to look like CREATE UNIQUE INDEX [IF NOT EXISTS] index_name ON table_name(column1, column2, ...)
		var indices: [SQLIndex] = T.indices.compactMap { keyPaths in
			// get the names for each keyPath
			SQLIndex(columnNames: keyPaths, unique: false, table: name)
		}
		
		let uniqueIndicies: [SQLIndex] = T.uniqueIndices.compactMap { keyPaths in
			// get the names for each keyPath
			SQLIndex(columnNames: keyPaths, unique: true, table: name)
		}
		indices.append(contentsOf: uniqueIndicies)
		
		return indices.map { $0.definition(tableName: name) }
	}
}
