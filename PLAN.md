# MaxAct — Plan

A fast, native macOS 26 app for browsing Apple Health workouts exported by **Health Auto Export**
(HAE), with batch upload to Strava.

**Status:** Phases 0–8 complete and checked by the user. Next: see §1.
**Last updated:** 2026-10-26.

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

## 1. Where things stand — 2026-10-24

All work is on `main`; no open branches. Builds clean with **zero warnings**. Tests: 391 in
`MaxActCore` (`swift test`), 89 app and UI tests (`RunAllTests` — ask first, then leave the Mac
alone for ~15 minutes; the two real-content tests skip unless a library copy is in place). A full
run makes no Keychain calls.

Phases 0–7 are done and verified live. Since then: issues 6 and 8–14 fixed or closed (8: statistics); View ▸ Hide
Sidebar (⌃⌘S); ⌥⌘U for the Strava check; MaxAct is one window (no tabs, no New Window).

**Next:** the security fixes 47 and 48, then 36
(README). 24's live run waits for HAE's fix (21). Issue 7 (TrainingPeaks) starts with
whether its API is open to us at all.

**Still to confirm live:** the exact duplicate-error wording — no real duplicate has been rejected
yet.

## 2. Open issues and requests

Numbered independently of the phases: "known issue 8" (summary stats) is not "Phase 8" (polish).
Fixed or closed issues — 1–20, 22, 23, 25, 26, 27, 29–32, 34, 35, 28, 37–46 — have their diagnoses in `HISTORY.md` §2; what stays open
from them is under "Known limitations" below.

**21. Health Auto Export bug report** *(sent by the user 2026-10-14; HAE acknowledged it and asked
for data; package prepared 2026-10-23)* — two export
defects behind 18 and 19, on every HAE path (MCP, manual JSON and GPX): Workout-app heart rate comes
as one average per series sample, and interval workouts' routes as one interval's piece (the Sept
17 2025 run: interval 3 of 28, 27 s of 42 min — identical in the manual GPX/JSON export). Until
HAE fixes it, MaxAct fills heart rate from `get_health_metrics` and routes from Strava. **Keep open until HAE fixes it.** Then: re-download the
affected workouts — the ones issue 22 flags, plus the 17+ with heart rate from `get_health_metrics` —
check the export's routes and heart rate are whole, and consider retiring the Strava route fallback.

The data sent (`~/Downloads/MaxAct-HAE-issue-data.zip`) covers the runs from 2025-09-17, 10-02 and 10-08. Each run has
HAE's `get_workouts` and `get_health_metrics` replies, unmodified, and a GPX built from Strava's streams. Points inside a
400 m zone, centred at a random offset of up to 150 m from home, were removed from the GPX. New finding: each
exported route piece is exactly one entry of the workout's `activities` array, one work interval (index 3 of 28,
2 of 20, 2 of 8).

**Follow-up:** XCTest reads an empty label for the inspector's "≈" estimates and the
incomplete-route note, despite explicit accessibility labels — check with VoiceOver /
`debugDescription` which element the identifier lands on.

**Statistics' accessibility frames are wrong** *(found 2026-10-27; investigated, left open)*. A
two-axis `ScrollView` in the split view's detail column, under macOS 26's floating sidebar,
reports frames that don't match where things are drawn:
- the scroll view itself, always: x 552, width 1133, where it's drawn from 330 across about 1355;
- its contents, once the inspector has opened: one sidebar-width (~223 pt) left, and still after
  it closes.

VoiceOver's cursor, and any click aimed by frame, land off target. None of these changed it:
- no slide-in animation (this only moved the failure from open to closed);
- vertical-only scrolling (the layout overflowed the window);
- laying statistics and inspector out beside the sidebar explicitly.

