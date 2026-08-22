//
//  Deprecated.swift
//  AutoDB
//
//  Created by Olof Andersson-Thorén on 2026-08-22.
//
//  Deprecated token-taking variants of the public API. The transaction token is now carried
//  automatically as a task-local (SemaphoreToken.current), so the explicit parameters are no
//  longer needed - each wrapper binds the given token and forwards to the clean version.
//  Explicit tokens still win over an ambient one. Delete this whole file in the next major version.

// MARK: - Model

public extension Model {

	@available(*, deprecated, message: "The transaction token is carried automatically (SemaphoreToken.current) - remove the token argument, see 'Removing explicit tokens' in Documentation.md")
	static func create(token: AutoId?, _ id: AutoId? = nil) -> Self {
		// legacy behavior: an explicitly passed token doubles as the default id
		SemaphoreToken.$current.withValue(token ?? SemaphoreToken.current) {
			create(id ?? token)
		}
	}

	@available(*, deprecated, message: "The transaction token is carried automatically (SemaphoreToken.current) - remove the token argument, see 'Removing explicit tokens' in Documentation.md")
	static func create(token: AutoId?, _ id: AutoId? = nil) async -> Self {
		// legacy behavior: an explicitly passed token doubles as the default id
		await SemaphoreToken.$current.withValue(token ?? SemaphoreToken.current) {
			await create(id ?? token)
		}
	}

	@available(*, deprecated, message: "The transaction token is carried automatically (SemaphoreToken.current) - use transaction { db in ... } and remove all token arguments, see 'Removing explicit tokens' in Documentation.md")
	static func transaction<R: Sendable>(_ action: (@Sendable (_ db: isolated Database, _ token: AutoId) async throws -> R)) async throws -> R {
		try await db().transaction(token: nil, action)
	}

	@available(*, deprecated, message: "The transaction token is carried automatically (SemaphoreToken.current) - remove the token argument, see 'Removing explicit tokens' in Documentation.md")
	static func fetchId(token: AutoId?, _ id: AutoId, _ typeID: ObjectIdentifier? = nil) async throws -> Self {
		try await SemaphoreToken.$current.withValue(token ?? SemaphoreToken.current) {
			try await fetchId(id, typeID)
		}
	}

	@available(*, deprecated, message: "The transaction token is carried automatically (SemaphoreToken.current) - remove the token argument, see 'Removing explicit tokens' in Documentation.md")
	static func fetchIds(token: AutoId?, _ ids: [AutoId], _ identifier: ObjectIdentifier? = nil) async throws -> [Self] where Self: AnyObject {
		try await SemaphoreToken.$current.withValue(token ?? SemaphoreToken.current) {
			try await fetchIds(ids, identifier)
		}
	}

	@available(*, deprecated, message: "The transaction token is carried automatically (SemaphoreToken.current) - remove the token argument, see 'Removing explicit tokens' in Documentation.md")
	static func fetchQuery(token: AutoId?, _ query: String = "", _ arguments: [Sendable]? = nil, sqlArguments: [SQLValue]? = nil) async throws -> [Self] where Self: AnyObject {
		try await SemaphoreToken.$current.withValue(token ?? SemaphoreToken.current) {
			try await fetchQuery(query, arguments, sqlArguments: sqlArguments)
		}
	}

	@available(*, deprecated, message: "The transaction token is carried automatically (SemaphoreToken.current) - remove the token argument, see 'Removing explicit tokens' in Documentation.md")
	@discardableResult
	static func query(token: AutoId?, _ query: String = "", _ arguments: [Sendable]? = nil) async throws -> [Row] {
		try await SemaphoreToken.$current.withValue(token ?? SemaphoreToken.current) {
			try await self.query(query, arguments)
		}
	}

	@available(*, deprecated, message: "The transaction token is carried automatically (SemaphoreToken.current) - remove the token argument, see 'Removing explicit tokens' in Documentation.md")
	@discardableResult
	static func query(token: AutoId?, _ query: String = "", sqlArguments: [SQLValue]? = nil) async throws -> [Row] {
		try await SemaphoreToken.$current.withValue(token ?? SemaphoreToken.current) {
			try await self.query(query, sqlArguments: sqlArguments)
		}
	}

