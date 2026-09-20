# Health Auto Export data contract

**Most of this is now verified against a real device** (Phase 1, HAE 1.1.0, 2026-09-18) rather than
inferred from documentation. Where measured behaviour contradicts the vendor's docs or their
reference server, the measurement wins and is marked *measured*.

Secondary sources: the vendor help centre (`help.healthyapps.dev`), the MCP server repo
(`HealthyApps/health-auto-export-mcp-server`), and their REST receiver
`HealthyApps/health-auto-export-server` (`server/src/models/Workout.ts`).

**The reference server has no license file.** Read it as documentation. Do not copy code from it.

## Units — read them, never assume *(measured, with a controlled experiment)*

Every scalar is a `{qty, units}` pair. **The unit strings are user preferences and change under
you**, so the canonical model must normalise to SI at decode time and must never persist the
incoming unit string as truth.

Observed directly: **two** preferences were changed together — energy set to kcal, and
**"Localize Units" turned on** — between two otherwise identical `get_workouts` calls twelve
minutes apart, against the same workout.

| Field | before | after |
|---|---|---|
| `activeEnergyBurned`, `totalEnergy`, `activeEnergy`, `basalEnergy` | `kJ` | `kcal` |
| `heartRate.*`, `avgHeartRate`, `maxHeartRate`, `heartRateData[]` | `count/min` | `bpm` |
| `stepCount[]` | `count` | `steps` |
| `stepCadence[]` | `count/min` | `count/min` (unchanged) |
| `distance`, `cyclingDistance` | `km` | `km` |
| `speed`, `avgSpeed`, `maxSpeed` | `km/hr` | `km/hr` |
| `elevationUp`, `elevationDown` | `m` | `m` |

Because two settings moved at once, this does **not** isolate which one caused which change. What
it does establish:

1. **There is a "Localize Units" toggle that rewrites unit spellings wholesale**, beyond the
   per-quantity unit pickers. The `count/min`→`bpm` and `count`→`steps` changes are most likely
   its doing — those look like HealthKit-canonical strings being swapped for display-friendly ones
   — while `kJ`→`kcal` could come from either setting. Untested either way.
2. **The remapping is not uniform.** `stepCadence` stayed `count/min` while heart rate became
   `bpm`, in the same payload. So even under localization you cannot assume that identically-shaped
   quantities share a spelling.
3. **One quantity has several spellings meaning exactly the same thing.** The decoder needs a
   synonym table per dimension, not merely a units-aware parse:

   | Dimension | Supported |
   |---|---|
   | energy | `kJ`, `kcal` |
   | length | `km`, `m` |
   | speed | `km/hr` |
   | rate | `count/min`, `bpm` |
   | count | `count`, `steps` |

   **Metric only — imperial is deliberately out of scope** (decided 2026-09-18; the user doesn't
   need it). `mi`, `ft`, `mi/hr` and friends must therefore hit the same hard failure as any other
   unknown unit. That is the point: if HAE's locale ever flips, sync stops with a clear error
   instead of quietly reporting miles as kilometres.

An unrecognised unit must be a loud decode failure, never a silent pass-through: a workout showing
1122 "calories" because `kJ` was read as `kcal` is a plausible-looking wrong number, which is the
worst kind.

**Conversion is lossless, so no HAE setting is preferable to another** *(measured)*. The same
workout exported under both settings gave `1121.8603941990377 kJ` and `268.13106935923463 kcal`;
dividing by 4.184 reproduces the second exactly, delta 0. Unaffected fields are bit-identical,
including full-precision values like `avgHeartRate = 140.04751754400314`. HAE emits raw doubles and
converts exactly rather than rounding to a display value. There is therefore nothing to gain by
asking the user to configure HAE a particular way — normalise whatever arrives.

Both vocabularies are covered by fixtures —
`MaxActCore/Tests/Fixtures/mcp-workouts-seconds.json` (kcal/bpm/steps) and
`mcp-workouts-kJ-countmin.json` (kJ/count-min/count).

> **Corrected 2026-09-18.** An earlier version of this file claimed heart rate used `count/min` in
> some fields and `bpm` in others *within one payload*. That was wrong: it compared two captures
> taken either side of the preference change. Within a single capture the spelling is consistent.

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

**No path is hands-off.** Sync to Mac is often described as "automatic", but it too needs Health
Auto Export open on the phone — it is automatic in the sense that the Mac doesn't drive it, not in
the sense that it runs unattended. Treat "the user must have HAE open on an unlocked phone" as a
fixed constraint of this whole design, and build sync UI that says so plainly rather than implying
background magic.

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

