# Fast text search as a property, FTSColumn

FTSColumn is available and intended for production use on platforms where SQLite FTS5 is present.

Current behavior:

- FTS tables are created lazily on first use.
- Updates, inserts, and deletes in the source table invalidate the indexed rows through triggers.
- Searches repopulate any missing rows before querying, so updated text becomes searchable without manual reindex steps.
- You can index a source column directly or provide a custom `FTSCallbackOwner` to build combined search text from multiple fields.

Current limitations:

- Automatic static search without specifying a column uses the first registered FTS column for that table.
- Custom ranking/highlighting APIs are not exposed yet; the current surface returns matching rows ordered by SQLite FTS rank.