	@available(*, deprecated, message: "The transaction token is carried automatically (SemaphoreToken.current) - remove the token argument, see 'Removing explicit tokens' in Documentation.md")
	static func execute(token: AutoId?, _ query: String = "", _ arguments: [Sendable]? = nil) async throws {
		try await SemaphoreToken.$current.withValue(token ?? SemaphoreToken.current) {
			try await execute(query, arguments)
		}
	}

	@available(*, deprecated, message: "The transaction token is carried automatically (SemaphoreToken.current) - remove the token argument, see 'Removing explicit tokens' in Documentation.md")
	static func execute(token: AutoId?, _ query: String = "", sqlArguments: [SQLValue]? = nil) async throws {
		try await SemaphoreToken.$current.withValue(token ?? SemaphoreToken.current) {
			try await execute(query, sqlArguments: sqlArguments)
		}
	}

	@available(*, deprecated, message: "The transaction token is carried automatically (SemaphoreToken.current) - remove the token argument, see 'Removing explicit tokens' in Documentation.md")
	static func executeAffectedRows(token: AutoId?, _ query: String = "", sqlArguments: [SQLValue]? = nil) async throws -> Int {
		try await SemaphoreToken.$current.withValue(token ?? SemaphoreToken.current) {
			try await executeAffectedRows(query, sqlArguments: sqlArguments)
		}
	}

	@available(*, deprecated, message: "The transaction token is carried automatically (SemaphoreToken.current) - remove the token argument, see 'Removing explicit tokens' in Documentation.md")
	@discardableResult
	static func queryNT(token: AutoId?, _ query: String = "", arguments: [Sendable]? = nil) async -> [Row]? {
		await SemaphoreToken.$current.withValue(token ?? SemaphoreToken.current) {
			await queryNT(query, arguments: arguments)
		}
	}

	@available(*, deprecated, message: "The transaction token is carried automatically (SemaphoreToken.current) - remove the token argument, see 'Removing explicit tokens' in Documentation.md")
	static func valueQuery<Val: SQLColumnWrappable>(token: AutoId?, _ query: String = "", _ arguments: [Sendable]? = nil) async throws -> Val {
		try await SemaphoreToken.$current.withValue(token ?? SemaphoreToken.current) {
			try await valueQuery(query, arguments)
		}
	}

	@available(*, deprecated, message: "The transaction token is carried automatically (SemaphoreToken.current) - remove the token argument, see 'Removing explicit tokens' in Documentation.md")
	static func groupConcatQuery<Val: SQLColumnWrappable>(token: AutoId?, _ query: String = "", _ arguments: [Sendable]? = nil) async throws -> [Val] {
		try await SemaphoreToken.$current.withValue(token ?? SemaphoreToken.current) {
			try await groupConcatQuery(query, arguments)
		}
	}

	@available(*, deprecated, message: "The transaction token is carried automatically (SemaphoreToken.current) - remove the token argument, see 'Removing explicit tokens' in Documentation.md")
	func save(token: AutoId?) {
		Task.detached {
			// explicit tokens deliberately cross into detached work - preserve that
			try? await SemaphoreToken.$current.withValue(token) {
				try await self.save()
			}
		}
	}

	@available(*, deprecated, message: "The transaction token is carried automatically (SemaphoreToken.current) - remove the token argument, see 'Removing explicit tokens' in Documentation.md")
	func save(token: AutoId?) async throws {
		try await SemaphoreToken.$current.withValue(token ?? SemaphoreToken.current) {
			try await save()
		}
	}

	@available(*, deprecated, message: "The transaction token is carried automatically (SemaphoreToken.current) - remove the token argument, see 'Removing explicit tokens' in Documentation.md")
	static func saveChanges(token: AutoId?) async throws {
		try await SemaphoreToken.$current.withValue(token ?? SemaphoreToken.current) {
			try await saveChanges()
		}
	}

	@available(*, deprecated, message: "The transaction token is carried automatically (SemaphoreToken.current) - remove the token argument, see 'Removing explicit tokens' in Documentation.md")
	static func saveChangesDetached(token: AutoId?) {
		Task.detached {
			try? await SemaphoreToken.$current.withValue(token) {
				try await AutoDBManager.shared.saveChanges(Self.self)
			}
		}
	}

	@available(*, deprecated, message: "The transaction token is carried automatically (SemaphoreToken.current) - remove the token argument, see 'Removing explicit tokens' in Documentation.md")
	static func saveAllChanges(token: AutoId?) async throws {
		try await SemaphoreToken.$current.withValue(token ?? SemaphoreToken.current) {
			try await saveAllChanges()
		}
	}

