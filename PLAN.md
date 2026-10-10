# MaxAct — Plan

A fast, native macOS 26 app for browsing Apple Health workouts exported by **Health Auto Export**
(HAE), with batch upload to Strava.

**Status:** Phases 0–7 complete and verified live. Next: known issues, then Phase 8.
**Last updated:** 2026-10-09 (evening).

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
| 8 — Polish | Not started |

---

## 1. Where things stand — 2026-10-09

All work is on `main`, pushed; no open branches. Builds clean with **zero warnings**. Tests: 233 in
`MaxActCore` (`swift test`), 30 app and UI tests (`RunAllTests` — leave the Mac alone for ~4
minutes, or mouse use breaks them).

**Phase 7 is done.** The three remaining live checks all passed against the real account: the sync
check imports Commute from Strava, editing a Strava-backed tag on a synced workout pushes the
change, and tagged uploads arrive with the flag set and muted. Together with the earlier run, that
covers upload, sport correction, duplicate detection, tag import, tag push and mute.

**Known issues 10 and 9 are done** (2026-10-09): a toolbar Inspector toggle with a close that
sticks, and search by region and country.

**On next launch** the app re-resolves every stored place once, to add the region and country
terms — one geocoder request per distinct place, in the background, with the Place column
unchanged. Nothing to do; worth knowing if the Place column looks busy for a minute.

**Next:** known issue 11 (odd splits on the 9/21 ride), 12 (the table gets cramped with the
inspector open), 6 (chart/map linking), 8 (summary stats), then Phase 8. Issue 7 (TrainingPeaks)
starts with whether its API is open to us at all.

**Still unseen live:** the exact duplicate-error wording — no real duplicate has been rejected yet.

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

**9. ~~Search by region and country, not just the stored label.~~ — done 2026-10-09.**

Searching "British Columbia", "Canada" or "Switzerland" now finds rides whose visible label only
says "Greater Vancouver BC" or "Geneva, Switzerland". A hidden `placeSearchTerms` field holds city,
subdivision as given *and* expanded, and country; it is stored pre-folded for case and diacritics,
so "geneve" finds Genève. `placeTermsVersion` makes the backfill automatic — a row below the
current version re-resolves itself, at one request per ~1 km cell rather than per workout.

**Two geocoders, which the measurement forced.** MapKit composes the label well ("Boulder, CO
United States" but "Geneva, Switzerland") and exposes no subdivision — `regionCode` is documented
but **absent from the SDK**, and `regionName` is the country. `CLPlacemark` has the structure
(`locality`, `administrativeArea`, `country`, `isoCountryCode`) and no composer. Each is used for
what it does well, two requests per new cell, both throttled.

Also measured, and the reason the label didn't regress: `cityWithContext` returns an **empty
string** for a place in the device's own region, not just over water — Vancouver came back blank on
a Canadian Mac. Composing `locality + administrativeArea` as the second fallback reproduces
"Greater Vancouver BC" exactly; falling straight through to `cityName` would have quietly demoted
every local label to "Vancouver" on the first re-resolve.

`administrativeArea` is an abbreviation in Canada, the US and Switzerland but a full name in the UK
("Scotland"), so expansion uses a bundled ISO 3166-2 table for CA, US and AU, keyed by country
because "WA" and "NT" collide. Anywhere else the raw value is still stored and searchable.

**10. ~~A visible way to close the detail inspector.~~ — done 2026-10-09.**

A trailing toolbar **Toggle** bound to the same state as ⌃⌘I, so the button and the menu item can't
disagree. An explicit close now **sticks**: clicking another row leaves it closed, as in Finder and
Xcode. The old rule reopened it on the next selection, which meant the close button could not be
obeyed while a row was selected — most of the time.

**The sidebar squeeze turned out not to exist**, which only measuring found. Stating
`columnVisibility = .all` had fixed the live collapse, not merely its persistence: with the
inspector open the sidebar keeps its full 217pt. The table is what gives way — see issue 12.

Resizing the window to fit all three was built and then **removed**. It worked, but AppKit's frame
autosave made the new width stick, so a single selection would have left the window permanently
wider even with the inspector shut — and Xcode, Finder and Mail all shrink the content instead.
Worth not rebuilding.

**11. Strange pace splits around km 5 on the 2026-09-21 ~1 PM commute ride.**
Not yet investigated. Measure first: print that ride's per-km splits from `WorkoutSplits` next to
the raw route around 4–6 km (timestamps, gaps, speeds, accuracy), and compare with Strava's own
splits for the same ride. Suspects: a GPS gap or stop inside the km, a jump the route cleaning
missed, or route distance disagreeing with HealthKit's total. Fix in `MaxActCore` with a test built
from the real points.

**12. The table gets cramped when the inspector is open.** *(measured 2026-10-09)*

At the default window width, opening the inspector takes the table from 1,079pt to **562pt** —
below the sum of its own column minimums, so columns compress and truncate. The window is wide
enough for all three panes only in the sense that none disappears.

Not a defect so much as a consequence of eleven columns and a 440pt inspector. Options, none yet
measured: a narrower inspector minimum (440 was set by the splits row, which could wrap instead);
automatically hiding low-value columns under some width; or accepting it, since widening the window
once is sticky and solves it per-user. Decide with real content in the window, not from these
numbers.

**Optional, not built:** writing Mac-only tags into the Strava description (`#withkid`) behind a
setting.

### Known limitations

- **No `.hae` reader.** It would give HealthKit's own laps, splits and pause events, which MaxAct
  currently reconstructs from the route. Worth reconsidering if issue 11 traces back to splits.
- **UI tests share the app's window geometry.** AppKit's frame autosave and split-view state live
  in the standard defaults, which `--ui-testing` does not isolate, and the saved frame is **per
  display configuration**. So a test run can change where the real app opens, and a test can't
  assume a starting width.
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
