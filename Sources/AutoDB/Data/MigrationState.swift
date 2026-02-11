//
//  MigrationState.swift
//  AutoDB
//
//  Created by Olof Andersson-Thorén on 2025-09-22.
//

public enum MigrationTableState: Sendable, Hashable {
	case done
	case isMigrating
}

public enum MigrationState: Sendable, Hashable {
	
	/// Called when table was created (or renamed)
	case createdTable
	/// A new column has been created
	case newColumn(Column)
	/// one or more columns has been modified or dropped, old definition for each column is supplied. Old data is kept and supplied in a separate table `oldTableName` if you need it, e.g. when changing names, the new column will be empty.
	/// @NOTE: All current data is moved, if types have changed you must apply tranformations manually or delete like so:  db.execute("UPDATE the-table/class-name SET `the-column-name` = ?", [value])
	/// See MigrationTests for in-depth example and discussion
	case changes(oldTableName: String, columns: Set<Column>)
	
	case failedIndex(index: SQLIndex, error: Error)
	
	
	public static func == (lhs: MigrationState, rhs: MigrationState) -> Bool {
		switch (lhs, rhs) {
			case (.createdTable, .createdTable):
				return true
			case (.newColumn(let column1), .newColumn(let column2)):
				return column1 == column2
			case (.changes(let oldTableName1, let columns1), .changes(let oldTableName2, let columns2)):
				return oldTableName1 == oldTableName2 && columns1 == columns2
			case (.failedIndex(let index1, let error1), .failedIndex(let index2, let error2)):
				return index1 == index2 && error1.localizedDescription == error2.localizedDescription
			default:
				return false
		}
	}
	
	public func hash(into hasher: inout Hasher) {
		switch self {
			case .createdTable:
				hasher.combine("c")
			case .newColumn(let column):
				hasher.combine(column)
			case .changes(let oldTableName, let columns):
				hasher.combine(oldTableName)
				hasher.combine(columns)
			case .failedIndex(let index, let error):
				hasher.combine(index)
				hasher.combine(error.localizedDescription)
		}
	}
}