	@available(*, deprecated, message: "The transaction token is carried automatically (SemaphoreToken.current) - remove the token argument, see 'Removing explicit tokens' in Documentation.md")
	static func saveAllChangesDetacted(token: AutoId?) {
		Task.detached {
			try? await SemaphoreToken.$current.withValue(token) {
				try await AutoDBManager.shared.saveAllChanges()
			}
		}
	}

	@available(*, deprecated, message: "The transaction token is carried automatically (SemaphoreToken.current) - remove the token argument, see 'Removing explicit tokens' in Documentation.md")
	static func saveList(token: AutoId?, _ objects: [Self]) async throws {
		try await SemaphoreToken.$current.withValue(token ?? SemaphoreToken.current) {
			try await saveList(objects)
		}
	}

	@available(*, deprecated, message: "The transaction token is carried automatically (SemaphoreToken.current) - remove the token argument, see 'Removing explicit tokens' in Documentation.md")
	func delete(token: AutoId?) {
		Task.detached {
			try? await SemaphoreToken.$current.withValue(token) {
				try await self.delete()
			}
		}
	}

	@available(*, deprecated, message: "The transaction token is carried automatically (SemaphoreToken.current) - remove the token argument, see 'Removing explicit tokens' in Documentation.md")
	func delete(token: AutoId?) async throws {
		try await SemaphoreToken.$current.withValue(token ?? SemaphoreToken.current) {
			try await delete()
		}
	}

	@available(*, deprecated, message: "The transaction token is carried automatically (SemaphoreToken.current) - remove the token argument, see 'Removing explicit tokens' in Documentation.md")
	static func deleteIds(token: AutoId?, _ ids: [AutoId]) async throws {
		try await SemaphoreToken.$current.withValue(token ?? SemaphoreToken.current) {
			try await deleteIds(ids)
		}
	}
}

public extension Collection where Element: Model {

	@available(*, deprecated, message: "The transaction token is carried automatically (SemaphoreToken.current) - remove the token argument, see 'Removing explicit tokens' in Documentation.md")
	func save(token: AutoId?) where Self: Sendable {
		Task.detached {
			try? await SemaphoreToken.$current.withValue(token) {
				try await self.save()
			}
		}
	}

	@available(*, deprecated, message: "The transaction token is carried automatically (SemaphoreToken.current) - remove the token argument, see 'Removing explicit tokens' in Documentation.md")
	func save(token: AutoId?) async throws {
		try await SemaphoreToken.$current.withValue(token ?? SemaphoreToken.current) {
			try await save()
		}
	}

	@available(*, deprecated, message: "The transaction token is carried automatically (SemaphoreToken.current) - remove the token argument, see 'Removing explicit tokens' in Documentation.md")
	func delete(token: AutoId?) async throws {
		try await SemaphoreToken.$current.withValue(token ?? SemaphoreToken.current) {
			try await delete()
		}
	}
}

// MARK: - Table

public extension Table {

	@available(*, deprecated, message: "The transaction token is carried automatically (SemaphoreToken.current) - remove the token argument, see 'Removing explicit tokens' in Documentation.md")
	static func create(token: AutoId?, _ id: AutoId? = nil) async -> Self {
		await SemaphoreToken.$current.withValue(token ?? SemaphoreToken.current) {
			await create(id)
		}
	}

	@available(*, deprecated, message: "The transaction token is carried automatically (SemaphoreToken.current) - remove the token argument, see 'Removing explicit tokens' in Documentation.md")
	static func create(token: AutoId?, _ id: AutoId? = nil) -> Self {
		SemaphoreToken.$current.withValue(token ?? SemaphoreToken.current) {
			create(id)
		}
	}

	@available(*, deprecated, message: "The transaction token is carried automatically (SemaphoreToken.current) - use transaction { db in ... } and remove all token arguments, see 'Removing explicit tokens' in Documentation.md")
	static func transaction<R: Sendable>(_ action: (@Sendable (_ db: isolated Database, _ token: AutoId) async throws -> R)) async throws -> R {
		try await db().transaction(token: nil, action)
	}

