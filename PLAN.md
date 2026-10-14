# MaxAct — Plan

A fast, native macOS 26 app for browsing Apple Health workouts exported by **Health Auto Export**
(HAE), with batch upload to Strava.

**Status:** Phases 0–8 complete and checked by the user. Next: issue 15 (deeper statistics).
**Last updated:** 2026-10-14.

> **Working on this project?** Read `.claude/skills/maxact-development/` first: the HAE data
> contract, the Xcode tooling limits, and the Strava API facts. **`HISTORY.md`** holds how we got
> here — phase write-ups, fixed issues, the original research and the dated change log.

| Phase | Status |
|---|---|
| 0 — Project foundation | Complete |
| 1 — Sync evaluation spike | Complete — MCP chosen |
| 2 — Model + ingest | Complete |
| 3 — Persistence | Complete |
| 4 — List UI | Complete |
| 5 — Detail view | Complete |
| 6 — Approximate location | Complete |
| 7 — TCX + Strava | Complete, verified live |
| 8 — Polish | Complete, checked by the user |

---

## 1. Where things stand — 2026-10-12

All work is on `main`, pushed; no open branches. Builds clean with **zero warnings**. Tests: 312 in
`MaxActCore` (`swift test`), 53 app and UI tests (`RunAllTests` — ask first, then leave the Mac
alone for ~5 minutes; the two real-content tests skip unless a library copy is in place). A full
run makes no Keychain calls.

Phases 0–7 are done and verified live. Since then: issues 6 and 8–14 fixed or closed (8: statistics); View ▸ Hide
Sidebar (⌃⌘S); ⌥⌘U for the Strava check; MaxAct is one window (no tabs, no New Window).

**Next:** issue 15 (deeper statistics). Issue 7 (TrainingPeaks) starts with
whether its API is open to us at all.

**Still to confirm live:** the exact duplicate-error wording — no real duplicate has been rejected
yet.

## 2. Open issues and requests

Numbered independently of the phases: "known issue 8" (summary stats) is not "Phase 8" (polish).
Fixed or closed issues — 1–14 — have their diagnoses in `HISTORY.md` §2; what stays open
from them is under "Known limitations" below.

