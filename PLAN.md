# MaxAct — Build Plan

A fast, native macOS 26 app for browsing Apple Health workouts exported by **Health Auto Export**,
with batch upload to Strava.

**Status:** Phases 0–3 complete. Sync is **MCP over HTTP**, two passes, weekly chunks, resumable
(§2), verified against the real phone; persistence is in place and measured at corpus scale.
Phase 4 (list UI) is next — the first phase with anything on screen.
**Last updated:** 2026-09-20.

> **Working on this project?** Read `.claude/skills/maxact-development/` first. It carries the
> Health Auto Export data contract, the Xcode tooling limits we hit, and the Strava API facts —
> the things that cost research to establish and aren't visible in the code.

---

## 1. Context

`OLD_PLAN.md` assumed a companion iOS app reading HealthKit directly and shipping workouts to the
Mac over Bonjour + TLS-PSK. That is dead: HealthKit is unavailable on macOS, and the Apple Developer
Program cost to provision the HealthKit entitlement on a companion app isn't worth it for a personal
tool. Everything in that plan downstream of the transport (models, SwiftData store, Table UI, GPX
writer, Strava upload, geocoding) is still sound and is carried forward here.

The replacement data source is **Health Auto Export** (HAE) on the iPhone, which already has
HealthKit access and three ways to get data off the phone. That collapses two app targets into one
and removes ~2 phases of work (HealthKit reading, custom TLS-PSK transport), at the cost of a new
uncertainty: which HAE export path actually carries full-fidelity data, including GPS routes and
heart-rate series. That question is settled empirically in Phase 1, not from documentation.

**Intended outcome:** one macOS app. It browses every workout in a sortable, filterable,
multi-selectable table with route thumbnails and Strava sync state; a detail view shows the full
map, heart-rate chart and splits; and batch actions upload selections to Strava under correct rate
limiting.

### Research findings that shape the plan

| Path | Mechanism | Route + HR? | Cost / risk |
|---|---|---|---|
| **REST API** | Phone POSTs JSON to a URL you own | **Yes — confirmed against the vendor's own reference server** (see below): `route?: ILocation[]` and `heartRateData?: IHeartRate[]` are first-class fields | Mac must run an HTTP listener. The Network framework has **no** HTTP server protocol, so this means hand-rolling HTTP/1.1 over `NetworkListener` or taking an SPM dependency — and the reference server sets a **200 MB** body limit, so bodies are genuinely large and a naive parser won't do. iOS background tasks get ~30 s, so backfill is awkward. |
| **MCP / TCP server** | Mac is the client; JSON-RPC 2.0 on port 9000, `http://{LAN_IP}:9000/mcp` + `Authorization: Bearer <token>` (HTTPS available via an app-generated local CA) | `workouts` tool takes `start`, `end`, `includeRoutes`, `includeMetadata`, `metadataAggregation` — but the docs never confirm route/HR arrays actually come back | Mac controls the date range, so backfill is chunked requests and re-sync is idempotent. But HAE must be **foregrounded** on the phone for the whole sync, `listTools` is documented as non-functional, and tool names differ by contract version (v1.1.0 `get_*` vs v1.0.0 `workouts`) — needs runtime probing. |
| **Sync to Mac** | iCloud Drive → `Auto Export/AutoSync/{Health Metrics,Workouts,Routes}` | Has a dedicated `Routes/` folder, so probably yes | Files are a **proprietary, undocumented `.hae` format**. Nothing exists in this Mac's iCloud Drive yet (no `Auto Export` folder), so it is entirely unverified — and the vendor's public server repo does **not** read `.hae`, so no reference implementation exists to crib from. Also needs `Keep Downloaded` on the folder or the files are cloud placeholders. |

### The vendor's reference server — what it settles, and what it doesn't