	@available(*, deprecated, message: "The transaction token is carried automatically (SemaphoreToken.current) - remove the token argument, see 'Removing explicit tokens' in Documentation.md")
	static func fetchId(token: AutoId?, _ id: AutoId, _ identifier: ObjectIdentifier? = nil) async throws -> Self {
		try await SemaphoreToken.$current.withValue(token ?? SemaphoreToken.current) {
			try await fetchId(id, identifier)
		}
	}

	@available(*, deprecated, message: "The transaction token is carried automatically (SemaphoreToken.current) - remove the token argument, see 'Removing explicit tokens' in Documentation.md")
	static func fetchIds(token: AutoId?, _ ids: [AutoId], _ identifier: ObjectIdentifier? = nil) async throws -> [Self] {
		try await SemaphoreToken.$current.withValue(token ?? SemaphoreToken.current) {
			try await fetchIds(ids, identifier)
		}
	}

	@available(*, deprecated, message: "The transaction token is carried automatically (SemaphoreToken.current) - remove the token argument, see 'Removing explicit tokens' in Documentation.md")
	static func fetchQuery(token: AutoId?, _ query: String = "", _ arguments: [Sendable]? = nil, sqlArguments: [SQLValue]? = nil) async throws -> [Self] {
		try await SemaphoreToken.$current.withValue(token ?? SemaphoreToken.current) {
			try await fetchQuery(query, arguments, sqlArguments: sqlArguments)
		}
	}

	@available(*, deprecated, message: "The transaction token is carried automatically (SemaphoreToken.current) - remove the token argument, see 'Removing explicit tokens' in Documentation.md")
	@discardableResult
	static func query(token: AutoId?, _ query: String = "", _ arguments: [Sendable]? = nil) async throws -> [Row] {
		try await SemaphoreToken.$current.withValue(token ?? SemaphoreToken.current) {
			try await self.query(query, arguments)
		}
	}

	@available(*, deprecated, message: "The transaction token is carried automatically (SemaphoreToken.current) - remove the token argument, see 'Removing explicit tokens' in Documentation.md")
	@discardableResult
	static func query(token: AutoId?, _ query: String = "", sqlArguments: [SQLValue]? = nil) async throws -> [Row] {
		try await SemaphoreToken.$current.withValue(token ?? SemaphoreToken.current) {
			try await self.query(query, sqlArguments: sqlArguments)
		}
	}

	@available(*, deprecated, message: "The transaction token is carried automatically (SemaphoreToken.current) - remove the token argument, see 'Removing explicit tokens' in Documentation.md")
	static func execute(token: AutoId?, _ query: String = "", _ arguments: [Sendable]? = nil, sqlArguments: [SQLValue]? = nil) async throws {
		try await SemaphoreToken.$current.withValue(token ?? SemaphoreToken.current) {
			try await execute(query, arguments, sqlArguments: sqlArguments)
		}
	}

	@available(*, deprecated, message: "The transaction token is carried automatically (SemaphoreToken.current) - remove the token argument, see 'Removing explicit tokens' in Documentation.md")
	@discardableResult
	static func executeAffectedRows(token: AutoId?, _ query: String = "", _ arguments: [Sendable]? = nil, sqlArguments: [SQLValue]? = nil) async throws -> Int {
		try await SemaphoreToken.$current.withValue(token ?? SemaphoreToken.current) {
			try await executeAffectedRows(query, arguments, sqlArguments: sqlArguments)
		}
	}

	@available(*, deprecated, message: "The transaction token is carried automatically (SemaphoreToken.current) - remove the token argument, see 'Removing explicit tokens' in Documentation.md")
	@discardableResult
	static func queryNT(token: AutoId?, _ query: String = "", arguments: [Sendable]? = nil) async -> [Row]? {
		await SemaphoreToken.$current.withValue(token ?? SemaphoreToken.current) {
			await queryNT(query, arguments: arguments)
		}
	}

	@available(*, deprecated, message: "The transaction token is carried automatically (SemaphoreToken.current) - remove the token argument, see 'Removing explicit tokens' in Documentation.md")
	static func valueQuery<Val: SQLColumnWrappable>(token: AutoId?, _ query: String = "", _ arguments: [Sendable]? = nil, sqlArguments: [SQLValue]? = nil) async throws -> Val {
		try await SemaphoreToken.$current.withValue(token ?? SemaphoreToken.current) {
			try await valueQuery(query, arguments, sqlArguments: sqlArguments)
		}
	}

