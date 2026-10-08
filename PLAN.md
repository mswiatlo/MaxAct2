# MaxAct — Plan

A fast, native macOS 26 app for browsing Apple Health workouts exported by **Health Auto Export**
(HAE), with batch upload to Strava.

**Status:** Phases 0–7 built. Phase 7 has three live checks left; then known issues and Phase 8.
**Last updated:** 2026-10-07.

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
| 7 — TCX + Strava | Built; three live checks left |
| 8 — Polish | Not started |

---

## 1. Where things stand — paused 2026-10-07

All work is on `main`, pushed; no open branches. Builds clean with **zero warnings**. Tests: 233 in
`MaxActCore` (`swift test`), 28 app and UI tests (`RunAllTests` — leave the Mac alone for ~3.5
minutes, or mouse use breaks them).

**Pick up here — three live checks in the app, no code expected:**

1. Settings → Strava → "Check for Workouts Already on Strava". The 9/18 (13:20 and 16:04) and 9/21
   rides should come back tagged **Commute** (set by hand on Strava, so this proves importing).
2. Untag Commute on one of them. The detail pane should show "Updating Strava…" briefly, and the
   flag should clear on Strava. Re-tag it afterwards.
3. Tag the next workout before uploading it. It should arrive with the commute flag and muted.
   Note whether a *backdated* upload reaches followers' feeds even unmuted — that decides whether
   mute stays on by default.

Also unseen live: the exact duplicate-error wording (no real duplicate rejected yet).

**Then, in order:** known issue 10 (inspector close control + sidebar squeeze — smallest), 9
(region/country search), 11 (odd splits on the 9/21 ride), 6 (chart/map linking), 8 (summary
stats), Phase 8. Issue 7 (TrainingPeaks) starts with whether its API is open to us at all.

**Settled live 2026-10-07:** upload, the sport-correcting `PUT` and the already-on-Strava check work
against the real account. Strava's Activity Tags ("With Kid", "With Pet") are **not in the API** —
confirmed against an activity tagged "With Kid" — so such tags are Mac-only by necessity.

---

## 2. Open issues and requests

Numbered independently of the phases: "known issue 8" (summary stats) is not "Phase 8" (polish).
Issues 1–5 are fixed; their diagnoses are in `HISTORY.md`.

**6. Link the charts and the map to each other.** *(feature)*
Clicking a chart point highlights that spot on the map, and clicking the route highlights that time
in the charts. One `@State var highlighted: Date?` drives both — **timestamp, not array index**,
since the series differ in length. `.chartXSelection(value:)` for charts → map; `MapReader` to turn a
click into a coordinate for map → charts. Traps:
- Look up against the full `series.cleanedRoute`, never the thinned chart data or simplified
  polyline.
- A time inside a pause has no position: snap only within a few seconds, else show nothing.
- A click far from the track should highlight nothing: use a screen-space distance threshold.
- The pace series drops stopped samples, so it may lack a mark the other charts have.

Put nearest-by-time (binary search) and nearest-by-coordinate in `MaxActCore` next to
`WorkoutCharts` so the tolerances are tested. Update the charts' `accessibilityValue` with the
highlighted values.

**7. Sync to TrainingPeaks as well as Strava.** *(speculative, unresearched)*
TrainingPeaks accepts TCX, so the file is free. **First establish whether its API is open** — it is
understood to be partner-gated. If closed, offer a plain "Export TCX…" command instead, useful for
Garmin, Runalyze and archiving anyway. The uploader sits behind `WorkoutDestination`, but upload
*state* on `WorkoutRecord` is still Strava-shaped; a second destination means per-destination
state, which is a schema and UI change.

**8. Summary statistics: weekly, monthly, yearly, all-time.** *(speculative)*
Totals by period and kind, with a distance-per-month chart. `WorkoutAggregate` already does the
arithmetic; the work is grouping and presentation, in the package so period boundaries are tested.
Things that will bite:
- `duration` is moving time for auto-paused activities and elapsed time for others (walks). Label
  it plainly, or derive moving time from the series.
- Missing distance/energy must not silently count as zero. Say how many couldn't be counted.
- Week start is a locale setting. Use `Calendar.dateInterval(of:for:)` and choose explicitly.
- Bucket by the current time zone, and say so.

**9. Search by region and country, not just the stored label.** *(feature)*
"BC", "British Columbia", "Canada" should find Vancouver rides; "Switzerland" the Geneva ones.
Search only reads `placeLabel` ("Vancouver BC"). Design: a hidden `placeSearchTerms` field (city,
region abbreviation and full name, country name and ISO code), matched case- and
diacritic-insensitively, never displayed. Known constraints:
- MapKit gives `cityWithContext` and, via `.full`, the country. **`regionCode`/`regionName` don't
  exist in the SDK**, so the full region name isn't available from MapKit.
