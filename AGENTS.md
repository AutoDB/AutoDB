# AGENTS.md

## General

This is a library making persistance automatic and hazzle free, read README.md for more details.

New code should be built to run on all platforms; Linux, Android, mac and iOS, so avoid or use #if os(iOS) for things that are iOS only. iOS is the main plaform. If something isn't Android ready, consider it a TODO.

Use tabs instead of spaces, so the user can decide on tab-length. A large portion of coders prefers 2 spaces per tab, while the majority prefers 4 spaces - we don't need to dictate how wide a tab is for them.

Formatting is done by the pre-commit hook in `.githooks`. If `git config core.hooksPath` is not `.githooks`, enable it with `git config core.hooksPath .githooks`.

## Testing

Always use Swift testing when writing unit tests.

Every test suite gets its own databases with `@Suite(.autoDB)` from the AutoDBTesting product (`import AutoDBTesting`). Each suite's manager keeps its files in `Caches/AutoDBTests/<suite>/`, so suites never see each other's rows and can run in parallel, even when they use the same Table types. Tables use the module-wide `.regular` settings in `Tests/AutoDBTests/TestHelpers.swift`; declare `autoDBSettings` only for a table that must live in another file, like `.cache`. Use `AutoDBManager.current`, not `.shared`, inside tests.