	@available(*, deprecated, message: "The transaction token is carried automatically (SemaphoreToken.current) - remove the token argument, see 'Removing explicit tokens' in Documentation.md")
	static func groupConcatQuery<Val: SQLColumnWrappable>(token: AutoId?, _ query: String = "", _ arguments: [Sendable]? = nil) async throws -> [Val] {
		try await SemaphoreToken.$current.withValue(token ?? SemaphoreToken.current) {
			try await groupConcatQuery(query, arguments)
		}
	}

	@available(*, deprecated, message: "The transaction token is carried automatically (SemaphoreToken.current) - remove the token argument, see 'Removing explicit tokens' in Documentation.md")
	func save(token: AutoId?) {
		Task.detached {
			// explicit tokens deliberately cross into detached work - preserve that
			try? await SemaphoreToken.$current.withValue(token) {
				try await self.save()
			}
		}
	}

	@available(*, deprecated, message: "The transaction token is carried automatically (SemaphoreToken.current) - remove the token argument, see 'Removing explicit tokens' in Documentation.md")
	func save(token: AutoId?) async throws {
		try await SemaphoreToken.$current.withValue(token ?? SemaphoreToken.current) {
			try await save()
		}
	}

	@available(*, deprecated, message: "The transaction token is carried automatically (SemaphoreToken.current) - remove the token argument, see 'Removing explicit tokens' in Documentation.md")
	static func saveList(token: AutoId?, _ objects: [Self]) async throws {
		try await SemaphoreToken.$current.withValue(token ?? SemaphoreToken.current) {
			try await saveList(objects)
		}
	}

	@available(*, deprecated, message: "The transaction token is carried automatically (SemaphoreToken.current) - remove the token argument, see 'Removing explicit tokens' in Documentation.md")
	static func saveList(token: AutoId?, _ objects: [Self], onlyUpdated: Bool?) async throws {
		try await SemaphoreToken.$current.withValue(token ?? SemaphoreToken.current) {
			try await saveList(objects, onlyUpdated: onlyUpdated)
		}
	}

	@available(*, deprecated, message: "The transaction token is carried automatically (SemaphoreToken.current) - remove the token argument, see 'Removing explicit tokens' in Documentation.md")
	func delete(token: AutoId?) {
		Task.detached {
			try? await SemaphoreToken.$current.withValue(token) {
				try await self.delete()
			}
		}
	}

	@available(*, deprecated, message: "The transaction token is carried automatically (SemaphoreToken.current) - remove the token argument, see 'Removing explicit tokens' in Documentation.md")
	func delete(token: AutoId?) async throws {
		try await SemaphoreToken.$current.withValue(token ?? SemaphoreToken.current) {
			try await delete()
		}
	}

	@available(*, deprecated, message: "The transaction token is carried automatically (SemaphoreToken.current) - remove the token argument, see 'Removing explicit tokens' in Documentation.md")
	static func deleteIds(token: AutoId?, _ ids: [AutoId]) async throws {
		try await SemaphoreToken.$current.withValue(token ?? SemaphoreToken.current) {
			try await deleteIds(ids)
		}
	}
}

public extension Collection where Element: Table {

	@available(*, deprecated, message: "The transaction token is carried automatically (SemaphoreToken.current) - remove the token argument, see 'Removing explicit tokens' in Documentation.md")
	func save(token: AutoId?) where Self: Sendable {
		Task.detached {
			try? await SemaphoreToken.$current.withValue(token) {
				try await self.save()
			}
		}
	}

	@available(*, deprecated, message: "The transaction token is carried automatically (SemaphoreToken.current) - remove the token argument, see 'Removing explicit tokens' in Documentation.md")
	func save(token: AutoId?) async throws {
		try await SemaphoreToken.$current.withValue(token ?? SemaphoreToken.current) {
			try await save()
		}
	}
}

// MARK: - ManyRelation

extension ManyRelation {

	@available(*, deprecated, message: "The transaction token is carried automatically (SemaphoreToken.current) - remove the token argument, see 'Removing explicit tokens' in Documentation.md")
	@discardableResult
	public func firstFetch(_ token: AutoId?) async throws -> [AutoType] {
		try await SemaphoreToken.$current.withValue(token ?? SemaphoreToken.current) {
			try await firstFetch()
		}
	}
}

// MARK: - AutoDBManager

extension AutoDBManager {

