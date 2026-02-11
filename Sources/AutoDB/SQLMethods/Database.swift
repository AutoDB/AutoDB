//
//  AutoDB.swift
//  AutoDB
//
//  Heavily copied from Blackbird: https://github.com/marcoarment/Blackbird
//
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

// TODO: replace token: AutoId? = nil with TaskLocal


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

public typealias RowChangeObserver = AsyncObserver<RowChangeParameters>
public typealias TableChangeObserver = AsyncObserver<SQLiteOperation>
public struct RowChangeParameters: Sendable, Codable, Hashable, Equatable {
	//let tableName: String
	public let operation: SQLiteOperation
	public var ids: [AutoId]
}

private struct DebounceRowChange {
	var parameters: RowChangeParameters
	var debounceTask: Task<Void, Error>?
}

public enum SQLiteOperation: Int32, Sendable, Codable {
	case insert = 18
	case update = 23
	case delete = 9
}

struct PreparedStatement {
	let handle: OpaquePointer
	let isReadOnly: Bool
	//var usage: Int = 0 this was a bad idea to figure out when to remove cached statements - leave it here to remember, it slows us down, and we still can't know if it has heavy use in the start of an app and then none - lingering forever.
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
public actor Database {
	
	/// The maximum number of parameters (`?`) supported in database queries. (The value of `SQLITE_LIMIT_VARIABLE_NUMBER` of the backing SQLite instance.)
	public var maxQueryVariableCount: Int = 900_000_000
	
	var dbHandle: OpaquePointer
	
	/// the file url for the DB
	private var dbURL: URL?
	
	public var isClosed: Bool = false
	private var cachedStatements: [String: PreparedStatement] = [:]
	private let semaphore = Semaphore() 
	private var inTransaction: Bool = false
	private var debugPrintEveryQuery = false
	
	public func setDebug(_ enabled: Bool = true) {
		debugPrintEveryQuery = enabled
		if enabled {
			AutoLog.setup()
		} else {
			AutoLog.notUsed = true
		}
	}
	
	/// If you never have long queries but afraid of getting deadlocks, set the watchdog to detect those. Will kill the app if transactions takes too long, so it shows up in Crashlytics or Apple's "crash" pane - then you will know.
	/// Deadlocks can happen if you create a new transaction inside another, or call a Database's queries without the transaction's token.
	public func semaphoreWatchdog(_ timeInterval: TimeInterval) async {
		await semaphore.setWatchDogTimeout(timeInterval)
	}
	
	public init(_ path: String?) throws {
		
		let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
		let url: URL? = path.flatMap { URL(fileURLWithPath: $0) }
		if let url {
			let folder = url.deletingLastPathComponent()
			try FileManager.default.createDirectory(atPath: folder.path, withIntermediateDirectories: true)
		}
		let path = path ?? ":memory:"
		// this is pointless: flags |= SQLITE_OPEN_MEMORY
		dbURL = url
		
		var handle: OpaquePointer? = nil
		var result: Int32 = SQLITE_ERROR
		if let dbURL {
			var coordinatorError: NSError?
			NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: dbURL, options: .forMerging, error: &coordinatorError) { _ in
				result = sqlite3_open_v2(path, &handle, flags, nil)
			}
			if let coordinatorError {
				throw coordinatorError
			}
		} else {
			result = sqlite3_open_v2(":memory:", &handle, flags, nil)
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
		self.maxQueryVariableCount = Int(sqlite3_limit(dbHandle, SQLITE_LIMIT_VARIABLE_NUMBER, -1))
		try setup(dbHandle)
	}
	
	nonisolated
	private func setup(_ dbHandle: OpaquePointer) throws {
		
		// this allows us to do simultaneous writes, by waiting whenever the DB is busy. It is by design to retry.
		sqlite3_busy_timeout(dbHandle, 80)
		
		// turn on Write Ahead Logging, may not be able to but that is ok - then we use the older slower method instead.
		if SQLITE_OK != sqlite3_exec(dbHandle, "PRAGMA journal_mode = WAL", nil, nil, nil) {
			print("AutoDB: Cannot enable Write Ahead Logging (upgrade SQLite")
		}
		
		// we don't need to assign a pointer to this function since we can only have one update_hook per handle.
		sqlite3_update_hook(dbHandle, { ctx, operation, dbName, tableName, rowid in
			
			guard let ctx, let operation = SQLiteOperation(rawValue: operation),
				  let tableName, let tableNameStr = String(cString: tableName, encoding: .utf8) else {
				return
			}
			let autoDB = Unmanaged<Database>.fromOpaque(ctx).takeUnretainedValue()
			Task {
				await autoDB.callListeners(tableNameStr, operation, rowid)
			}
			
		}, Unmanaged<Database>.passUnretained(self).toOpaque())
	}
	
	func reopen() throws {
		let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
		var handle: OpaquePointer? = nil
		var result: Int32 = SQLITE_ERROR
		var coordinatorError: NSError?
		let path = dbURL?.path() ?? ":memory:"
		
		if let dbURL {
			NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: dbURL, options: .forMerging, error: &coordinatorError) { _ in
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
		self.maxQueryVariableCount = Int(sqlite3_limit(dbHandle, SQLITE_LIMIT_VARIABLE_NUMBER, -1))
		try setup(dbHandle)
	}
	
	var gentleClose: Task<Void, Swift.Error>?
	var harshClose: Task<Void, Swift.Error>?
	public func close(_ token: AutoId? = nil, waitSec: Double = 10) async {
		gentleClose?.cancel()
		harshClose?.cancel()
		
		gentleClose = Task {
			let hasSemaphore = inTransaction || token != nil
			if hasSemaphore {
				await semaphore.wait(token: token)
			}
			defer { if hasSemaphore { Task { await semaphore.signal(token: token) } } }
			try Task.checkCancellation()
			closeDB()
		}
		
		// kill after some time?
		harshClose = Task {
			let date = Date().addingTimeInterval(waitSec * 2.0)
			try await Task.sleep(nanoseconds: 100_000_000 * UInt64(waitSec))
			try Task.checkCancellation()
			if Date.now > date {
				// we have gone too long to be relevant, perhaps was backgrounded and couldn't finish until restarted.
				return
			}
			if isClosed {
				return
			}
			// if there still is db-access (which it most likely isn't), we can't know that so must interrups to let go of handle.
			//print("Interrupting sqlite to force close")
			sqlite3_interrupt(dbHandle)	//https://www.sqlite.org/c3ref/interrupt.html
			closeDB()
		}
	}
	
	public func closeNow() async {
		gentleClose?.cancel()
		harshClose?.cancel()
		if isClosed {
			return
		}
		isClosed = true
		
		// interrubt any other long-running query or transaction, to let go of the handle. If there is no long-running query, this will do nothing
		sqlite3_interrupt(dbHandle)	//https://www.sqlite.org/c3ref/interrupt.html
		
		// we cannot close DB if already in transaction - statements must finalise first.
		let hasSemaphore = inTransaction
		if hasSemaphore {
			await semaphore.wait(token: nil)
		}
		defer { if hasSemaphore { Task { await semaphore.signal(token: nil) } } }
		
		closeDB()
	}
	
	private func closeDB() {
		isClosed = true
		for (_, statement) in cachedStatements {
			sqlite3_finalize(statement.handle)
		}
		cachedStatements.removeAll()
		// since there is no await between any usages of dbHandle and isClosed, we know that no task can access the db now.
		sqlite3_close(dbHandle)
	}
	public func open() async throws {
		harshClose?.cancel()
		gentleClose?.cancel()
		if isClosed {
			do {
				try reopen()
			} catch {
				print("Cannot reopen database: \(error)")
				throw error
			}
		}
		isClosed = false
	}
	
	public func switchDB(_ dbURL: URL?) async throws {
		self.dbURL = dbURL
		
		for (_, statement) in cachedStatements {
			sqlite3_finalize(statement.handle)
		}
		cachedStatements.removeAll()
		
		try await open()
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
	
	// MARK: - Query methods
	
	@discardableResult
	public func query(token: AutoId? = nil, _ queryString: String, _ arguments: [Sendable] = []) async throws -> [Row] {
		let values = try arguments.map {
			// we must cast or somehow find out which SQL-type each argument is!
			try SQLValue.fromAny($0)
		}
		return try await query(token: token, queryString, sqlArguments: values)
	}
	
	@discardableResult
	public func query(token: AutoId? = nil, _ query: String, sqlArguments: [SQLValue]?) async throws -> [Row] {
		// only take semaphore if in transaction - other times we can run queries in parallel (as much as being an actor allows)
		let hasSemaphore = inTransaction || token != nil
		if hasSemaphore {
			await semaphore.wait(token: token)
		}
		defer { if hasSemaphore { Task { await semaphore.signal(token: token) } } }
		if isClosed { throw Error.databaseIsClosed }
		
		let statement = try preparedStatement(query, sqlArguments ?? [])
		return try rowsByExecutingPreparedStatement(statement, from: query)
	}
	
	private func preparedStatement(_ query: String, _ sqlArguments: [SQLValue]) throws -> PreparedStatement {
		let statement = try preparedStatement(query)
		let statementHandle = statement.handle
		var idx = 1 // SQLite bind-parameter indices start at 1, not 0!
		for value in sqlArguments {
			try value.bind(database: self, statement: statementHandle, index: Int32(idx), for: query)
			idx += 1
		}
		return statement
	}
	
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
	
	private func debugPrint(_ statement: PreparedStatement, _ query: String, extra: String? = nil, file: StaticString = #file, function: StaticString = #function, line: UInt = #line) {
		if let cStr = sqlite3_expanded_sql(statement.handle), let expandedQuery = String(cString: cStr, encoding: .utf8) {
			AutoLog.debug("[AutoDB \(Unmanaged.passUnretained(self).toOpaque())] \(extra ?? "")\(expandedQuery)", file: file, function: function, line: line)
		} else {
			AutoLog.debug("[AutoDB \(Unmanaged.passUnretained(self).toOpaque())] \(query)", file: file, function: function, line: line)
		}
	}
	
	/// execute a prepared statement, returning the statement handle and the result code.
	private func executingPreparedStatement(_ statement: PreparedStatement, _ query: String) throws -> (OpaquePointer, Int32) {
		if debugPrintEveryQuery {
			debugPrint(statement, query)
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
			switch result {
				case SQLITE_CONSTRAINT:
					debugPrint(statement, query, extra: "Unique constraint failed for: ")
					sqlite3_reset(statementHandle)
					sqlite3_clear_bindings(statementHandle)
					throw Error.uniqueConstraintFailed
				default:
					sqlite3_reset(statementHandle)
					sqlite3_clear_bindings(statementHandle)
					throw Error.queryExecutionError(query: query, description: errorDesc(dbHandle))
			}
		}
		return (statementHandle, result)
	}
	
	private func rowsByExecutingPreparedStatement(_ statement: PreparedStatement, from query: String) throws -> [Row] {
		
		let (statementHandle, resultIn) = try executingPreparedStatement(statement, query)
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
		
		var result = resultIn
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
		
		// finalize handler
		if result != SQLITE_DONE { throw Error.queryExecutionError(query: query, description: errorDesc(dbHandle)) }
		guard sqlite3_reset(statementHandle) == SQLITE_OK, sqlite3_clear_bindings(statementHandle) == SQLITE_OK else {
			throw Error.queryExecutionError(query: query, description: errorDesc(dbHandle))
		}
		
		return rows
	}
	
	// MARK: - Execute methods, perform queries that do not return rows.
	
	/// Execute a query with parameters, returning amount of affected rows. Will throw an error if the query returns rows.
	@discardableResult
	public func execute(token: AutoId? = nil, _ queryString: String, _ arguments: [Sendable]?) async throws -> Int {
		let values = try arguments?.map {
			// we must cast or somehow find out which SQL-type each argument is!
			try SQLValue.fromAny($0)
		}
		return try await execute(token: token, queryString, sqlArguments: values ?? [])
	}
	
	/// Execute a query with parameters, returning amount of affected rows. Will throw an error if the query returns rows.
	@discardableResult
	public func execute(token: AutoId? = nil, _ query: String, sqlArguments: [SQLValue] = []) async throws -> Int {
		
		if sqlArguments.isEmpty {
			// no arguments, just run the query
			return try await execute(token: token, query)
		}
		
		// only take semaphore if in transaction - other times we can run queries in parallel (as much as being an actor allows)
		let hasSemaphore = inTransaction || token != nil
		if hasSemaphore {
			if debugPrintEveryQuery && token != nil {
				print("DB in transaction, will wait for semaphore before executing query: \(query)")
			}
			await semaphore.wait(token: token)
		}
		defer { if hasSemaphore { Task { await semaphore.signal(token: token) } } }
		if isClosed { throw Error.databaseIsClosed }
		
		let statement = try preparedStatement(query, sqlArguments)
		let (statementHandle, result) = try executingPreparedStatement(statement, query)
		
		// finalize handler
		if result != SQLITE_DONE {
			throw Error.queryExecutionError(query: query, description: errorDesc(dbHandle))
		}
		
		guard sqlite3_reset(statementHandle) == SQLITE_OK, sqlite3_clear_bindings(statementHandle) == SQLITE_OK else {
			throw Error.queryExecutionError(query: query, description: errorDesc(dbHandle))
		}
		let affectedRows = sqlite3_changes64(dbHandle)
		return Int(affectedRows)
	}
	
	/// Execute a query with no parameters returning  amount of affected rows. Will throw an error if the query returns rows.
	@discardableResult
	public func execute(token: AutoId? = nil, _ query: String) async throws -> Int {
		let hasSemaphore = inTransaction || token != nil
		if hasSemaphore {
			await semaphore.wait(token: token)
		}
		defer { if hasSemaphore { Task { await semaphore.signal(token: token) } } }
		if isClosed { throw Error.databaseIsClosed }
		
		if debugPrintEveryQuery {
			AutoLog.debug("[AutoDB \(Unmanaged.passUnretained(self).toOpaque())] \(query)")
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
		
		let affectedRows = sqlite3_changes64(dbHandle)
		return Int(affectedRows)
	}
	
	/// Run actions inside a transaction - any thrown error causes the DB to rollback (and the error is rethrown).
	/// ⚠️  Must use token for all db-access inside transactions, otherwise will deadlock. ⚠️
	/// Why? Since async/await and actors does not and can not deal with threads, there is no other way of knowing if you are holding the lock. We could send around the AutoDB and only allow access when locked - but that would basically be the same thing.
	public func transaction<R: Sendable>(_ action: (@Sendable (_ db: isolated Database, _ token: AutoId) async throws -> R) ) async throws -> R {
		
		let transactionID = AutoId.generateId()
		await semaphore.wait(token: transactionID)
		inTransaction = true	// now everyone must wait for semaphore
		defer {
			Task {
				// Set a token to wait for semaphores, this way we can call DB simultaneous with regular queries but wait when there are transactions.
				// also closing the DB will wait for a whole transaction.
				inTransaction = false
				
				// must be done in this order, waiting transactions may start un-ordered. Does that matter?
				await semaphore.signal(token: transactionID)
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
	private nonisolated(unsafe) var rowChangeObservers: [String: RowChangeObserver] = [:]
	public func rowChangeObserver(_ tableName: String) -> RowChangeObserver {
		if let listener = rowChangeObservers[tableName] {
			return listener
		}
		let listener = RowChangeObserver()
		rowChangeObservers[tableName] = listener
		return listener
	}
	
	private var debounce = [String: [SQLiteOperation: DebounceRowChange]]()
	private var debounceTime: UInt64 = .shortDelay
	
	// allow to listen to db-level changes of each row
	private func callListeners(_ tableName: String, _ operation: SQLiteOperation, _ rowId: sqlite_int64 ) async {
		
		if rowChangeObservers[tableName] != nil || tableChangeObservers[tableName] != nil {
			let id = UInt64(bitPattern: rowId)
			debounce[tableName]?[operation]?.debounceTask?.cancel()
			if debounce[tableName] == nil {
				debounce[tableName] = [:]
			}
			if debounce[tableName]?[operation] == nil {
				tableChangeObservers[tableName]?.append(operation)
				debounce[tableName]?[operation] = DebounceRowChange(parameters: RowChangeParameters(operation: operation, ids: [id]), debounceTask: nil)
			} else {
				debounce[tableName]?[operation]?.parameters.ids.append(id)
			}
			
			debounce[tableName]?[operation]?.debounceTask = Task {
				try await Task.sleep(nanoseconds: debounceTime)
				tableChangeObservers[tableName]?.append(operation)
				if let value = debounce[tableName]?[operation]?.parameters {
					debounce[tableName]?[operation] = nil
					rowChangeObservers[tableName]?.append(value)
				}
			}
		}
	}
	
	// allow the use of ChangeObservers elsewhere, access should not be restricted to this actor.
	private nonisolated(unsafe) var tableChangeObservers: [String: TableChangeObserver] = [:]
	
	public func tableChangeObserver(_ tableName: String) -> TableChangeObserver {
		if let listener = tableChangeObservers[tableName] {
			return listener
		}
		let listener = TableChangeObserver()
		tableChangeObservers[tableName] = listener
		return listener
	}
}
