//
//  AutoDB.swift
//  AutoDB
//
//  Heavily copied from Blackbird: https://github.com/marcoarment/Blackbird
//

import Foundation
#if canImport(Darwin)
import SQLite3
#else
fileprivate class NSFileCoordinator {
	struct WritingOptions : OptionSet, @unchecked Sendable {
		
		var rawValue: UInt
		init(rawValue: UInt) {
			self.rawValue = rawValue
		}
		static var forMerging: NSFileCoordinator.WritingOptions { .init(rawValue: 0) }
	}
	init(filePresenter whateverNilThing: Int?) {}
	func coordinate(writingItemAt url: URL, options: NSFileCoordinator.WritingOptions = [], error: inout NSError?, byAccessor writer: (URL) -> Void) {}
}
import SQLCipher
#endif

#if canImport(Android)
import Android
#elseif canImport(GlibC)
import GlibC
#endif

public typealias ChangeObserver = AsyncObserver<RowChangeParameters>
public struct RowChangeParameters: Sendable, Codable, Hashable, Equatable {
	//let tableName: String
	let operation: SQLiteOperation
	let id: AutoId
}

public enum SQLiteOperation: Int32, Sendable, Codable {
	case insert = 18
	case update = 23
	case delete = 9
}

struct PreparedStatement {
	let handle: OpaquePointer
	let isReadOnly: Bool
	//var usage: Int = 0 this was a bad idea to figure out when to remove cached statements - leave it here to remember, it slows us don't and we still can't know if it has heavy use in the start of an app and then none - lingering forever.
}

public typealias Row = Dictionary<String, SQLValue>

// shortcuts to create smart lists
extension [Row] {
	func ids() -> [AutoId] {
		self.compactMap { $0["id"]?.uint64Value }
	}
}


/**
 AutoDB is the database connection mechanism of the system.
 */