	@available(*, deprecated, message: "The transaction token is carried automatically (SemaphoreToken.current) - remove the token argument, see 'Removing explicit tokens' in Documentation.md")
	@discardableResult
	public nonisolated func query<T: Table>(token: AutoId?, _ classType: T.Type, _ query: String, _ arguments: [Sendable]? = nil, sqlArguments: [SQLValue]? = nil) async throws -> [Row] {
		try await SemaphoreToken.$current.withValue(token ?? SemaphoreToken.current) {
			try await self.query(classType, query, arguments, sqlArguments: sqlArguments)
		}
	}

	@available(*, deprecated, message: "The transaction token is carried automatically (SemaphoreToken.current) - remove the token argument, see 'Removing explicit tokens' in Documentation.md")
	@discardableResult
	public nonisolated func execute<T: Table>(token: AutoId?, _ classType: T.Type, _ query: String, _ arguments: [Sendable]? = nil, sqlArguments: [SQLValue]? = nil) async throws -> Int {
		try await SemaphoreToken.$current.withValue(token ?? SemaphoreToken.current) {
			try await self.execute(classType, query, arguments, sqlArguments: sqlArguments)
		}
	}

	@available(*, deprecated, message: "The transaction token is carried automatically (SemaphoreToken.current) - remove the token argument, see 'Removing explicit tokens' in Documentation.md")
	public nonisolated func valueQuery<T: Table, Val: SQLColumnWrappable>(token: AutoId?, _ classType: T.Type, _ query: String = "", _ arguments: [Sendable]? = nil, sqlArguments: [SQLValue]? = nil) async throws -> Val? {
		try await SemaphoreToken.$current.withValue(token ?? SemaphoreToken.current) {
			try await self.valueQuery(classType, query, arguments, sqlArguments: sqlArguments)
		}
	}

	@available(*, deprecated, message: "The transaction token is carried automatically (SemaphoreToken.current) - remove the token argument, see 'Removing explicit tokens' in Documentation.md")
	public nonisolated func groupConcatQuery<T: Table, Val: SQLColumnWrappable>(token: AutoId?, _ classType: T.Type, _ query: String = "", _ arguments: [Sendable]? = nil) async throws -> [Val] {
		try await SemaphoreToken.$current.withValue(token ?? SemaphoreToken.current) {
			try await self.groupConcatQuery(classType, query, arguments)
		}
	}

	@available(*, deprecated, message: "The transaction token is carried automatically (SemaphoreToken.current) - use transaction { db in ... } and remove all token arguments, see 'Removing explicit tokens' in Documentation.md")
	public func transaction<T: Table, R: Sendable>(_ classType: T.Type, _ action: (@Sendable (_ db: isolated Database, _ token: AutoId) async throws -> R)) async throws -> R {
		let database = try await setupDB(classType)
		return try await database.transaction(token: nil, action)
	}

	@available(*, deprecated, message: "The transaction token is carried automatically (SemaphoreToken.current) - remove the token argument, see 'Removing explicit tokens' in Documentation.md")
	public nonisolated func delete(token: AutoId?, _ ids: [AutoId], _ typeID: ObjectIdentifier) async throws {
		try await SemaphoreToken.$current.withValue(token ?? SemaphoreToken.current) {
			try await delete(ids, typeID)
		}
	}

	@available(*, deprecated, message: "The transaction token is carried automatically (SemaphoreToken.current) - remove the token argument, see 'Removing explicit tokens' in Documentation.md")
	public nonisolated func saveAllChanges(token: AutoId?) async throws {
		try await SemaphoreToken.$current.withValue(token ?? SemaphoreToken.current) {
			try await saveAllChanges()
		}
	}

	@available(*, deprecated, message: "The transaction token is carried automatically (SemaphoreToken.current) - remove the token argument, see 'Removing explicit tokens' in Documentation.md")
	public nonisolated func saveChanges<T: Model>(token: AutoId?, _ class: T) async throws {
		try await SemaphoreToken.$current.withValue(token ?? SemaphoreToken.current) {
			try await saveChanges(T.self)
		}
	}

	@available(*, deprecated, message: "The transaction token is carried automatically (SemaphoreToken.current) - remove the token argument, see 'Removing explicit tokens' in Documentation.md")
	public nonisolated func saveChanges<T: Model>(token: AutoId?, _ classType: T.Type) async throws {
		try await SemaphoreToken.$current.withValue(token ?? SemaphoreToken.current) {
			try await saveChanges(classType)
		}
	}
}
