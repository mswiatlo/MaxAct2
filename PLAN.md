# MaxAct — Plan

A fast, native macOS 26 app for browsing Apple Health workouts exported by **Health Auto Export**
(HAE), with batch upload to Strava.

**Status:** Phases 0–7 complete and verified live. Next: known issues, then Phase 8.
**Last updated:** 2026-10-11 (late night).

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

## 1. Where things stand — 2026-10-11

All work is on `main`, pushed; no open branches. Builds clean with **zero warnings**. Tests: 272 in
`MaxActCore` (`swift test`), 34 app and UI tests (`RunAllTests` — leave the Mac alone for ~4
minutes, or mouse use breaks them). A full run makes no Keychain calls.

Phases 0–7 are done and verified live. Since then: issues 9, 10, 11 and 13 fixed; View ▸ Hide
Sidebar (⌃⌘S); ⌥⌘U for the Strava check; MaxAct is one window (no tabs, no New Window).

**Next:** issue 12 (the table gets cramped with the inspector open), 14 (signing — needs the user),
6 (chart/map linking), 8 (summary stats), then Phase 8. Issue 7 (TrainingPeaks) starts with
whether its API is open to us at all.

**Still to confirm live:**
- Issue 13: "Check for Workouts Already on Strava" (⌥⌘U) should report the two deleted 9/21 rides
  and mark them not uploaded; they can then be re-uploaded without the GPS spike.
- The exact duplicate-error wording — no real duplicate has been rejected yet.

## 2. Open issues and requests

Numbered independently of the phases: "known issue 8" (summary stats) is not "Phase 8" (polish).
Fixed issues — 1–5, 9–11 and 13 — have their diagnoses in `HISTORY.md` §2; what stays open
from them is under "Known limitations" below.

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

**12. The table gets cramped when the inspector is open.** *(eased 2026-10-10)*

At the default 1,300pt window the table now gets **664pt** with the inspector open, up from 562pt,
because the inspector opens at its 440pt minimum instead of a 560pt ideal (the sidebar-inset fix; see `HISTORY.md` §2, under issue 10).
Still below the sum of the column minimums, so some columns compress. Remaining options, none
measured: automatically hiding low-value columns under some width, or accepting it — widening the
window once is sticky and solves it per-user. Decide with real content in the window.

**14. The real app asks for the Keychain password after every rebuild.** *(follow-up, user-requested
2026-10-11)*

The app is **ad-hoc signed** (`Signature=adhoc`, no team), so every build has a new code signature
and the Keychain treats each one as a new app: the first Strava access after a rebuild raises a
password prompt, and "Always Allow" only covers that one build. Tests are no longer affected — UI
tests and the unit-test host run on in-memory secrets — but day-to-day development still is.

The fix is a **stable signing identity**, so the Keychain's access rule follows the certificate
rather than the build. `security find-identity -v -p codesigning` found **none** on this Mac. Options:

- **Add an Apple ID in Xcode** (Settings ▸ Accounts) for a free *Personal Team*, then select it as
  the target's team with automatic signing. Simplest; personal-team certificates expire yearly
  and are renewed by Xcode.
- **A self-signed code-signing certificate** (Keychain Access ▸ Certificate Assistant ▸ Create a
  Certificate, type "Code Signing"), set as `CODE_SIGN_IDENTITY`. No Apple account needed, but
  manual to renew and not trusted beyond this Mac.

Needs the user for the account or certificate step. After it, each item needs "Always Allow" once
more, then should stop prompting; verify by rebuilding twice and launching. Check that the
sandbox and Keychain service name (`com.swiatlowski.MaxAct.strava`) carry over unchanged, so the
existing Strava login survives the switch.

**Optional, not built:** writing Mac-only tags into the Strava description (`#withkid`) behind a
setting.

### Known limitations

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
- **Column widths are tuned for this Mac's content.** Longer place or activity names will
  truncate. Retuning means bumping `workoutTableColumns.v5`.
- **Ad-hoc signing makes the real app ask for the Keychain password after every rebuild** —
  tracked as issue 14. Tests are no longer affected (see the change log,
  2026-10-11): UI tests and the unit-test host both run on in-memory stores, and a full run makes
  no Keychain calls.
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

**Work on a branch.** Before starting any feature, fix or batch of changes, create a branch from
`main` (`git switch -c <short-name>`). Commit there, verify (build, `swift test`, `RunAllTests`),
then merge to `main` and push once the work is verified or the user approves. Don't commit
directly to `main`. *(Requested by the user, 2026-10-10.)*

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
