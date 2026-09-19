# Health Auto Export data contract

**Most of this is now verified against a real device** (Phase 1, HAE 1.1.0, 2026-09-18) rather than
inferred from documentation. Where measured behaviour contradicts the vendor's docs or their
reference server, the measurement wins and is marked *measured*.

Secondary sources: the vendor help centre (`help.healthyapps.dev`), the MCP server repo
(`HealthyApps/health-auto-export-mcp-server`), and their REST receiver
`HealthyApps/health-auto-export-server` (`server/src/models/Workout.ts`).

**The reference server has no license file.** Read it as documentation. Do not copy code from it.

## Units — read them, never assume *(measured)*

The docs' examples imply kcal and metres. The device sends neither:

| Field | Actual units |
|---|---|
| `activeEnergyBurned`, `totalEnergy`, `activeEnergy`, `basalEnergy` | **kJ** |
| `distance`, `cyclingDistance` | **km** |
| `speed`, `avgSpeed`, `maxSpeed` | **km/hr** |
| `elevationUp` / `elevationDown` | m |
| `heartRate`, `avgHeartRate`, `maxHeartRate` | **count/min** |
| `heartRateData[].Min/Avg/Max` | bpm |

Note that the same quantity uses different unit strings in different places (`count/min` vs `bpm`).
Always read `units` and convert to the canonical SI model. Unit preferences are user-configurable in
HAE, so these are not even stable across installs.

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

**Undocumented but present *(measured)*:** `heartRate`, `avgHeartRate`, `maxHeartRate`,
`basalEnergy`, `source`, `walkingAndRunningDistance`, `cyclingDistance`. Expect more to appear —
decode leniently.

Shapes that differ from what the docs and reference server suggest *(all measured)*:

- **`source` is an object at workout level**: `{"name": "WorkOutDoors", "identifier": "net.workoutdoors.workoutdoors"}`.
  Inside series samples it is a plain string (`"MaxWatch7"`). Decode both.
- **`location` is a string, not a coordinate**: `"Outdoor"` / `"Indoor"` — it's the HealthKit
  session location type. The workout's position comes only from `route`.
- **`heartRate` is a summary object**, `{"min": {...}, "avg": {...}, "max": {...}}`, each a
  `{qty, units}` pair — and `avgHeartRate` / `maxHeartRate` duplicate two of them at top level.
- **`heartRateData` samples carry no `source` key**, though the reference server's schema marks it
  required.
- `metadata` came back as `{}` even with `includeMetadata: true`.

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

Ten keys, all present in practice *(measured)*: `latitude`, `longitude`, `timestamp`, `altitude`,
`speed`, `course`, `horizontalAccuracy`, `verticalAccuracy`, `speedAccuracy`, `courseAccuracy`.
The last three are undocumented.

**Sampled at 1 Hz** — a 3.5-hour hike produced 12,645 points. Full fidelity; no downsampling needed
on the phone side, and plenty of reason to downsample before drawing.

Intervals are *not* uniform: median 1 s but individual gaps of 1800–3000 s appear where the workout
was paused. Never assume evenly spaced samples, and don't interpolate across a long gap — it would
draw a straight line through a pause.

## Heart rate

```json
{ "Min": 120, "Avg": 150, "Max": 175, "date": "...", "units": "bpm" }
```

Capitalised `Min`/`Avg`/`Max`. Bucketed aggregates whose bucket size is **controlled by
`metadataAggregation`** *(measured)*:

| `metadataAggregation` | Median HR interval | Samples, 35-min ride |
|---|---|---|
| `"minutes"` (default) | 60 s | 74 |
| `"seconds"` | **5 s** | 728 |

5 s is the Apple Watch's native workout sampling rate, so `"seconds"` is effectively lossless — the
earlier worry that TCX exports would carry coarse heart rate is resolved, provided we ask for it.
The knob is global: it re-buckets every series (`basalEnergy`, `stepCount`, `cyclingDistance`…), not
just heart rate, which is what makes it expensive.

