# AGENTS.md

## General

This is a library making persistance automatic and hazzle free, read README.md for more details.

New code should be built to run on all platforms; Linux, Android, mac and iOS, so avoid or use #if os(iOS) for things that are iOS only. iOS is the main plaform. If something isn't Android ready, consider it a TODO.

Use tabs instead of spaces, so the user can decide on tab-length. A large portion of coders prefers 2 spaces per tab, while the majority prefers 4 spaces - we don't need to dictate how wide a tab is for them.

Formatting is done by the pre-commit hook in `.githooks`. If `git config core.hooksPath` is not `.githooks`, enable it with `git config core.hooksPath .githooks`.

## Testing

Always use Swift testing when writing unit tests.

Every test suite has its own database file in the cache folder, see `TestDatabase` in `Tests/AutoDBTests/TestHelpers.swift`. This keeps suites from touching each other's tables, so they can run in parallel. When adding a suite, add a file to `TestDatabase` and point every Table the suite uses at it with `static let autoDBSettings = TestDatabase.mySuite`. Never share a Table type between suites - give each suite its own types.