[`HealthyApps/health-auto-export-server`](https://github.com/HealthyApps/health-auto-export-server)
(TypeScript, Express + MongoDB + Grafana; last pushed 2025-12-15) turns out to be a **REST receiver**,
not a `.hae` reader. It does not touch iCloud Drive at all, so the `.hae` probe in Phase 1 stands
unchanged. What it does give us:

- **The exact push contract.** `POST /api/data` with an `api-key:` header (their convention, not
  HAE's — HAE sends whatever custom headers you configure), body
  `{"data": {"metrics": [...], "workouts": [...]}}`, `200` on success and `207` on partial failure.
- **The authoritative workout shape**, from `server/src/models/Workout.ts`. Required: `id`, `name`,
  `start`, `end`, `duration`. Optional: `distance`, `activeEnergyBurned`, `activeEnergy`,
  `heartRateData`, `heartRateRecovery`, `stepCount`, `temperature`, `humidity`, `intensity`,
  `route`. Their Mongo schema marks `activeEnergyBurned` required while the TypeScript interface
  marks it optional — so **treat everything except the five required fields as optional**, whatever
  the docs imply.
- **Richer route points than the docs list.** `ILocation` carries `latitude`, `longitude`,
  `timestamp`, `course`, `courseAccuracy`, `speed`, `speedAccuracy`, `altitude`,
  `verticalAccuracy`, `horizontalAccuracy`. The help pages omit the three accuracy fields.
- **A fidelity problem worth knowing about early.** `IHeartRate` is `{Min, Avg, Max, date, units,
  source}` — a **bucketed aggregate per timestamp, not a raw beat-by-beat series**. Sample density
  is therefore a function of the export's time-grouping setting (the MCP `workouts` tool's
  `metadataAggregation` argument and the REST automation's grouping control are almost certainly the
  same knob). This directly bounds how good the heart-rate track in an uploaded TCX can be, so
  Phase 1 must measure the achievable interval, not just presence.
- **Idempotency confirmation.** They upsert workouts and routes separately, both keyed on the
  workout `id`, with routes in their own collection — the same split (summary row + series blob,
  keyed on `id`) that Phase 3 plans.

The repo has **no license file**. Read it as documentation and as a Phase 1 test harness; don't copy
code from it.

Prerequisites confirmed present: **HAE Premium** (required for all three paths) and a **Strava API
application** (client ID + secret). No Apple Developer team — builds stay ad-hoc signed.

Strava, as of 2026: overall limit 200 req/15 min and 2000/day; a *separate* read limit of
100 req/15 min and 1000/day, and upload-status polls are GETs that count against the **read**
bucket. New apps are in single-player mode (own account only), which is exactly the use case.

---

## 2. Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Targets | One macOS app target (`MaxAct2`, display name **MaxAct**) + `MaxActCore` local SwiftPM package + unit and UI test bundles | No iOS companion is needed any more. The package keeps model/ingest/format/Strava logic testable with `swift test`, without booting the app. |
| Minimum OS | macOS 26.0 | Liquid Glass, `MKReverseGeocodingRequest`, Swift-native `Network` API. The current `MACOSX_DEPLOYMENT_TARGET = 26.6.2` is an inherited template artifact, not a choice. |
| Primary sync | **MCP over HTTP, chunked and resumable** (decided 2026-09-20 after Phase 1) | All three paths carry full route and heart-rate fidelity, so the decision came down to bulk import of ~7 years / ~2,867 workouts. `.hae` is the richer schema but its backfill cannot be forced and was observed to stall after two days' worth. Manual export would have been fastest but writes multi-GB files to a phone with little free space. MCP is the only path the Mac can drive to completion, and it shares the v2 JSON schema with manual export, so one decoder covers both. |
| Sync shape | **Two passes.** Pass 1: list sync over weekly windows, no routes, `metadataAggregation: "minutes"`. Pass 2: per-workout detail with routes and `"seconds"`, fetched lazily. | Pass 1 is the only blocking cost: ~1.9 h of foregrounded phone for 7 years, 0.13 GB. Fetching every route up front would double that and add 2.9 GB, to populate thumbnails for rows the user may never scroll to. |
| Resumability | Persisted sync frontier: which windows are listed, which workouts have detail. Weekly chunks. | Requests are independent date windows with no server cursor, and per-request overhead is negligible against the 2.4 s/workout cost, so fine chunks are nearly free: an interruption loses ~20 s. Small chunks also cap peak memory on an old phone, which builds each response in memory (16 MB for a 14-day windowed request with routes). Upsert on the stable workout UUID makes a re-fetched window idempotent. |
| Backfill | HAE **manual export** (JSON + GPX) imported from a file/folder, regardless of which live path wins | Manual export has no 30-second background window and no foreground requirement. Years of history land in one pass. |
| Units | Decode **metric only** (`kJ`/`kcal`, `km`, `m`, `km/hr`, `count/min`/`bpm`, `count`/`steps`), normalise to SI, and treat any other unit — including imperial — as a hard decode failure | HAE's unit strings follow its preferences and are not stable, so decoding must be units-driven regardless. Imperial is explicitly out of scope: the user doesn't need it, and a loud failure beats silently reading `mi` as `km`. If HAE's locale ever flips, sync stops with a clear error rather than showing wrong distances. |
| Canonical model | Own `Workout` value types in `MaxActCore`, decoded *from* HAE's shape | HAE identifies activity type by display name (`"Running"`), not `HKWorkoutActivityType` raw values — so `ActivityKind` must carry `.other(String)` rather than an integer fallback. |
| Persistence | SwiftData for summary rows + local state; route/HR series as compressed JSON blobs on disk | A 4-hour ride is thousands of points and must not sit in the table's query path. |
| Row thumbnails | Pre-rendered, disk-cached `MKMapSnapshotter` images of a simplified polyline — never a live `Map` per row | N live `Map` views in a table is the single easiest way to make this app slow. |
| Strava upload format | **TCX only** | Carries GPS, heart rate, laps, distance and calories in one schema, and still produces a meaningful file for indoor workouts with no route. One writer, one golden-file suite. GPX/FIT explicitly out of scope for v1. |
| Strava credentials | User's own client ID + secret, in the Keychain | Already held; a bundled secret is extractable and shares one rate-limit budget. |
| Concurrency | Swift 6 language mode, `SWIFT_STRICT_CONCURRENCY = complete`, `async`/`await`, no Combine | Project code-style guidance. `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` and `SWIFT_APPROACHABLE_CONCURRENCY = YES` are already set and stay. |

### Out of scope for v1
Writing to HealthKit; non-workout health metrics (sleep, body mass — the model shouldn't preclude
them); GPX/FIT export; Strava *download*; syncing between Macs.

---

## 3. Architecture

```
MaxAct2.xcodeproj
├── MaxAct2              macOS app target (macOS 26+)   ← exists, currently multiplatform template
├── MaxAct2Tests         Swift Testing                  ← to add
├── MaxAct2UITests       XCUIAutomation                 ← to add
└── MaxActCore/          local SwiftPM package          ← to add
    ├── Model/           Workout, RoutePoint, HeartRateSample, Lap, ActivityKind
    ├── Ingest/          WorkoutSource protocol + HAE decoders (MCP, REST, file)
    ├── Formats/         TCXWriter
    └── Strava/          OAuth, upload client, rate-limit budget
```

Data flow:

```
iPhone / Health Auto Export
   └─ (winning path from Phase 1) ─→ HAEWorkoutPayload  [Ingest]
                                        ↓ decode
                                     Workout             [Model]
                                        ↓
                          WorkoutStore (SwiftData rows + blob files)
                                        ↓
                      Table + detail views ─→ TCXWriter ─→ Strava upload
```

### Canonical model sketch (`MaxActCore/Model`)

```swift
public struct Workout: Identifiable, Hashable, Sendable {
    public let id: String              // HAE workout id — stable, our dedupe key
    public let kind: ActivityKind
    public let start: Date
    public let end: Date
    public let duration: TimeInterval
    public let distanceMeters: Double?
    public let activeEnergyKilocalories: Double?
    public let elevationUpMeters: Double?
    public let averageHeartRate: Double?
    public let maximumHeartRate: Double?
    public let isIndoor: Bool?
    public let sourceName: String?
    public let startCoordinate: Coordinate?   // coarsened to ~1 km, see Phase 6
    public let hasRoute: Bool
}

public struct WorkoutSeries: Sendable {       // the heavy part, stored as a blob
    public let route: [RoutePoint]
    public let heartRate: [HeartRateSample]   // bucketed min/avg/max, NOT raw beats — see §1
    public let laps: [Lap]
}

public struct RoutePoint: Sendable {
    public let coordinate: Coordinate
    public let timestamp: Date
    public let altitudeMeters: Double?
    public let speedMetersPerSecond: Double?
    public let course: Double?
    public let horizontalAccuracy: Double?
    public let verticalAccuracy: Double?      // these three accuracy fields are undocumented
    public let speedAccuracy: Double?         // but present in the vendor's reference server
    public let courseAccuracy: Double?
}

public struct HeartRateSample: Sendable {
    public let date: Date
    public let min: Double, avg: Double, max: Double
    public let source: String?
}

public enum ActivityKind: Hashable, Sendable {
    case running, cycling, walking, swimming, hiking, strengthTraining /* … */
    case other(String)                        // HAE sends display names, not HK raw values
}
```

### Ingest boundary

```swift
public protocol WorkoutSource: Sendable {
    /// Pull sources fetch a window; push sources ignore the interval and yield as data arrives.
    func workouts(in interval: DateInterval) -> AsyncThrowingStream<IngestedWorkout, any Error>
}
```

Implementations: `MCPWorkoutSource`, `RESTReceiverSource`, `HAEFileSource` (manual-export JSON/GPX
and, if Phase 1 says it's readable, `.hae`). All of them emit the same `IngestedWorkout`
(`Workout` + optional `WorkoutSeries`), so Phases 3–8 are written once and are indifferent to which
path won.

HAE decoding details that must be handled in one place: measurements arrive as `{ "qty": …,
"units": … }`; dates are `yyyy-MM-dd HH:mm:ss Z`; optional fields are *absent*, not null; the
envelope is `{"data": {"workouts": [...], "metrics": [...]}}`; and unknown keys must decode without
throwing so an HAE update can't brick sync.

---

## 4. Phases

Every phase ends with a green build. Don't start the next one on a broken build.

### Phase 0 — Project foundation

The target is still the raw multiplatform template. Fix the settings that are wrong by default:

| Setting | Now | To |
|---|---|---|
| `SUPPORTED_PLATFORMS` | `iphoneos iphonesimulator macosx xros xrsimulator` | `macosx` |
| `SDKROOT` | `auto` | `macosx` |
| `TARGETED_DEVICE_FAMILY` | `1,2,7` | (clear) |
| `MACOSX_DEPLOYMENT_TARGET` | `26.6.2` | `26.0` |
| `SWIFT_VERSION` | `5.0` | `6.0` |
| `SWIFT_STRICT_CONCURRENCY` | `minimal` | `complete` |
| `PRODUCT_BUNDLE_IDENTIFIER` | `devplaceholder.MTG0HGP4.MaxAct2` | `com.swiatlowski.MaxAct` |
| `ENABLE_OUTGOING_NETWORK_CONNECTIONS` | `NO` | `YES` |
| `ENABLE_USER_SELECTED_FILES` | `readonly` | `readwrite` |
| `INFOPLIST_KEY_NSLocalNetworkUsageDescription` | — | set (LAN sync) |

The bundle ID must be settled **now** and never change: Keychain items are keyed to it.

Also: rename `MyApp.swift` → `MaxActApp.swift` (`struct MaxActApp: App`), strip the `#Playground`
and placeholder body from `ContentView.swift`, add `MaxActCore` as a local package and link it,
add `MaxAct2Tests` (Swift Testing) and `MaxAct2UITests`, add a `.gitignore` for build output and
`.swiftpm`, and copy this plan into the repo as `PLAN.md`, deleting `OLD_PLAN.md`.

**Done.** All of the above is applied and verified: `BuildProject` is clean, `swift test` in
`MaxActCore/` passes (2 tests), and `RunAllTests` passes 3 of 3 across both app test bundles.

Notes on what the tooling could and couldn't do, so this isn't rediscovered later:

- The two "needs Xcode's UI" test-wiring steps that `OLD_PLAN.md` predicted were both avoidable.
  The autocreated scheme really does run **zero** tests, but writing a shared scheme by hand at
  `MaxAct2.xcodeproj/xcshareddata/xcschemes/MaxAct2.xcscheme` with an explicit `TestAction` /
  `Testables` fixes it, and has the side benefit of being checked in rather than living in
  `xcuserdata`. `TEST_HOST` and `BUNDLE_LOADER` are ordinary writable build settings; the app test
  bundle asserts `@testable import MaxAct2` resolves, so a regression in that wiring fails loudly
  instead of silently running nothing.
- `TEST_TARGET_NAME` is **not** writable through the build-settings tooling (it's rejected as an
  unknown setting), so `MaxAct2UITests` has no implicit target application. Worked around in code:
  the UI test launches `XCUIApplication(bundleIdentifier: "com.swiatlowski.MaxAct")`. The scheme's
  build action builds the app for testing, so the bundle is present when the test runs.
- There is no MCP tool to add a local package to a project, so linking `MaxActCore` was the one
  genuine Xcode UI step (File → Add Package Dependencies… → Add Local). Done, and verified by
  `XCLocalSwiftPackageReference` plus a `MaxActCore in Frameworks` entry in the project file —
  a package can be referenced without being linked, which type-checks and then fails at link time.
- `MACOSX_DEPLOYMENT_TARGET` is still `26.6.2` at the **project** level (all three targets override
  it to `26.0`). The build-settings tooling is target-scoped only and `project.pbxproj` must not be
  hand-edited, so this is left as-is. Harmless today; fix it in Xcode if a new target ever inherits
  it.
- `MaxActCore`'s manifest needs `swift-tools-version: 6.2`, not 6.0 — `.macOS(.v26)` doesn't exist
  before 6.2.

### Phase 1 — Sync evaluation spike *(throwaway code; delete when done)*

Score each path against: does it carry full `route[]` **and** heart-rate series; **what sample
interval the heart-rate and route series actually come back at, and whether that's configurable**
(the series are bucketed aggregates, so this bounds TCX quality — see §1); payload size and wall
time for one long (4 h+) activity and for a one-month window; how hands-off it is; whether
multi-year backfill is practical; and implementation cost on the Mac.

- **A. MCP over HTTP — done 2026-09-18. PASSES, and is the presumptive winner.** Full results in
  `.claude/skills/maxact-development/references/hae-data-contract.md`. Headlines: routes at 1 Hz
  with ten fields per point; heart rate at a 5 s median once `metadataAggregation: "seconds"` is
  requested; everything the list view needs is present. The transport is real MCP Streamable HTTP
  (session handshake, `tools/list` / `tools/call`), not the simplified `callTool` the help pages
  describe — and `tools/list` works fine. Cost is ~2.4 s of phone time per workout, near enough
  independent of payload size, which is what makes a two-tier fetch (cheap list sync, per-workout
  detail on demand) the right shape.
- **C. `.hae` / Sync to Mac — done 2026-09-20. The format is READABLE, and the schema is in some
  ways better than MCP's.** `.hae` is LZFSE: workouts and routes are bare streams, metric dailies
  use a `HAE1` + `[uint32 length][block]` container. macOS decodes LZFSE natively, so no dependency
  is needed. Full details in the skill reference; `Spikes/hae_decode.swift.txt` is a working decoder.

  What it has that MCP doesn't: `measurements` with explicit **SI** units and provenance, the
  **HKWorkoutActivityType raw code** instead of a display name, **laps/splits/pause events**,
  an **IANA `sourceTimeZone`**, and a **versioned `schema`** with `minimumReaderVersion`. Route
  fidelity is identical (2922 points, same as MCP, for the same workout) at a fifth of the bytes.

  What it lacks: **no per-workout heart-rate series** — only `heartRateStatistics` and per-split
  summaries. It would have to be joined from `HealthMetrics/heart_rate/<date>.hae` and sliced by
  workout time range. **Unverified**, because that metric had not synced when tested. Route points
  also drop `course`/`courseAccuracy`/`speedAccuracy`, which MCP provides.

  Also: iCloud delivery is slow and partial. A manual one-week sync produced 4 workouts and 20 of
  the metric folders (alphabetically `active_energy`→`calcium`) and then stalled. And being another
  app's ubiquity container, it needs a user-selected folder plus a security-scoped bookmark.

- **B. REST push — deliberately not run.** Probe A settled that MCP carries everything, and probe C
  settled the schema comparison. B's only distinct value was hands-off incremental capture, and
  once it emerged that *no* path runs without HAE open on an unlocked phone, that value largely
  disappeared — while its cost (an HTTP listener in a sandboxed app, with no HTTP server protocol
  in the Network framework) stayed high. Not run, and not planned. `Spikes/hae_capture.py` is kept
  until the spike directory is deleted, in case this is revisited.

**Decision — 2026-09-20.** Primary sync is **MCP over HTTP**, in two passes, chunked weekly and
resumable; see §2. The deciding factor was the ~2,867-workout bulk import, not fidelity — all three
paths carry full route and heart-rate detail.

- `.hae` **rejected for v1, not on quality.** It is the better schema (SI units with provenance,
  HealthKit activity codes, laps/splits/pause events, IANA time zone, a fifth of the bytes) and its
  data is exact wherever it lands. But its backfill cannot be forced, and was measured stalling
  after delivering two days of workouts while metrics went back a full week. Seven years arriving
  on HAE's own schedule is not a migration path. It would also be a *third* schema: the v2 JSON
  decoder is needed regardless, so `.hae` adds a decoder that serves only the steady state MCP
  already covers in seconds a day. Worth revisiting once the detail view exists and can use laps
  and pause events.
- **Manual export rejected** on a hard constraint: it writes multi-GB files to a phone with little
  free space. This removed what had looked like the obvious bulk-import answer.
- **Operational note if Sync to Mac is left on:** with all 113 metrics selected it projects to
  **6.4 GB** of iCloud over 7 years, dominated by `basal_energy_burned` (2.3 GB) and
  `active_energy` (1.9 GB), neither of which MaxAct reads. Scoped to workouts, routes and
  `heart_rate` it is 0.41 GB.

**Verify:** captured fixtures committed under `MaxActCore/Tests/Fixtures/`; the decision recorded
in `PLAN.md`.

#### Spike tooling

`Spikes/` is now a permanent fixture rather than the throwaway Phase 1 said to delete. It is in the
Xcode navigator for browsing but excluded from every build phase via `EXCLUDED_SOURCE_FILE_NAMES`
— see `Spikes/README.md` and the conventions reference. `hae_mcp_probe.py` still regenerates
fixtures and gives a known-good reference to check the Swift client against; `hae_decode.swift.txt`
is the only artefact of the `.hae` reverse engineering.

Captures are written to `~/.maxact-spike-captures`, outside the repository, because they contain
real GPS traces and heart rate.

| | |
|---|---|
| Mac on the LAN | `10.0.0.206`, hostname `Gondolin-3` |
| Phone (HAE Server screen) | `10.0.0.158:9000`; the bearer token may have been regenerated — re-read it |
| HAE must be | open and foregrounded, phone unlocked; the server dies when backgrounded |

```
python3 Spikes/hae_mcp_probe.py --host 10.0.0.158 --token <token> --list-tools
MAXACT_LIVE_HOST=10.0.0.158 MAXACT_LIVE_TOKEN=<token> swift test --filter LiveMCPTests
```

### Phase 2 — Model + ingest (`MaxActCore`)

Canonical types as sketched above, plus HAE decoders built against the Phase 1 fixtures, and the
winning `WorkoutSource` implementation. `HAEFileSource` handles a manual-export folder (JSON
workouts + per-workout GPX routes) and is always built.

**Tests:** fixture → `Workout` round-trip; an unknown activity name lands in `.other`; a workout
with no route decodes; unknown extra JSON keys don't throw; `{qty, units}` unwrapping and unit
conversion; the `yyyy-MM-dd HH:mm:ss Z` parser across a DST boundary and a non-local offset.

### Phase 3 — Persistence — **done 2026-09-20**

SwiftData `@Model WorkoutRecord` holds every field the table sorts, filters or displays, plus the
local state: `placeLabel`, `stravaState`, `stravaActivityID`, `stravaUploadID`, `lastUploadedAt`,
`thumbnailFileName`, `hasDetail`. `WorkoutStore` is a `@ModelActor`, so `@Model` objects never
escape the actor — the UI only ever sees the value type `WorkoutListItem`.

`upsert` matches on the HealthKit UUID and rewrites **only imported fields**, which is what makes a
retried chunk safe. Three subtleties that tests pin down: `hasRoute` is OR-ed rather than assigned,
or a list pass (fetched with `includeRoutes: false`) would erase it; absent optionals keep their
previous value rather than nulling; and an empty series is not saved, or a list pass would replace
a stored detail blob with nothing.

Series blobs live in `Application Support/com.swiatlowski.MaxAct/Series/<id>.json.lzfse`.
**LZFSE, not the zlib originally planned** — comparable ratio, much faster to decompress, and these
are read interactively.

Measured at corpus scale rather than assumed:

| | |
|---|---|
| Largest real route (3.5 h, 12,645 points) | 2465 KB JSON → **168 KB** (14.7×) |
| Worst case if every workout were that size | **0.5 GB** |
| Open one workout (load, decompress, decode) | **55 ms** |
| List all 2,867 rows | **0.108 s** |
| Bulk insert 2,867 rows | 8.7 s one-time; a weekly chunk of ~20 is ~60 ms |

### Phase 4 — List UI

`NavigationSplitView`:
- **Sidebar:** All Workouts, per activity kind, and saved filters — at minimum "Not on Strava",
  "Upload failed", "Has route".
- **Content:** `Table(_:selection:sortOrder:columnCustomization:)` with `selection: Set<String>`
  for multi-select (⌘A "Select All" comes free), sortable columns, and customization persisted via
  `@AppStorage`. Columns: route thumbnail, Date, Kind (symbol + name), Duration, Distance,
  Pace/Speed, Energy, Avg HR, Place, Strava. `.searchable` over kind, place and source.
- **Detail:** one row selected → Phase 5's view; many selected → count, aggregate totals and the
  batch actions.

Every action lives in three places per Mac convention: toolbar, context menu, and a menu-bar
`CommandGroup` with a shortcut.

**Thumbnails are the performance crux.** A `RouteThumbnailRenderer` actor simplifies the polyline
(Ramer–Douglas–Peucker down to ~200 points), renders once per (id, size, appearance) with
`MKMapSnapshotter`, and caches the PNG to disk plus an in-memory `NSCache`. Rows read cached images
only; renders are requested lazily for visible rows and cancelled on scroll-away. If snapshotter
latency disappoints, fall back to a `Canvas`-drawn polyline with no map tiles.

**Verify:** `RunProject`, then scroll a seeded table of ~1000 rows and confirm no live `Map`
instances and no hitching; screenshot via the device-interaction tools.

### Phase 5 — Detail view

`Map` with `MapPolyline(coordinates:)` over the downsampled route; Swift Charts for heart rate,
pace and elevation against time; a stats grid; laps/splits table; source and device; Strava status
with a link to the uploaded activity. Liquid Glass only on the floating map overlay controls, inside
a single `GlassEffectContainer` — Apple's own guidance is that over-applying it costs render time.

Accessibility from the start, not retrofitted: Strava state is **symbol + text**, never colour
alone; explicit `accessibilityLabel` on every status symbol; text styles throughout so Dynamic Type
scales.

### Phase 6 — Approximate location

Snap the route's first coordinate to a ~1 km grid before storing it, so the list never depends on a
precise home address. Resolve with `MKReverseGeocodingRequest(location:)` → `await request.mapItems`
→ `MKAddressRepresentations.cityName` + `regionCode` ("Vancouver, BC"). Serialize through an actor,
throttle to roughly one request per second, back off on failure, and cache by snapped coordinate —
repeat rides from the same trailhead then cost nothing. Indoor or route-less workouts show an indoor
badge or an em dash, never a fabricated place.

### Phase 7 — TCX export and Strava

**TCX writer** (`MaxActCore/Formats`): `Activities/Activity/Lap/Track/Trackpoint` with `Time`,
`Position`, `AltitudeMeters`, `DistanceMeters`, `HeartRateBpm` and `Cadence`; lap-level
`TotalTimeSeconds`, `DistanceMeters`, `Calories`, `AverageHeartRateBpm`, `MaximumHeartRateBpm`.
Golden-file tests, plus one indoor (no-GPS) case that must still produce a valid file.

**Strava.** A `Settings` scene takes the client ID and secret into the Keychain
(`kSecClassGenericPassword`, `.whenUnlocked`). OAuth via `ASWebAuthenticationSession` with a custom
callback scheme (`CFBundleURLTypes` gets added in this phase, now that the scheme is chosen), scope
`activity:write,activity:read_all`. Strava's OAuth has no PKCE, so the secret is genuinely required
— which is exactly why the user supplies their own. Tokens refresh proactively on expiry and
reactively on a 401.

Upload: multipart `POST /api/v3/uploads` (`file`, `data_type=tcx`, `name`, `description`,
`activity_type`, `external_id` = our workout id), then poll `GET /api/v3/uploads/{id}` until
`activity_id` appears or `error` is set. `external_id` buys server-side dedupe: Strava answers
"duplicate of activity N", which we record as already-uploaded rather than as a failure.

Rate limiting, via one actor with **two** budgets — overall (200/15 min, 2000/day) and read
(100/15 min, 1000/day), because status polls are GETs and hit the read bucket. Parse
`X-RateLimit-Usage` / `X-RateLimit-Limit` and `X-ReadRateLimit-*`, keep upload concurrency at 1, and
on a 429 back off to the next quarter-hour boundary. Persist `stravaUploadID` so a relaunch resumes
polling instead of re-uploading.

Batch upload: progress sheet with per-item state, continue-on-error, and a "Retry failed" action.
Failures are never swallowed — `stravaState = .failed(reason)` and the reason is readable in the
detail pane.

**Tests:** golden-file TCX; the rate-limit actor under a simulated 429 and header sequence; the
duplicate-activity response path; token refresh on 401.

### Phase 8 — Polish

First-run onboarding that walks through the chosen sync setup; window state restoration and
`@SceneStorage` for selection and sort; empty states for every list; an error banner that
distinguishes "phone not reachable" from "auth rejected" from "HAE returned nothing" (which, per
HAE's own docs, is indistinguishable from a permissions problem — say so, and point at Health →
Sharing → Apps); one XCUIAutomation test that launches with seeded data, multi-selects, and runs a
batch action.

---

## 5. Verification

- **Compile fast:** `XcodeRefreshCodeIssuesInFile` after each edit; `BuildProject` per phase.
- **Package logic:** `swift test` in `MaxActCore/` — models, decoders, TCX golden files, rate-limit
  actor. No app launch needed, so this is the fast inner loop.
- **App tests:** `RunAllTests` (once the scheme's Test action is wired in Phase 0).
- **Spike probes:** `RunCodeSnippet` and `curl` against the live phone in Phase 1.
- **End to end:** `RunProject`, sync from the phone, confirm rows appear with thumbnails and places;
  open one workout and confirm map, HR chart and splits; select several, upload to Strava, and
  confirm the activities exist there with heart-rate data attached and no duplicates on re-run.

---

## 6. Risks

| Risk | Mitigation |
|---|---|
| No HAE path carries full route + HR | Phase 1 tests all three before any of Phases 2–8 depend on one. Manual export (JSON + GPX) is the documented floor and is built regardless. |
| `.hae` is opaque | Treated as a bonus, not a dependency, and there's no reference implementation to lean on. Time-boxed to an hour in Phase 1, then dropped. |
| ~~Heart-rate series are bucketed, so uploaded TCX heart-rate tracks may be coarse~~ | **Retired 2026-09-18.** Measured: `metadataAggregation: "seconds"` yields a 5 s median interval, the Apple Watch's native workout rate. Ask for it on detail fetches. |
| Backfill is slow: the phone spends ~2.4 s per workout regardless of payload options, and the server dies if HAE is backgrounded | Chunk by month, make sync resumable and idempotent, show progress, and tell the user to keep HAE foregrounded. A 1,000-workout history is ~40 minutes — acceptable once, not per launch. |
| MCP tool names/contract shift between HAE versions | Probe the contract at connect time and fall back across known names; surface an actionable error rather than failing silently. |
| MCP server dies when HAE is backgrounded | Sync is an explicit, foreground, resumable operation with visible progress — never a silent background job. Chunk by month so an interruption loses one chunk. |
| Route-less/indoor workouts | First-class state everywhere: no thumbnail, indoor badge instead of a place, and TCX (not GPX) so the upload still carries HR, laps and calories. |
| Table performance with thousands of rows | Denormalized sort columns in SwiftData, series in blobs off the query path, pre-rendered cached thumbnails, no live `Map` in a row. |
| Strava rate limits and async upload processing | Two tracked budgets, serialized uploads, header-driven backoff, persisted upload IDs so polling resumes; "queued" is in-flight, not success. |
| Ad-hoc signing invalidates Keychain items on rebuild | Bundle ID is fixed in Phase 0. If macOS starts prompting on every rebuild, create a self-signed development certificate — revisit only if it actually bites. |
| Route data reveals home locations | The start coordinate is coarsened to ~1 km *before* storage; full routes stay local; nothing leaves the Mac without an explicit action on an explicit selection. |

---

## 7. Keeping this plan current

`PLAN.md` in the repo is the source of truth for *what* and *which phase*. When something changes:
edit the affected section in place (don't leave stale text with a contradiction below it), bump
**Last updated**, append a dated change-log line, and update the phase table.

Durable *how-to* knowledge goes in the skill at `.claude/skills/maxact-development/` instead, so it
survives past the phase that discovered it:

| File | Holds |
|---|---|
| `SKILL.md` | Ground rules, the fast test loop, and the two findings that shape the data model. |
| `references/hae-data-contract.md` | Envelope, required vs optional fields, `{qty, units}`, date format, route fields, HR bucketing, and the exact invocation details for all three sync paths. |
| `references/xcode-project-conventions.md` | Settings that must not change, which build settings the tooling can and can't write, the silent zero-tests scheme trap, SwiftPM manifest requirements. |
| `references/strava-api.md` | The two rate-limit buckets, upload/poll flow, OAuth constraints. |

Rule of thumb: if a fact would still be true two phases from now and cost research to establish, it
belongs in the skill. If it's a decision, a status, or a sequencing choice, it belongs here.
**Phase 1's findings are the next thing to land in both** — the measured sync decision goes in §2
and the change log, and any new payload detail goes in `references/hae-data-contract.md`.

| Phase | Status |
|---|---|
| 0 — Project foundation | Complete |
| 1 — Sync evaluation spike | Complete — MCP chosen |
| 2 — Model + ingest | Complete |
| 3 — Persistence | Complete |
| 4 — List UI | Not started |
| 5 — Detail view | Not started |
| 6 — Approximate location | Not started |
| 7 — TCX + Strava | Not started |
| 8 — Polish | Not started |

### Change log

- **2026-09-20** — Phase 3 complete. `WorkoutRecord`, `WorkoutStore` (`@ModelActor`) and
  `SeriesStore` added; 65 tests. The imported/local split is the load-bearing idea — a re-synced
  window must not cost us `stravaActivityID`, or the next batch upload duplicates work already on
  Strava. Switched series compression from zlib to LZFSE and measured the result: the largest real
  route compresses 14.7× to 168 KB, opens in 55 ms, and listing all 2,867 rows takes 0.108 s, so
  the denormalised-row/blob-on-disk split does what it was chosen for. Also made `Spikes/`
  permanent but inert — browsable in Xcode, excluded from every build phase — after discovering it
  (and `PLAN.md`) had been silently copied into the app bundle.

- **2026-09-20** — Phase 2 complete. `MaxActCore` now holds the canonical model (metres, seconds,
  kilocalories, m/s, bpm), the HAE v2 JSON decoder, an MCP Streamable HTTP client, `HAEWorkoutSource`
  and the weekly chunker plus `SyncFrontier`. 47 tests, and a live suite gated behind
  `MAXACT_LIVE_HOST`/`MAXACT_LIVE_TOKEN` that was run against the phone: handshake to
  Health Auto Export 1.1.0, 13 workouts listed in 28.2 s (2.17 s each, matching the Phase 1
  estimate), and detail returning 3311 route points with 664 heart-rate samples at a 5.0 s median.
  Found an HAE bug on the way — `avgSpeed`/`maxSpeed` are km/h labelled `"km"` — adjudicated
  against the `.hae` `measurements` block and handled for speed-dimension fields only. Also had to
  detach `Spikes/` from the Xcode target: it had been absorbed automatically, putting raw GPS
  captures into Copy Bundle Resources.

- **2026-09-20** — Phase 1 closed. Probe C decoded `.hae`: LZFSE, natively decodable, with a
  versioned self-describing schema that is richer than MCP's (SI units with provenance, HealthKit
  activity codes, laps/splits/pause events, IANA time zone) and exact wherever it lands — route
  and heart-rate counts matched MCP exactly for the same workout, heart rate via a join against
  `HealthMetrics/heart_rate` dailies. Chose MCP anyway, on bulk import rather than fidelity:
  `.hae` backfill cannot be forced and stalled after two days, manual export writes multi-GB files
  to a phone short on space, and MCP shares the v2 JSON schema with manual export so one decoder
  covers both. Sized the job at ~2,867 workouts over 7 years and split sync into a blocking
  ~1.9 h list pass plus lazy per-workout detail, chunked weekly so an interruption costs ~20 s and
  peak phone memory stays small. Probe B was deliberately not run — its only distinct value was
  hands-off capture, which evaporated once it emerged that no path runs without HAE open.
  Corrected two of my own errors along the way: a claim that heart-rate units varied within one
  payload, and a claim that `.hae` needed nothing from the user.


- **2026-09-18** — Replaced `OLD_PLAN.md`. Dropped the iOS HealthKit companion (developer-program
  cost) in favour of Health Auto Export. Researched all three HAE export paths and found the REST
  payload fully documented (route + heart rate present), the MCP server's route/HR coverage
  unconfirmed, and `.hae` proprietary with no folder present on this Mac — so the sync decision
  became Phase 1's measured spike rather than a documentation guess. Confirmed HAE Premium and a
  Strava API app are in hand; no Apple Developer team, so signing stays ad-hoc. Chose TCX as the
  single upload format. Recorded 2026 Strava limits, including that upload-status polls consume the
  *read* budget. Recorded the template build settings Phase 0 has to undo.
- **2026-09-18** — Reviewed `HealthyApps/health-auto-export-server`. It is a REST receiver
  (Express + MongoDB + Grafana), **not** a `.hae` reader, so the iCloud probe is unchanged and all
  three Phase 1 probes stand. It does pin down the REST contract (`POST /api/data`, `api-key`
  header, `{"data":{"metrics","workouts"}}`, 207 on partial failure, 200 MB bodies), confirms
  `route` and `heartRateData` are first-class, and adds three undocumented route accuracy fields to
  `RoutePoint`. Two findings changed the plan beyond documentation: heart-rate data is a **bucketed
  min/avg/max series rather than raw beats**, which bounds TCX quality and is now a Phase 1
  measurement and a tracked risk; and Phase 1's REST probe now runs their server as the capture
  harness instead of a hand-rolled listener. Repo has no license — reference only, no code reuse.
- **2026-09-18** — Executed Phase 0. `MaxAct2` narrowed to macOS 26 (`SUPPORTED_PLATFORMS`,
  `SDKROOT`, deployment target, `TARGETED_DEVICE_FAMILY` cleared), Swift 6 with complete
  concurrency checking on all three targets, bundle ID fixed at `com.swiatlowski.MaxAct`, sandbox
  opened for outgoing connections and read-write user-selected files, local-network usage
  description set, `MyApp.swift` renamed to `MaxActApp.swift`, `.gitignore` added, `MaxActCore`
  package created with a passing test, and both app test bundles added and wired. Both predicted
  Xcode-UI test steps turned out to be scriptable via a checked-in shared scheme plus a
  bundle-identifier launch in the UI test; only the local-package link remains manual. 3/3 app
  tests and 2/2 package tests pass, build clean.
- **2026-09-18** — Ran Phase 1 probe A (MCP over HTTP): passes, and is the presumptive winner.
  Routes at 1 Hz; heart rate at a 5 s median with `metadataAggregation: "seconds"`, which retires
  the coarse-heart-rate risk entirely. The transport turned out to be real MCP Streamable HTTP
  rather than the simplified `callTool` the help pages document, and `tools/list` works. Cost is
  ~2.4 s of phone time per workout almost regardless of payload size, so sync should fetch in two
  tiers — minute-resolution metadata without routes for the list, per-workout re-fetch with routes
  and second-resolution for detail and export. That also settles the long-standing question of
  when detail gets fetched. Separately confirmed by experiment that unit strings track HAE's
  preferences (including a "Localize Units" toggle) while conversion is lossless, so the app
  normalises whatever arrives and no HAE setting is preferred; decided to support metric only and
  fail loudly on imperial. Two fixtures committed, one per unit vocabulary. Probes B and C remain.

- **2026-09-18** — `MaxActCore` linked into the app target, completing Phase 0. Captured the
  research and Phase 0 findings as a skill at `.claude/skills/maxact-development/` so the HAE data
  contract, Xcode tooling limits and Strava constraints don't have to be rediscovered each phase;
  §7 now describes the split between plan and skill.
