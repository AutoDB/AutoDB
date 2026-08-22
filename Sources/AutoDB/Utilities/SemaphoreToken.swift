//
//  SemaphoreToken.swift
//  AutoDB
//
//  Created by Olof Andersson-Thorén on 2026-08-22.
//

/// Ambient re-entry token for Database/encoder semaphores.
/// Bound by `Database.transaction` for the duration of the transaction body, so code inside
/// transactions and migrations no longer needs to forward `token:` explicitly - inner calls pick
/// it up from the task and re-enter the lock instead of deadlocking.
/// Explicit `token:` parameters always win; this is only the fallback when they are nil.
/// Note that task-locals flow into `Task { }` but deliberately NOT into `Task.detached` -
/// a detached task inside a transaction still waits for it to finish, just like before.
public enum SemaphoreToken {
	@TaskLocal public static var current: AutoId?

	/// Run `body` with no ambient token. Use at the top of stored/delayed/fire-and-forget
	/// Tasks that must keep the waiting semantics (nil-token queries wait for open transactions
	/// to finish) instead of silently joining a transaction inherited from the spawning task.
	public static func detached<R>(_ body: nonisolated(nonsending) () async throws -> R) async rethrows -> R {
		try await $current.withValue(nil, operation: body)
	}
}
