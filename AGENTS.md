# AGENTS.md

## General

This is a library making persistance automatic and hazzle free, read README.md for more details.

New code should be built to run on all platforms; Linux, Android, mac and iOS, so avoid or use #if os(iOS) for things that are iOS only. iOS is the main plaform. If something isn't Android ready, consider it a TODO.

Use tabs instead of spaces, so the user can decide on tab-length. A large portion of coders prefers 2 spaces per tab, while the majority prefers 4 spaces - we don't need to dictate how wide a tab is for them.

After editing a file run swift format, run:

```bash
git diff --name-only --diff-filter=ACMR | grep '\.swift$' | xargs swift-format -i --configuration .swift-format
```