- `Locale.localizedString(forRegionCode:)` turns "CH" into "Switzerland". There is no equivalent
  for subdivisions, so "BC" → "British Columbia" needs a small bundled ISO 3166-2 table.
- City names depend on the geocoder's locale ("Geneva" vs "Genève"); store both when they differ.
- Existing places need resolving again. That's one request per ~1 km cell, not per workout.
  Version the terms so it happens once.
- Privacy: still send only the snapped cell, and never store street-level fields.

**10. A visible way to close the detail inspector.** *(small)*
Today it closes only via View ▸ Hide Inspector or ⌃⌘I. Add a trailing **toolbar toggle**
(`sidebar.trailing`, "Inspector") bound to `showsDetail`. Decide at the same time: the pane
auto-opens only when the selection goes from empty to non-empty, so after closing it, clicking
another row leaves it closed. Either reopen on any selection change unless closed during the current
selection, or have an explicit close stick until reopened. Test it in the seeded UI suite.

Same fix should address the **sidebar squeeze**. At the default 1,300pt width, opening the
inspector leaves no room for three panes, so AppKit collapses the sidebar. Launch now forces
`.all`, but selecting a workout still hides the sidebar until the window is widened. Either widen
the window when the inspector opens, or let the table shrink further.

**11. Strange pace splits around km 5 on the 2026-09-21 ~1 PM commute ride.**
Not yet investigated. Measure first: print that ride's per-km splits from `WorkoutSplits` next to
the raw route around 4–6 km (timestamps, gaps, speeds, accuracy), and compare with Strava's own
splits for the same ride. Suspects: a GPS gap or stop inside the km, a jump the route cleaning
missed, or route distance disagreeing with HealthKit's total. Fix in `MaxActCore` with a test built
from the real points.

**Optional, not built:** writing Mac-only tags into the Strava description (`#withkid`) behind a
setting.

### Known limitations

- **No `.hae` reader.** It would give HealthKit's own laps, splits and pause events, which MaxAct
  currently reconstructs from the route. Worth reconsidering if issue 11 traces back to splits.
- **Visual details aren't covered by tests.** The map camera and chart contents aren't exposed to
  accessibility, so they were checked by hand.
- **Column widths are tuned for this Mac's content.** Longer place or activity names will
  truncate. Retuning means bumping `workoutTableColumns.v5`.
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

## 5. Phase 8 — Polish

First-run onboarding that walks through the HAE sync setup; `@SceneStorage` for selection and sort;
empty states for every list; an error banner that distinguishes "phone not reachable" from "auth
rejected" from "HAE returned nothing" (which, per HAE's docs, is indistinguishable from a
permissions problem — say so, and point at Health → Sharing → Apps).

---

## 6. Verification

- **Compile fast:** `XcodeRefreshCodeIssuesInFile` after each edit; `BuildProject` before committing.
- **Package logic:** `swift test` in `MaxActCore/` — the fast inner loop.
- **App and UI tests:** `RunAllTests`, with the Mac left alone.
- **Data questions:** decode the stored series files (see `Spikes/`) rather than reasoning from
  formulas. **Measure, don't derive:** in this project, measurement has repeatedly contradicted
  plausible calculations, for both data and layout. Examples are in `HISTORY.md` §1.
- **End to end:** sync from the phone, open a workout, upload a selection, confirm on Strava with
  heart rate attached and no duplicates on re-run.

---

## 7. Keeping this plan current

This file is for **what's current**: status, next steps, open issues, decisions. Keep it short.
- Edit sections in place, bump **Last updated**, and update the phase table.
- Add a dated entry to the change log in **`HISTORY.md`**.
- When an issue is fixed, move its diagnosis to `HISTORY.md` §2 and drop it here.

Durable *how-to* knowledge goes in `.claude/skills/maxact-development/`:

| File | Holds |
|---|---|
| `SKILL.md` | Ground rules, the fast test loop, the facts that shape the data model. |
| `references/hae-data-contract.md` | HAE payloads, units, dates, route and HR fields, all three sync paths, `.hae` format. |
| `references/xcode-project-conventions.md` | Build settings, schemes, SwiftUI/AppKit traps, UI-test isolation, window state. |
| `references/strava-api.md` | Rate limits, OAuth, upload flow, what the live API actually returns. |

Rule of thumb: if a fact will still be true two phases from now and cost research to establish, it
belongs in the skill. A decision, a status or a sequencing choice belongs here.