- **The real path is the app's own ubiquity container, not iCloud Drive proper** *(measured)*:
  `~/Library/Mobile Documents/iCloud~com~ifunography~HealthExport/Documents/`. The docs' "iCloud
  Drive → Auto Export" is how Finder and the Files app *present* that container — there is no
  `Auto Export` folder under `com~apple~CloudDocs`. (`ifunography` is HAE's developer.)
- Consequence for a sandboxed app: this is **another app's** container, so we cannot read it from
  our own ubiquity entitlement. It requires the user to pick the folder in an open panel and a
  retained security-scoped bookmark. Finder does show it under iCloud Drive as "Auto Export", so
  the user can navigate to it, but it's a real extra step this path carries.
- Expected layout below that: `AutoSync/{Health Metrics,Workouts,Routes}`.
- Layout *(measured)*: `AutoSync/Workouts/<code>_<yyyyMMdd>_<UUID>.hae`,
  `AutoSync/Routes/<workout-UUID>.hae`, `AutoSync/HealthMetrics/<metric_name>/<yyyyMMdd>.hae` —
  metrics are one file per metric per day.
- The folder needs Finder's *Keep Downloaded* or the files are dataless cloud placeholders.

#### The `.hae` container — reverse engineered *(measured)*

Two layouts, both LZFSE, which macOS decodes natively via
`(data as NSData).decompressed(using: .lzfse)`:

```
HealthMetrics dailies:   "HAE1" magic, then repeating [uint32 big-endian length][LZFSE block]
Workouts and Routes:     a bare LZFSE stream (starts "bvx2"), possibly several concatenated
```

An LZFSE stream ends with the 4-byte marker `bvx$`, which is how to split concatenated streams.
Each decodes to UTF-8 JSON. Typical ratios: a route went 201 KB → 626 KB, a workout 3.6 KB → 21 KB.

**This is not the REST/MCP schema.** It is a different, richer one, and self-describing:
`schema: {"name": "workout-cache", "version": 2, "minimumReaderVersion": 2}` (routes say
`workout-route-cache`). Check `minimumReaderVersion` before parsing and refuse politely if it
exceeds what we support.

Workout file highlights:

| Field | Note |
|---|---|
| `measurements` | The one to use. `{value, unit, origin}` per quantity in **SI** (`kJ`, `m`, `m/s`, `s`), with provenance: `workout`, `metadata`, `routeDerived`, `sampleOverlapEstimate`. |
| top-level `activeEnergy`, `avgSpeed`, … | Display-unit duplicates of the above (`268.13` kcal vs `measurements.activeEnergy` = `1121.86` kJ). Ignore them. |
| `activity` | `{code: "cycling", platformType: 13}` — **the HKWorkoutActivityType raw value**, unlike MCP's display name. |
| `intervals` | `activities`, `laps`, `segments`, `splits`, `events`. Splits carry per-km `distance`/`heartRateMinimum`/`activeEnergy` with `qty`/`units`/`origin`/`sampleCount`. Events are `pause`/`motionPaused`/`motionResumed` with `typeCode` — these explain the multi-minute gaps in route timestamps. |
| `sourceTimeZone` | IANA identifier (`America/Creston`). MCP only ever gives a UTC offset. |
| `heartRateStatistics` | `{average, minimum, maximum, unit}` only — **no heart-rate time series.** |
| `producer`, `source` | App version/build/platform, and the recording app. |

Route file: `{id, workoutID, activityCode, name, schema, units, locations[]}` where `units` declares
`{speed: "m/s", course: "deg", altitude: "m", accuracy: "m"}` once for the file. Location keys are
`latitude`, `longitude`, `elevation`, `hAcc`, `vAcc`, `speed`, `time` — note the **different names
from MCP** (`elevation` not `altitude`, `hAcc` not `horizontalAccuracy`) and **no `course`,
`courseAccuracy` or `speedAccuracy`**, despite `units` mentioning course. Point count matched MCP
exactly for the same workout (2922), so there is no loss of route fidelity.

**All timestamps are Apple-epoch doubles** (seconds since 2001-01-01 UTC), not the
`yyyy-MM-dd HH:mm:ss Z` strings the other transports use. Use `Date(timeIntervalSinceReferenceDate:)`.

**Known gap:** no per-workout heart-rate series. It would have to be joined from
`HealthMetrics/heart_rate/<date>.hae` and sliced by the workout's time range — unverified, because
that folder had not synced yet.

- Sandbox cost: this is **another app's** ubiquity container, so it needs a user-selected folder
  and a retained security-scoped bookmark; we cannot reach it with our own iCloud entitlement.

### Manual export (the backfill path)

Not an automation, and the only path with no 30-second window and no foreground requirement. JSON
(one file, all types) plus optional per-workout GPX route files, any date range, shared out via the
Files app. This is how years of history get imported in one pass, whichever live path wins.