`heartRateRecovery` is a separate series with the same shape, ~24 samples at 5 s, recorded after the
workout ends.

## Sync paths

All three require an HAE **Premium** subscription. Apple forbids health data access while the phone
is locked, so *every* path only moves data while the phone is unlocked. That is not a bug to work
around.

### MCP server over HTTP (Mac pulls) — the chosen path *(all measured)*

**The help pages describe the TCP transport's simplified `callTool` shape. The HTTP transport is
real MCP Streamable HTTP and that shape does not work on it.** A bare `callTool` gets
`-32600 Missing or invalid Mcp-Session-Id`. The actual sequence:

1. `POST http://{LAN_IP}:9000/mcp`, `method: "initialize"`, params
   `{protocolVersion: "2025-06-18", capabilities: {}, clientInfo: {...}}`.
   Headers: `Content-Type: application/json`, `Accept: application/json, text/event-stream`,
   `Authorization: Bearer <token>`.
2. Read **`Mcp-Session-Id`** from the *response headers* and send it on every later request.
3. `POST` the `notifications/initialized` notification.
4. `tools/list` and `tools/call` — the standard MCP method names, not `listTools`/`callTool`.

`tools/list` **works**, contrary to the docs; the "non-functional" note applies to the TCP
transport. Use it to resolve the contract instead of guessing tool names. Server identifies itself
as `Health Auto Export` version `1.1.0`, whose tools are `get_workouts`, `get_health_metrics`,
`get_symptoms`, `get_medications`, `get_ecg`, and so on.

`get_workouts` schema, with defaults straight from `tools/list`:

| Argument | Type | Default | Notes |
|---|---|---|---|
| `start`, `end` | string | — | required; `yyyy-MM-dd HH:mm:ss Z` |
| `includeRoutes` | bool | **`false`** | must be asked for explicitly |
| `includeMetadata` | bool | `true` | all the time-series, plus `avgHeartRate`/`maxHeartRate`/`isIndoor`/`location` |
| `metadataAggregation` | string | `"minutes"` | `"seconds"` for native-fidelity heart rate |

Tool results arrive MCP-wrapped: `result.content[0].text` is a **JSON string** that must be parsed
again to reach the `{"data": {"workouts": [...]}}` envelope.

**Cost is query time on the phone, not bytes.** Roughly **2.3–2.5 seconds per workout**, essentially
independent of whether routes or metadata are requested:

| Request | Workouts | Payload | Time |
|---|---|---|---|
| summary only (`includeMetadata: false`) | 101 | 0.12 MiB | 234 s |
| metadata, minutes, no routes | 16 | 0.73 MiB | 41 s |
| metadata, minutes, **with routes** | 16 | 16.4 MiB | 49 s |
| metadata, **seconds**, with routes — one 3.5 h hike | 1 | 14.0 MiB | 18 s |

So: ~46 KB per workout of minute-resolution metadata, ~1 MB per workout of route, ~1.5 MB per
workout of second-resolution metadata. A single long workout tops out around 14 MiB, comfortably
within one response — no chunking needed *within* a workout.

Do **not** use `includeMetadata: false` to make list sync cheap. It saves little time (time scales
with workout count regardless) and it drops `avgHeartRate`, `maxHeartRate`, `isIndoor` and
`location`, all of which the list view wants.

**Therefore, fetch in two tiers** — this also answers the old question of when detail is fetched:

- **List sync:** `includeRoutes: false`, `metadataAggregation: "minutes"` over a date window.
- **Detail / export:** re-request that one workout with a narrow `start`/`end` window,
  `includeRoutes: true`, `metadataAggregation: "seconds"`.

**The server stops when HAE is backgrounded**, and at ~2.4 s/workout a multi-year backfill is tens
of minutes of foreground time. Sync must be explicit, chunked by month, resumable, and show
progress.

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
