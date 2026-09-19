# Health Auto Export data contract

Sources: the vendor help centre (`help.healthyapps.dev`), the MCP server repo
(`HealthyApps/health-auto-export-mcp-server`), and — most reliably — the vendor's own REST receiver
`HealthyApps/health-auto-export-server` (`server/src/models/Workout.ts`). The last of these is the
authoritative shape; where it and the help pages disagree, trust the code.

**The reference server has no license file.** Read it as documentation. Do not copy code from it.

## Envelope

Every JSON export, over every transport, is wrapped the same way:

```json
{ "data": { "metrics": [ ... ], "workouts": [ ... ] } }
```

Both keys are optional. A push that contains only metrics is normal and must not be treated as an
error.

## Workout object (format v2)

**Required — these five are the only fields guaranteed present:**
`id`, `name`, `start`, `end`, `duration`.

**Optional:** `distance`, `activeEnergyBurned`, `activeEnergy`, `totalEnergy`, `intensity`,
`heartRateData`, `heartRateRecovery`, `stepCount`, `stepCadence`, `flightsClimbed`, `speed`,
`avgSpeed`, `maxSpeed`, `elevationUp`, `elevationDown`, `temperature`, `humidity`, `location`,
`isIndoor`, `route`, `metadata`, plus swimming (`lapLength`, `strokeStyle`, `swolfScore`,
`salinity`, `totalSwimmingStrokeCount`, `swimCadence`) and cycling (`cyclingCadence`,
`cyclingDistance`, `cyclingPower`, `cyclingSpeed`) fields.

Treat **everything except the five required fields as optional**, regardless of what the docs
suggest. The vendor's own Mongo schema marks `activeEnergyBurned` required while their TypeScript
interface marks it optional — the docs are not a reliable guide to presence.

Optional fields are **absent**, not null, when unavailable. Unknown keys must decode without
throwing, so an HAE update can't brick sync.

## Measurements

Scalar quantities are objects, not numbers:

```json
{ "qty": 12.5, "units": "km", "date": "...", "source": "Apple Watch" }
```

Never assume the unit — read `units` and convert. The app's canonical model stores SI (metres,
seconds, kilocalories).

## Dates

Format is `yyyy-MM-dd HH:mm:ss Z`, e.g. `2024-02-06 07:00:00 -0800`. The offset is always present.
Parse with a `DateFormatter` pinned to `en_US_POSIX` and this format — never with a fixed time zone,
or workouts recorded while travelling land on the wrong day. `MaxActCore.haeDateFormat` holds the
string; `HAEDateFormatTests` guards the behaviour.

## Route points

More fields than the help pages list. From `ILocation`:

`latitude`, `longitude`, `timestamp` (required), then `altitude`, `speed`, `course`,
`horizontalAccuracy`, `verticalAccuracy`, `speedAccuracy`, `courseAccuracy` — the last three are
undocumented but real.

## Heart rate

```json
{ "Min": 120, "Avg": 150, "Max": 175, "date": "...", "units": "bpm", "source": "Apple Watch" }
```

Capitalised `Min`/`Avg`/`Max`. **Bucketed aggregates, not raw samples** — see the main skill file.
`heartRateRecovery` has the same shape and is a separate series.

## Sync paths

All three require an HAE **Premium** subscription. Apple forbids health data access while the phone
is locked, so *every* path only moves data while the phone is unlocked. That is not a bug to work
around.

### MCP / TCP server (Mac pulls)

- HTTP (recommended): `POST http://{LAN_IP}:9000/mcp` with `Authorization: Bearer <token>`. Token
  and IP are shown on HAE's Server screen. HTTPS is available but requires trusting an
  app-generated local CA.
- Raw TCP: `{LAN_IP}:9000`, unauthenticated and unencrypted, one request/response per connection.
- JSON-RPC 2.0: `{"jsonrpc":"2.0","id":"1","method":"callTool","params":{"name":"<tool>", ...}}`.
- `listTools` is documented as **non-functional** — you cannot discover the contract at runtime that
  way. Probe by trying tool names.
- Tool names vary by contract version: v1.1.0 uses `get_*` (`get_workouts`), v1.0.0 uses bare names
  (`workouts`). Try the newer first and fall back.
- `workouts` args: `start`, `end` (required), `includeMetadata`, `includeRoutes`,
  `metadataAggregation`. Other tools: `health_metrics`, `symptoms`, `state_of_mind`, `medications`,
  `cycle_tracking`, `ecg`, `heart_notifications`.
- **The server stops when HAE is backgrounded.** Sync must be an explicit, resumable, foreground
  operation with visible progress — chunk by month so an interruption loses one chunk.

### REST API (phone pushes)

- The phone POSTs the envelope above to a URL you configure, with arbitrary custom headers for auth.
- The reference server listens on `POST /api/data` and sets a **200 MB** body limit — bodies are
  genuinely large. A naive hand-rolled HTTP parser is not sufficient, and the Network framework has
  **no HTTP server protocol**, so this path means either real HTTP parsing or an SPM dependency.
- iOS background tasks get roughly 30 seconds, which makes multi-year backfill impractical here.
- The reference server upserts workouts and routes into separate collections, both keyed on workout
  `id` — the same split (summary row + series blob) MaxAct uses.

### Sync to Mac (iCloud `.hae` files)

- `~/Library/Mobile Documents/com~apple~CloudDocs/Auto Export/AutoSync/{Health Metrics,Workouts,Routes}`.
- Naming: metrics `yyyyMMdd.hae`; workouts `[name]_[date]_[id].hae`; routes named by workout id.
- The format is **proprietary and undocumented**, and no reference implementation exists — the
  vendor's server repo does not read these files.
- The folder needs Finder's *Keep Downloaded* or the files are dataless cloud placeholders.
- A sandboxed app needs user-selected read access plus a security-scoped bookmark.

### Manual export (the backfill path)

Not an automation, and the only path with no 30-second window and no foreground requirement. JSON
(one file, all types) plus optional per-workout GPX route files, any date range, shared out via the
Files app. This is how years of history get imported in one pass, whichever live path wins.