public actor AutoDB {
	
	/// The maximum number of parameters (`?`) supported in database queries. (The value of `SQLITE_LIMIT_VARIABLE_NUMBER` of the backing SQLite instance.)
	let maxQueryVariableCount: Int
	
	let dbHandle: OpaquePointer
	
	public var isClosed: Bool = false
	private var cachedStatements: [String: PreparedStatement] = [:]
	private let semaphore = Semaphore()
	private var inTransaction: Bool = false
	private var debugPrintEveryQuery = false
	private var debugPrintQueryParameterValues = false
	func setDebug(_ enabled: Bool = true) {
		debugPrintEveryQuery = enabled
		debugPrintQueryParameterValues = enabled
	}
	
	public init(_ path: String, ramDB: Bool = false) throws {
		
		let url = URL(fileURLWithPath: path)
		let folder = url.deletingLastPathComponent()
		try FileManager.default.createDirectory(atPath: folder.path, withIntermediateDirectories: true)
		
		var flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
		if ramDB {
			flags |= SQLITE_OPEN_MEMORY
		}
		var handle: OpaquePointer? = nil
		var result: Int32 = SQLITE_ERROR
		if #available(iOS 5.0, macOS 10.7, tvOS 9.0, visionOS 1, watchOS 2, *) {
			
			var coordinatorError: NSError?
			NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forMerging, error: &coordinatorError) { _ in
				result = sqlite3_open_v2(path, &handle, flags, nil)
			}
			if let coordinatorError {
				throw coordinatorError
			}
		} else {
			result = sqlite3_open_v2(path, &handle, flags, nil)
		}
		
		guard let handle else {
			throw Error.cannotOpenDatabaseAtPath(path: path, description: "SQLite cannot allocate memory")
		}
		guard result == SQLITE_OK else {
			let code = sqlite3_errcode(handle)
			let msg = String(cString: sqlite3_errmsg(handle), encoding: .utf8) ?? "(unknown)"
			sqlite3_close(handle)
			throw Error.cannotOpenDatabaseAtPath(path: path, description: "SQLite error code \(code): \(msg)")
		}
		self.dbHandle = handle
		self.maxQueryVariableCount = Int(sqlite3_limit(handle, SQLITE_LIMIT_VARIABLE_NUMBER, -1))
		// this allows us to do simultaneous writes, by waiting whenever the DB is busy. It is by design to retry.
		sqlite3_busy_timeout(handle, 80)
		
		// turn on Write Ahead Logging, may not be able to but that is ok - then we use the older slower method instead.
		if SQLITE_OK != sqlite3_exec(handle, "PRAGMA journal_mode = WAL", nil, nil, nil) {
			print("AutoDB: Cannot enable Write Ahead Logging (upgrade SQLite")
		}
		
		// we don't need to assign a pointer to this function since we can only have one update_hook per handle.
		sqlite3_update_hook(dbHandle, { ctx, operation, dbName, tableName, rowid in
			
			guard let ctx, let operation = SQLiteOperation(rawValue: operation),
				  let tableName, let tableNameStr = String(cString: tableName, encoding: .utf8) else {
				return
			}
			let autoDB = Unmanaged<AutoDB>.fromOpaque(ctx).takeUnretainedValue()
			Task {
				await autoDB.callListeners(tableNameStr, operation, rowid)
			}
			
		}, Unmanaged<AutoDB>.passUnretained(self).toOpaque())
	}
	
	var gentleClose: Task<Void, Swift.Error>?
	var harshClose: Task<Void, Swift.Error>?
	public func close(_ token: AutoId? = nil) async {
		gentleClose = Task {
			let hasSemaphore = inTransaction || token != nil
			if hasSemaphore {
				await semaphore.wait(token: token)
			}
			defer { if hasSemaphore { Task { await semaphore.signal(token: token) } } }
			try Task.checkCancellation()
			isClosed = true
		}
		
		// kill after some time?
		harshClose = Task {
			try await Task.sleep(nanoseconds: 10_000_000_000)
			try Task.checkCancellation()
			isClosed = true
			// print("killing sqlite and forcing close")
			// sqlite3_interrupt(dbHandle)	//https://www.sqlite.org/c3ref/interrupt.html
		}
	}
	
	public func open() async {
		isClosed = false
		gentleClose?.cancel()
		harshClose?.cancel()
	}
	
	nonisolated internal func errorDesc(_ dbHandle: OpaquePointer?, _ query: String? = nil) -> String {
		guard let dbHandle else { return "No SQLite handle" }
		let code = sqlite3_errcode(dbHandle)
		let msg = String(cString: sqlite3_errmsg(dbHandle), encoding: .utf8) ?? "(unknown)"
		
		if #available(iOS 16, watchOS 9, macOS 13, tvOS 16, *), case let offset = sqlite3_error_offset(dbHandle), offset >= 0 {
			return "SQLite error code \(code) at index \(offset): \(msg)"
		} else {
			return "SQLite error code \(code): \(msg)"
		}
	}
	
	public enum Error: Swift.Error {
		//case anotherInstanceExistsWithPath(path: String)
		case cannotOpenDatabaseAtPath(path: String, description: String)
		//case unsupportedConfigurationAtPath(path: String)
		case queryError(query: String, description: String)
		//case backupError(description: String)
		case queryArgumentNameError(query: String, name: String)
		case queryArgumentValueError(query: String, description: String)
		case queryExecutionError(query: String, description: String)
		case queryResultValueError(query: String, column: String)
		case uniqueConstraintFailed
		case databaseIsClosed
	}
	
	public var changeCount: Int64 {
		get {
			if #available(macOS 12.3, iOS 15.4, tvOS 15.4, watchOS 8.5, *) {
				return Int64(sqlite3_total_changes64(dbHandle))
			} else {
				return Int64(sqlite3_total_changes(dbHandle))
			}
		}
	}
	
	@discardableResult
	public func query(token: AutoId? = nil, _ queryString: String, _ arguments: [Sendable] = []) async throws -> [Row] {
		let values = try arguments.map {
			// we must cast or somehow find out which SQL-type each argument is!
			try SQLValue.fromAny($0)
		}
		return try await query(token: token, queryString, sqlArguments: values)
	}
	
	@discardableResult
	public func query(token: AutoId? = nil, _ query: String, sqlArguments: [SQLValue] = []) async throws -> [Row] {
		// only take semaphore if in transaction - other times we can run queries in parallel (as much as being an actor allows)
		let hasSemaphore = inTransaction || token != nil
		if hasSemaphore {
			await semaphore.wait(token: token)
		}
		defer { if hasSemaphore { Task { await semaphore.signal(token: token) } } }
		if isClosed { throw Error.databaseIsClosed }
		
		let statement = try preparedStatement(query)
		let statementHandle = statement.handle
		var idx = 1 // SQLite bind-parameter indices start at 1, not 0!
		for value in sqlArguments {
			try value.bind(database: self, statement: statementHandle, index: Int32(idx), for: query)
			idx += 1
		}
		
		return try rowsByExecutingPreparedStatement(statement, from: query)
	}
	
	/*
	@discardableResult
	public func query(_ query: String, arguments: [String: Sendable]) throws -> [Row] {
		if isClosed { throw Error.databaseIsClosed }
		let statement = try preparedStatement(query)
		let statementHandle = statement.handle
		for (name, any) in arguments {
			let value = try Value.fromAny(any)
			try value.bind(database: self, statement: statementHandle, name: name, for: query)
		}
		
		return try _checkForUpdateHookBypass(statement: statement) {
			try rowsByExecutingPreparedStatement(statement, from: query)
		}
	}
	*/
	
	private func preparedStatement(_ query: String) throws -> PreparedStatement {
		if let cached = cachedStatements[query] {
			return cached
		}
		if cachedStatements.count > 100 {
			for (_, statement) in cachedStatements {
				sqlite3_finalize(statement.handle)
			}
			cachedStatements.removeAll()
		}
		var statementHandle: OpaquePointer? = nil
		let result = sqlite3_prepare_v3(dbHandle, query, -1, UInt32(SQLITE_PREPARE_PERSISTENT), &statementHandle, nil)
		guard result == SQLITE_OK, let statementHandle else {
			throw Error.queryError(query: query, description: errorDesc(dbHandle))
		}
		
		let statement = PreparedStatement(handle: statementHandle, isReadOnly: sqlite3_stmt_readonly(statementHandle) > 0)
		cachedStatements[query] = statement
		return statement
	}
	
	private func rowsByExecutingPreparedStatement(_ statement: PreparedStatement, from query: String) throws -> [Row] {
		if debugPrintEveryQuery {
			if debugPrintQueryParameterValues, let cStr = sqlite3_expanded_sql(statement.handle), let expandedQuery = String(cString: cStr, encoding: .utf8) {
				print("[AutoDB: \(Unmanaged.passUnretained(self).toOpaque())] \(expandedQuery)")
			} else {
				print("[AutoDB: \(Unmanaged.passUnretained(self).toOpaque())] \(query)")
			}
		}
		let statementHandle = statement.handle
		var result = sqlite3_step(statementHandle)
		// we are retrying with sqlite3_busy_timeout - but when still busy we need to retry ourselves a few more times.
		if result == SQLITE_BUSY || result == SQLITE_LOCKED {
			for _ in 0..<900 {
				usleep(10)
				result = sqlite3_step(statementHandle)
				if result != SQLITE_BUSY && result != SQLITE_LOCKED {
					break
				}
			}
			if result == SQLITE_BUSY || result == SQLITE_LOCKED {
				print("⚠️ DB is occupied with a long running write and can't be accessed even after retries.")
			}
		}
		
		guard result == SQLITE_ROW || result == SQLITE_DONE else {
			sqlite3_reset(statementHandle)
			sqlite3_clear_bindings(statementHandle)
			switch result {
				case SQLITE_CONSTRAINT: throw Error.uniqueConstraintFailed
				default: throw Error.queryExecutionError(query: query, description: errorDesc(dbHandle))
			}
		}
		
		let columnCount = sqlite3_column_count(statementHandle)
		if columnCount == 0 {
			guard sqlite3_reset(statementHandle) == SQLITE_OK, sqlite3_clear_bindings(statementHandle) == SQLITE_OK else {
				throw Error.queryExecutionError(query: query, description: errorDesc(dbHandle))
			}
			return []
		}
		
		var columnNames: [String] = []
		for i in 0 ..< columnCount {
			guard let charPtr = sqlite3_column_name(statementHandle, i), case let name = String(cString: charPtr) else {
				throw Error.queryExecutionError(query: query, description: errorDesc(dbHandle))
			}
			columnNames.append(name)
		}
		
		var rows: [Row] = []
		while result == SQLITE_ROW {
			var row: Row = [:]
			for i in 0 ..< Int(columnCount) {
				switch sqlite3_column_type(statementHandle, Int32(i)) {
					case SQLITE_NULL:    row[columnNames[i]] = .null
					case SQLITE_INTEGER: row[columnNames[i]] = .integer(sqlite3_column_int64(statementHandle, Int32(i)))
					case SQLITE_FLOAT:   row[columnNames[i]] = .double(sqlite3_column_double(statementHandle, Int32(i)))
						
					case SQLITE_TEXT:
						guard let charPtr = sqlite3_column_text(statementHandle, Int32(i)) else { throw Error.queryResultValueError(query: query, column: columnNames[i]) }
						row[columnNames[i]] = .text(String(cString: charPtr))
						
					case SQLITE_BLOB:
						let byteLength = sqlite3_column_bytes(statementHandle, Int32(i))
						if byteLength > 0 {
							guard let bytes = sqlite3_column_blob(statementHandle, Int32(i)) else { throw Error.queryResultValueError(query: query, column: columnNames[i]) }
							row[columnNames[i]] = .data(Data(bytes: bytes, count: Int(byteLength)))
						} else {
							row[columnNames[i]] = .data(Data())
						}
						
					default:
						throw Error.queryExecutionError(query: query, description: errorDesc(dbHandle))
				}
			}
			rows.append(row)
			
			result = sqlite3_step(statementHandle)
		}
		if result != SQLITE_DONE { throw Error.queryExecutionError(query: query, description: errorDesc(dbHandle)) }
		
		guard sqlite3_reset(statementHandle) == SQLITE_OK, sqlite3_clear_bindings(statementHandle) == SQLITE_OK else {
			throw Error.queryExecutionError(query: query, description: errorDesc(dbHandle))
		}
		return rows
	}
	
	/// Execute a query with no parameters returning nothing
	public func execute(token: AutoId? = nil, _ query: String) async throws {
		let hasSemaphore = inTransaction || token != nil
		if hasSemaphore {
			await semaphore.wait(token: token)
		}
		defer { if hasSemaphore { Task { await semaphore.signal(token: token) } } }
		if isClosed { throw Error.databaseIsClosed }
		
		if debugPrintEveryQuery {
			print("[AutoDB: \(Unmanaged.passUnretained(self).toOpaque())] \(query)")
		}
		var result = sqlite3_exec(dbHandle, query, nil, nil, nil)
		if result == SQLITE_BUSY || result == SQLITE_LOCKED {
			for _ in 0..<900 {
				usleep(10)
				result = sqlite3_exec(dbHandle, query, nil, nil, nil)
				if result != SQLITE_BUSY && result != SQLITE_LOCKED {
					break
				}
			}
			if result == SQLITE_BUSY || result == SQLITE_LOCKED {
				print("⚠️ DB is occupied with a long running write and can't be accessed even after retries.")
			}
		}
		if result != SQLITE_OK {
			throw Error.queryError(query: query, description: errorDesc(dbHandle))
		}
	}
	
	/// Run actions inside a transaction - any thrown error causes the DB to rollback (and the error is rethrown).
	/// ⚠️  Must use token for all db-access inside transactions, otherwise will deadlock. ⚠️
	/// Why? Since async/await and actors does not and can not deal with threads, there is no other way of knowing if you are holding the lock. We could send around the AutoDB and only allow access when locked - but that would basically be the same thing.
	public func transaction<R: Sendable>(_ action: (@Sendable (_ db: isolated AutoDB, _ token: AutoId) async throws -> R) ) async throws -> R {
		
		inTransaction = true	// now everyone must wait for semaphore
		let transactionID = AutoId.generateId()
		await semaphore.wait(token: transactionID)
		defer {
			Task {
				await semaphore.signal(token: transactionID)
				// Set a token to wait for semaphores, this way we can call DB simultaneous with regular queries but wait when there are transactions.
				// also closing the DB will wait for a whole transaction.
				inTransaction = false
			}
		}
		if isClosed { throw Error.databaseIsClosed }
		
		try await execute(token: transactionID, "SAVEPOINT \"\(transactionID)\"")
		do {
			let result: R = try await action(self, transactionID)
			try await execute(token: transactionID, "RELEASE SAVEPOINT \"\(transactionID)\"")
			return result
		} catch {
			try await execute(token: transactionID, "ROLLBACK TO SAVEPOINT \"\(transactionID)\"")
			throw error
		}
	}
	
	// MARK: - change callbacks
	
	// allow the use of ChangeObserver elsewhere, access should not be restricted to this actor.
	private nonisolated(unsafe) var changeObservers: [String: ChangeObserver] = [:]
	public func changeObserver(_ tableName: String) -> ChangeObserver {
		if let listener = changeObservers[tableName] {
			return listener
		}
		let listener = ChangeObserver()
		changeObservers[tableName] = listener
		return listener
	}
	
	private func callListeners(_ tableName: String, _ operation: SQLiteOperation, _ rowId: sqlite_int64 ) async {
		if changeObservers[tableName] != nil {
			let value = RowChangeParameters(operation: operation, id: UInt64(bitPattern: rowId))
			await changeObservers[tableName]?.append(value)
		}
	}
}
