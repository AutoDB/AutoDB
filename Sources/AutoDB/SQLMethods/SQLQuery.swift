//
//  SQLQuery.swift
//  AutoDB
//

/// A query built with string interpolation. Interpolated values become bound arguments, so "WHERE name = \(name)" is sent as "WHERE name = ?" with name as its argument.
/// Use \(verbatim:) for SQL that must be inserted as-is, like table or column names. Never pass user input to verbatim.
public struct SQLQuery: ExpressibleByStringInterpolation, Sendable {
	public let query: String
	public let arguments: [Sendable]
	
	public init(stringLiteral value: String) {
		query = value
		arguments = []
	}
	
	public init(stringInterpolation: StringInterpolation) {
		query = stringInterpolation.query
		arguments = stringInterpolation.arguments
	}
	
	public struct StringInterpolation: StringInterpolationProtocol {
		var query = ""
		var arguments: [Sendable] = []
		
		public init(literalCapacity: Int, interpolationCount: Int) {
			query.reserveCapacity(literalCapacity + interpolationCount)
			arguments.reserveCapacity(interpolationCount)
		}
		
		public mutating func appendLiteral(_ literal: String) {
			query += literal
		}
		
		/// Bind a value as an argument
		public mutating func appendInterpolation(_ value: some Sendable) {
			query += "?"
			arguments.append(value)
		}
		
		/// Bind an optional value as an argument, nil becomes NULL
		public mutating func appendInterpolation(_ value: (some Sendable)?) {
			query += "?"
			if let value {
				arguments.append(value)
			} else {
				arguments.append(SQLValue.null)
			}
		}
		
		/// Insert SQL as-is, e.g. a table name. Never use for user input.
		public mutating func appendInterpolation(verbatim sql: String) {
			query += sql
		}
	}
}
