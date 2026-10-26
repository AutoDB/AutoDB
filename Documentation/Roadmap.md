# Roadmap

## 1.0 scope

The 1.0 release target is:

- Swift Package only
- Apple-first support
- the current package deployment floor
- no cross-platform support promise
- no older non-Observation `RelationQuery` implementation

## Support matrix

| Surface | Support |
| --- | --- |
| Package platforms | macOS 14+, iOS 17+, tvOS 17+, watchOS 10+ |
| Tested regularly | macOS and iOS |
| `RelationQuery` | macOS 14+, iOS 17+, tvOS 17+, watchOS 10+ |
| Cross-platform targets | Out of scope for 1.0 |

## Stable in 1.0

- `Table` and `Model`
- automatic migrations
- cache-backed model identity
- uniqueness constraints
- batched saving
- transactions
- `ManyRelation` and `OneRelation`
- `FTSColumn`
- `RelationQuery` on supported Observation-capable OS versions

## 1.1 scope

- Encryption, probably using SQLCipher
- Android support