`testStatisticsReportWhereTheyAreDrawn` holds it as a strict expected failure, so it fails once an
OS update fixes it. The heatmap test aims from the window meanwhile. Next, if pursued: try the
system `.inspector` here (avoided for 8d's overflow), or report it to Apple with a small sample.

**Follow-up from 23:** after a detail re-download, the inspector uses the old sketch until the
sketches are next loaded (a Statistics visit).

**24. "Everything" should mean everything** *(requested 2026-10-15; built 2026-10-25; live run deferred)* —
"Everything" (was "Everything (7 years)") now syncs weekly, newest first, back to 2000. Health
launched in 2014, but a history imported from Strava can be older. Measured on the phone: an empty
window costs 0.03–0.2 s and a workout ~2.1 s, so the empty weeks add a minute or two. The panel shows
"Back to <month year> · N imported". **The live run waits for HAE's fix (21)**, by the user's choice, so
the re-import gets whole routes and heart rate. Then: check the phone's current address on HAE's
Server screen and set it in MaxAct (it changes between networks), run Everything with HAE in front (about 2 hours for ~2,867 workouts by Phase 1's
count), and check the oldest workout and the count.

**From the code-quality audit (27, 2026-10-26; agreed with the user, in this order):**

**Follow-up from 38 — Strava names and time zones.** Activity names use the Mac's time zone, so a
morning run abroad can be named "Night Run". The fix depends on what HAE's UTC offset means, which
is unmeasured: the recording's own zone, or the phone's zone at export. (The fixtures can't tell:
`make_fixture.py` moves dates but keeps the offset.) Next time the phone is connected, fetch a
winter workout. If it reads `-0800`, the offset is the recording's: store it and name by it.

**From the security audit (28, 2026-10-27; agreed with the user, in this order):**

**Follow-up from 44 — the first table rebuild costs ~2 s.** Replacing the table that has been on
screen since launch takes about 2 s wherever it happens: the first search keystroke now (2.3 s, two
runs), or a later big insertion if recorded at load (1.9 s). A table built during the search
replaces in about 0.5 s. Unexplained. Next ideas: whether `Table` builds row views for every row
(Instruments, SwiftUI template), and what tearing one down costs. It's once per session, against
6.5 s on every growth before 44.

**47. Hardening** *(built 2026-10-27 on `hardening`, awaiting the user's check)* —
- **The HAE token is a `SecureField`** in Settings and in the connection fields; UI tests type into
  `secureTextFields`.
- **Private logs:** HAE error replies, decoder failures and the heart-rate lookup failure.
- **`GuardedSession` (new), shared by both transports:**
  - refuses redirects. Measured: without it, the request really did go on to the redirect's host.
  - abandons replies over 256 MB, whether or not the length is declared.
  - gathers the reply in chunks. `bytes(for:)` was ruled out: 35 s for 5 MB in debug, against
    0.02 s.
- **Build settings:** the user-selected-files entitlement removed; Hardened Runtime on. The signed
  app shows the runtime flag; its entitlements are now sandbox and network client, plus
  `get-task-allow` in Debug.
- **`inMemoryFallback`** has no default secret store; the production fallback passes the Keychain
  explicitly.
- **Tests:** `GuardedSessionTests`, 3, mutation-checked (redirect, size).
- **To check:** the app launches; Strava still shows connected; the token field shows dots and
  takes a paste.

**48. HTTPS to Health Auto Export** (S4; the user's idea) — HAE's MCP server has an HTTPS option.
Plain HTTP lets anyone on the same Wi-Fi read the token and the workouts, or impersonate the phone.
HTTPS only helps if the certificate is checked, and HAE's is probably self-signed, which
`URLSession` rejects. Steps:
1. With the phone (ask for its current address), turn on HTTPS. Look at the certificate:
   self-signed? Stable across HAE restarts and updates?
2. Measure what TLS costs a sync.
3. Pin it: show the fingerprint on first connect for the user to confirm, store it, and accept only
   that certificate afterwards.
4. Keep HTTP as a clearly labelled, less safe option.

Until then: trusted networks only, and regenerate the token after an untrusted one. Say so in the
README (36) and the welcome sheet.

Checked and fine in 28:
- the OAuth `state` and scope checks;
- no URL scheme other apps can trigger;
- no secrets in logs or in errors shown;
- system TLS for Strava;
- TCX escaping;
- health data never leaves the sandbox container.

Kept as is (S11): the HAE token in UserDefaults. The Keychain would prompt after every rebuild,
and the token is exposed on the network until 48 anyway.

**36. A visual README** *(requested 2026-10-26; after the audits)* — a `README.md` at the root that
introduces MaxAct and shows its features: what it is (a Mac browser for Apple Health workouts
exported by Health Auto Export, with Strava upload), screenshots of the main views (table and
inspector, Same Route, coloured routes, statistics and the heatmap), how sync works, and what's
needed (HAE Premium on the phone, same Wi-Fi). **Screenshots from seeded data only**, window-only
via `XCUIElement`, never the user's library or screen: real routes would show where the user
lives. Keep it short; `PLAN.md` and `HISTORY.md` stay the developer docs.

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