**15. Deeper statistics.** *(deferred from issue 8; training load built)*
The HealthFit-style analyses left out of issue 8's first cut, as separate pieces:
- **Training load** *(built 2026-10-14, awaiting the user's check)* — Fitness/Fatigue/Form
  (CTL 42 days, ATL 7 days, TSB = yesterday's difference) from Banister's TRIMP on each workout's
  average heart rate, in the package (`TrainingLoad`, 8 tests against independently computed
  values, mutation-checked). Statistics gets a Training Load section (last 90 days) that asks for
  resting HR, maximum HR (suggesting the highest recorded, 182) and the TRIMP curve on first use;
  the same fields are in Settings. The curve (male 1.92 / female 1.67) is the user's choice, never
  defaulted. Workouts without heart rate are counted and reported. Checked on a copy of the real
  library with placeholder rates.
- **Heart-rate zones** — time in zones per period. Needs the HR series, so it only covers workouts
  whose detail has been downloaded; say how many weren't counted.
- **Route heat map** — every route on one map, plus an Explorer-style count of map tiles visited.
  Also needs downloaded detail.

**Optional, not built:** writing Mac-only tags into the Strava description (`#withkid`) behind a
setting.

### Known limitations

- **Signing depends on a Personal Team certificate that expires 2027-10-11.** Xcode renews it; if
  Keychain prompts after rebuilds ever return, check `security find-identity -v -p codesigning`
  first (see the Xcode conventions reference).
- **A city with no province anywhere stays province-less** (from issue 9). MapKit gives no province
  for places outside a municipality (UBC); such a place borrows one from other places in the same
  city and country. If none of them has one, there's nothing to borrow. Judged rare; revisit if it
  shows up.
- **Region search expands abbreviations only for Canada, the US and Australia** (from issue 9).
  Elsewhere the raw value is stored and searchable.
- **No `.hae` reader.** It would give HealthKit's own laps, splits and pause events, which MaxAct
  currently reconstructs from the route. (Issue 11's odd splits turned out to be a GPS fault, not
  this.)
- **UI tests share the app's window geometry.** AppKit's frame autosave and split-view state live
  in the standard defaults, which `--ui-testing` does not isolate, and the saved frame is **per
  display configuration**. So a test run can change where the real app opens, and a test can't
  assume a starting width.
- **Visual details aren't covered by tests.** The map camera and chart contents aren't exposed to
  accessibility, so they were checked by hand.
- **The table is narrower with the inspector open** (from issue 12). Columns that don't fit are cut
  off at the right rather than compressed: at the default width that's Pace, Energy and Avg HR,
  all shown in the inspector alongside. Strava sits third so it always stays. Widening the window
  once brings the rest back, and the width sticks.
- **Column widths are tuned for this Mac's content.** Longer place or activity names will
  truncate. Retuning means bumping `workoutTableColumns.v6`.
- **Over the statistics the inspector is our own panel**, not the system inspector (from issue 8d):
  SwiftUI can't lay the system one out beside SwiftUI content. It behaves the same, but its width is
  remembered separately and it doesn't take part in window state restoration.
- **The load-error banner has no test** (Phase 8): there's no reliable way to make the store fail
  inside a UI test. Checked by build and by reading only.
- **Whether HAE rejects a bad token at the handshake is unmeasured.** Test Connection doesn't
  depend on it — it also lists workouts — but a sync's first failure point might differ.
- **Performance tests have loose thresholds.** They catch 10× regressions; the printed figures are
  the real measurements.
- **`Spikes/` stays** as the quickest way to inspect a stored series file. It's excluded from every
  build.

---

## 3. Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Targets | One macOS app (`MaxAct2`, display name **MaxAct**) + `MaxActCore` local SwiftPM package + unit and UI test bundles | Package logic is testable with `swift test` without launching the app. |
| Minimum OS | macOS 26.0 | Liquid Glass, `MKReverseGeocodingRequest`, Swift-native `Network`. |
| Sync | **MCP over HTTP** to HAE on the phone; chunked weekly and resumable | All three HAE paths carry full route and heart rate; only MCP can be driven by the Mac to completion for ~2,867 workouts. `.hae` backfill stalls; manual export needs GBs of phone storage. |
| Sync shape | **Two passes.** List sync with no routes (`metadataAggregation: "minutes"`); per-workout detail with routes (`"seconds"`), fetched on demand or via "Download Missing Detail" | List sync is the only blocking cost (~1.9 h of foreground phone for 7 years). Fetching every route up front would double it. |
| Units | Metric only, normalised to SI; anything else is a hard decode failure | HAE's unit strings follow its preferences. A loud failure beats reading `mi` as `km`. |
| Model | Own value types in `MaxActCore`, decoded from HAE's shape; `ActivityKind.other(String)` | HAE sends activity display names, not HealthKit codes. |
| Persistence | SwiftData rows for list fields and local state; series as LZFSE-compressed JSON files | Large routes stay out of the table's query path. `upsert` never overwrites local state (tags, Strava state, place). |
| Thumbnails | Pre-rendered, disk-cached `MKMapSnapshotter` images — never a live `Map` per row | Live maps in a table are the easiest way to make the app slow. |
| Location | Snap the start to a ~1 km grid **before** geocoding; store city-level names only | An unsnapped start geocodes to a street address. |
| Strava format | **TCX only**; sport corrected afterwards with a `PUT` | Carries GPS, HR and calories, works for indoor workouts. TCX's `Sport` knows only Running/Biking/Other. |
| Strava credentials | User's own client ID + secret in the Keychain | A bundled secret is extractable and shares one rate-limit budget. |
| Tags | Local tags; **Commute/Trainer** mirrored to Strava's flags; everything else Mac-only | Strava's API has no Activity Tags. |
| Windows | **One.** No tabs, no New Window | Filter, search and selection live on the shared `AppModel`, so extra windows only looked independent. Making them independent was the alternative, judged not worth it for a one-library app. |
| Concurrency | Swift 6, strict concurrency, `async`/`await`, no Combine; default actor isolation `MainActor` | Project style. |

**Out of scope for v1:** writing to HealthKit; non-workout health metrics; GPX/FIT export; Strava
download; syncing between Macs; imperial units.

---

## 4. Architecture

```
MaxAct2.xcodeproj
├── MaxAct2              app: AppModel, views, Keychain store, PlaceResolver, thumbnail renderer
├── MaxAct2Tests         Swift Testing
├── MaxAct2UITests       XCUIAutomation, seeded with --ui-testing --ui-testing-seed=N
└── MaxActCore/          local SwiftPM package
    ├── Ingest/          MCP client + endpoint parsing, HAE decoder, date parser, sync estimates
    ├── Model/           Workout, WorkoutSeries, ActivityKind, tags, route quality/simplification,
    │                    splits, chart data, place grid, sample data for UI tests
    ├── Store/           WorkoutStore (@ModelActor), WorkoutRecord, SeriesStore, StravaState
    ├── Formats/         TCXWriter
    └── Strava/          client, uploader, rate limit, activity matcher
```

```
iPhone / HAE MCP server ─→ MCPClient ─→ HAEWorkoutDecoder ─→ WorkoutStore (SwiftData + series files)
                                                                  ↓
                                   Table + detail ─→ TCXWriter ─→ StravaUploader ─→ Strava
```

Privacy: the start coordinate is coarsened before storage; full routes stay on the Mac; nothing
leaves without an explicit action on an explicit selection. UI tests run fully isolated
(`--ui-testing`: in-memory store, separate settings and Keychain service).

---

## 5. Phase 8 — Polish *(complete 2026-10-14, checked by the user)*

Scope chosen with the user: a welcome sheet with a connection test, and remembering the sidebar
choice and sort (not the selection or search).
- **Welcome sheet** on a first launch with nothing configured (never to existing users), and from
  Help ▸ Getting Started with MaxAct…: what's needed (HAE Premium, same Wi-Fi), where the address and
  token come from, the fields, **Test Connection**, and how long a year's sync takes.
- **Test Connection** (welcome sheet and sync panel): handshake and tool list under a 10 s
  deadline (they take ≤0.6 s on a real phone), then a one-week listing with up to 90 s and a
  progress line (it takes 11–16 s); reports the recent-workout count, so "connected, but Health
  isn't sharing workouts" shows up before a long sync. The first version's single 15 s limit cut
  off a healthy phone mid-listing — the user saw HAE answer just after. Confirmed working by the user.
- **Sync errors name their cause** (`SyncProblem`): server not running (refused) vs phone
  unreachable (time-out, unknown host) vs token rejected vs server error vs unexpected reply —
  mapping measured. A sync that returns nothing warns and points at Health ▸ Sharing ▸ Apps;
  workouts that can't be read are counted and logged rather than silently dropped.
- **Empty states** say what they mean per filter ("No Failed Uploads", "Everything's on Strava"…);
  only a real search gets "No Results".
- **Remembered** between launches: sidebar choice and table sort.
- **Library load errors** are shown in a banner (they were recorded and never displayed).

Checked by the user: welcome sheet, Test Connection, empty states, remembered sidebar and sort. The
sync error messages couldn't be checked live (sync was working); they rest on the tests and the
measured URLError mapping.

---

## 6. Verification

- **Compile fast:** `XcodeRefreshCodeIssuesInFile` after each edit; `BuildProject` before committing.
- **Package logic:** `swift test` in `MaxActCore/` — the fast inner loop.
- **App and UI tests:** `RunAllTests`, with the Mac left alone — ask first.
- **Data questions:** decode the stored series files (see `Spikes/`) rather than reasoning from
  formulas. **Measure, don't derive:** in this project, measurement has repeatedly contradicted
  plausible calculations, for both data and layout. Examples are in `HISTORY.md` §1.
- **End to end:** sync from the phone, open a workout, upload a selection, confirm on Strava with
  heart rate attached and no duplicates on re-run.

---

## 7. Keeping this plan current

**The working rules — branching, verification, keeping this file and `HISTORY.md` current,
asking before UI tests — are in `CLAUDE.md`**, which every session loads automatically.

This file is for **what's current**: status, next steps, open issues, decisions. Keep it short.

Durable *how-to* knowledge goes in `.claude/skills/maxact-development/`:

| File | Holds |
|---|---|
| `SKILL.md` | Ground rules, the fast test loop, the facts that shape the data model. |
| `references/hae-data-contract.md` | HAE payloads, units, dates, route and HR fields, all three sync paths, `.hae` format. |
| `references/xcode-project-conventions.md` | Build settings, schemes, SwiftUI/AppKit traps, UI-test isolation, window state. |
| `references/strava-api.md` | Rate limits, OAuth, upload flow, what the live API actually returns. |

Rule of thumb: if a fact will still be true two phases from now and cost research to establish, it
belongs in the skill. A decision, a status or a sequencing choice belongs here.
