//
//  MigrationState.swift
//  AutoDB
//
//  Created by Olof Andersson-Thorén on 2025-09-22.
//

public enum MigrationState: Sendable, Hashable {
	/// Called when table was created (or renamed)
	case createdTable
	/// A new column has been created
	case newColumn(Column)
	/// one or more columns has been modified or dropped, old definition for each column is supplied. Old data is kept and supplied in a separate table `oldTableName` if you need it, e.g. when changing names, the new column will be empty.
	/// @NOTE: All current data is moved, if types have changed you must apply tranformations manually or delete like so:  db.execute("UPDATE the-table/class-name SET `the-column-name` = ?", [value])
	/// See MigrationTests for in-depth example and discussion
	case changes(oldTableName: String, columns: Set<Column>)
}
