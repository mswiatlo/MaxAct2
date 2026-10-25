# MaxAct — History

What was learned and decided while building MaxAct, moved out of `PLAN.md` on 2026-10-07 so the
plan can stay short. **Nothing here is current status** — see `PLAN.md` for that. Text is kept as
it was written, so it may describe things as "to do" that have since been done; the change log at
the end is the dated record.

Durable *how-to* facts (API behaviour, Xcode quirks, data contract) are in
`.claude/skills/maxact-development/`, not here.

## Contents

1. Notes from the Phase 6–7 pauses (lessons and bugs found by use)
2. Fixed known issues (1–6, 9–14)
3. Seeded UI tests
4. Original context and research
5. Original architecture sketch
6. Phase write-ups, 0–7
7. Original risk table
8. Change log

---

## 1. Notes from the Phase 6–7 pauses

**A habit worth keeping: measure, don't derive.** This has now paid off twice over, in two
different areas, and in nearly every case the measurement *contradicted* a reasonable-looking
calculation.

On the data: `avgSpeed` turned out to be a mean of instantaneous samples rather than a pause
problem, the proposed GPS spike detector fired only on jitter, and the heart-rate min–max band was
degenerate in all 2,580 real samples. An hour with the stored blobs repeatedly changed *what got
built*, not just confirmed it.

On the layout, more recently and more embarrassingly: `.width(ideal:)` turned out not to control
rendered width at all, a saved `TableColumnCustomization` was silently overriding every declared
width, `.defaultSize` was ignored in favour of the content's ideal, and a window sized from
sidebar + column widths came out ~185pt short because a `.inset` table's gutters aren't in those
numbers. Three shipped-then-corrected values came from trusting arithmetic over a measurement.

The cheap instruments, both documented in the skill reference: decode the stored series blobs for
anything data-shaped, and read the app's persisted state back after a launch for anything
layout-shaped. Neither needs a screenshot.

**Five bugs were found by using it, none of which any test caught.** Each is fixed and each taught
something now recorded in the skill reference:

1. `components.url!` on the typed address — pasting the full URL from HAE's Server screen (the
   natural thing to do) hard-crashed on Start Sync. Now parsed by `MCPEndpoint`, which accepts
   every sensible form and echoes the resolved URL back in the panel.
2. `@Environment(AppModel.self)` in a popover — crashed when the window re-laid out. Fixed in the
   popover only, and then it recurred in a table cell while scrolling. The model is now threaded
   explicitly everywhere and `@Environment(AppModel.self)` appears nowhere; on macOS, AppKit hosts
   table cells, toolbars, menus and popovers detached, and none of them reliably inherit it.
3. The thumbnail placeholder keyed "indoor" off `hasRoute == false`, which after a list pass means
   *unknown* — so every outdoor ride was labelled indoor.
4. `.task(id: key)` didn't include `hasDetail`, so the first attempt ran before any route existed,
   returned nothing, and never retried once Download Detail completed.
5. `MKMapSnapshotter` was released the moment `start` returned, since that was its last use, so
   the completion never fired and every thumbnail spun for ever. Held across the await now. Its
   throttle also parked cancelled tasks on continuations that nothing resumed, which wedged all
   later renders; it polls instead.

A sixth was found by running the suite rather than the app, and is worth remembering because it
looked like everything except what it was: **13 seeded UI tests couldn't launch the app at all**,
because `--ui-testing-seed 40` as two tokens leaves a stray `40` once `NSUserDefaults` pairs
arguments, and AppKit reads a stray argument as a file to open — which suppresses `WindowGroup`'s
window entirely. It is invisible under `open --args`, and raising the timeout doesn't help. Now
passed as `--ui-testing-seed=40`.

**Outstanding:**

1. **Strava is unbuilt.** The state machine, badges and filters exist and are tested; the toolbar
   button is deliberately disabled until Phase 7.
2. **No `.hae` reader.** Repeatedly the answer to things we currently reconstruct: HealthKit's own
   splits and laps, and explicit `pause`/`motionResumed` events that would settle moving time
   exactly instead of by threshold. Worth reconsidering before Phase 7.
3. **`Spikes/` is still in the tree.** Phase 2 said delete it; it stays for now because the Python
   probes remain the quickest way to interrogate a stored blob.
4. Performance assertions were loosened after failing spuriously at load average 86. They catch
   10x regressions; the printed figures are the real measurements.
5. The seeded UI tests can't see the map camera or chart contents — neither is exposed to
   accessibility — so those were verified by hand and by decoding rendered PNGs. Anything visual
   still needs an eye on it. The same limit bit the layout work: `entire contents` of the window
   returns nothing through System Events, so cell alignment could not be checked programmatically
   and the centred Strava glyph is the one recent change **not** independently verified.
6. **Column widths and window size are tuned for this Mac's content**, not proven across
   locales — a longer place name than "Greater Vancouver BC" or a longer activity name than
   "Strength Training" will truncate. Retuning means bumping `workoutTableColumns.v5` again.

---

## 2. Fixed or closed known issues (1–20, 22, 23, 26, 30)

**1. ~~Average speed and pace include time spent stopped.~~ — done 2026-09-21.**

The cause turned out to be nothing to do with pauses, and measuring first saved building the wrong
thing. `effectiveSpeedMetersPerSecond` preferred HAE's `avgSpeed`, and **`avgSpeed` is the
arithmetic mean of the per-point instantaneous speeds** — it matched that mean to six significant
figures in all five measured workouts. That mean includes every sample recorded while stopped
(6–27% of points), so it is biased low by 13–31%, by a varying amount.

Meanwhile `duration` is *already* moving time: 509–2,154 s against wall-clock spans of
551–6,240 s, and it agreed with a moving time computed from the route's own speeds to within 3%
every time. So the fix is simply to prefer **distance ÷ duration**, which needs no series and works
in the list for every workout immediately. The evidence that it's the unbiased figure: across four
rides by the same rider it gives 5.37–5.55 m/s, where `avgSpeed` scattered over 3.75–4.87 m/s. The
measured walk went from 19:40 /km to **14:50 /km**. `avgSpeed` is kept only as a last resort for a
workout with no distance.

Moving time is still computed, as a *refinement* rather than the fix, because activities the watch
doesn't auto-pause don't benefit from the above — the walk's `duration` equalled its full
55.3-minute span, with 12.3 minutes of it standing still. The detail pane shows both, labelled
**Elapsed Pace** and **Moving Pace** (14:50 against 11:30 for that walk); the list shows the
elapsed figure, which is the one always available. Thresholds are per activity — a cyclist at
0.6 m/s is stopped at a light, a walker at 0.6 m/s is walking.

**2. ~~The detail map opens on the previously selected workout's region.~~ — done 2026-09-21.**

`WorkoutDetailView` used `Map(initialPosition:)`. An initial position is applied **once, when the
map view is created**, and SwiftUI reuses the same `Map` across selection changes, so the region
computed for the first workout stuck and every later selection inherited it. The map is now driven
by a bound `@State var camera: MapCameraPosition`, reassigned in the existing `.task(id: item.id)`
*after* the series loads — the map exists well before the route arrives, so ordering matters. The
documented semantics are what make this work: passing `MapCameraPosition` as a *binding* has the
map adjust its camera whenever the value changes, whereas `initialPosition` explicitly does not.

A second defect of the same family was found while fixing it and is also gone: `series` was plain
`@State` on a reused view, so between selections the **previous** workout's route stayed drawn
under the **new** workout's header until the load finished. The loaded series is now tagged with
the id it belongs to and the body refuses to draw a mismatch, which rules the class of bug out
structurally rather than by getting the ordering right.

Region framing (bounding box + headroom, with a floor so a treadmill-sized route doesn't zoom to
one building) moved to `CoordinateBounds.displaySpan(headroom:minimumSpan:)` in `MaxActCore`, with
an `MKCoordinateRegion(fitting:…)` bridge in `MaxAct2/Support/MapRegion.swift`. The detail map and
the thumbnail renderer now share it, passing their own values — 1.3/0.003 for the 280pt map,
1.25/0.002 for a 96×56 thumbnail, where the track needs the pixels more than the breathing room.

Verified by hand against real workouts, since the camera region isn't exposed to accessibility and
the seeded routes all loop around one origin: a 3.73 km walk framed tightly on Granville Park, an
11.66 km ride on a much wider view from UBC to Burrard, and a 2.82 km ride zoomed back in on the
UBC Botanical Garden — re-framing correctly in both directions, not merely tracking the newest.

**3. ~~Route lines are grey.~~ — done 2026-09-20.**

Two separate causes, and both are fixed.

The defect: `Assets.xcassets/AccentColor` was **empty** — it declared a `universal` idiom with no
colour components — so `NSColor.controlAccentColor` in the thumbnail renderer and `.tint` in the
detail map both resolved to a default grey. There is no
`ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME` in the project, so the asset was being picked up
purely by naming convention; the colorset is deleted, and the app now follows the user's system
accent like any other Mac app.

The design mistake: a route line shouldn't follow the system accent at all. The accent is
user-configurable (graphite is a legitimate choice), and a track has to stay legible over parkland,
water and dense city blocks in both map appearances. `RouteColor` in `MaxActCore/Model` now holds
six deliberately saturated choices — default **Sunset** (`#FA590F`), a vivid orange-red — as sRGB
components rather than a SwiftUI `Color`, so it stays in the model layer and is testable. Picked in
Settings → Appearance, with swatches.

One subtlety worth keeping in mind for anything else cached: thumbnails live on disk indefinitely,
so the colour had to become part of `RouteThumbnailRenderer.Key` and therefore of the filename
(`…-dark-sunset.png`). Without that, changing the setting would have left every existing thumbnail
in the old colour until something unrelated invalidated it. Old-format files are simply never read
again; `Delete All Workouts` clears them.

Verified by decoding a rendered PNG: 605 pixels of `(247, 93, 42)` — the stroke, antialiased over
real map tiles.

**4. ~~No detection of bad GPS fixes.~~ — done 2026-09-21.** *(feature)*

`RouteQuality` in `MaxActCore/Model`, filtering **on read** as planned: the stored series keeps
exactly what the watch recorded, so thresholds can change without re-syncing and a future TCX
export can choose which track to carry.

The signature was measured, not guessed, and it is not the one sketched above. Every
kilometre-scale teleport across five real workouts landed on a point with **no
`speedMetersPerSecond` and a horizontal accuracy above ~30 m** — the worst a 1,826 m jump between
samples one second apart. Good fixes had a median accuracy of 8–16 m, the bad ones 35–39 m.
Dropping that combination discards 0.0–0.7% of a route and takes the worst implied speed from
1,826 m/s to 51 m/s; the remainder are 30–74 m wobbles, too small to distort the track or the
framing. The rule never looks at movement, so it cannot mistake genuine speed for an artifact.

**Two things the sketch above proposed were measured and rejected.**

*Implausible instantaneous speed.* At 1 Hz the GPS noise floor is itself several metres per second.
With a walking ceiling of 3 m/s the detector fired on **3–5 metre steps** — jitter, not
teleportation. Raised to a ceiling safe from false positives (5 m/s walking, 30 m/s cycling) it
never fired at all on real data. A knob that either misfires or no-ops is worse than no knob.

*Stuck fixes.* 3–18% of points with runs up to 33 samples, but at a 10 m accuracy floor they are
indistinguishable from genuinely standing still, and deleting them would delete real pauses.
`movingTime(for:)` treats them as what they are instead.

Also settled: **don't compute distance from the route.** Summing raw 1 Hz steps inflated a 3.73 km
walk to 5.55 km and an 11.66 km ride to 17.39 km, because it accumulates every metre of jitter.
HAE's own distance, from HealthKit's fused sensors, is the trustworthy figure.

The detail pane reports what was dropped — *"7 GPS fixes left out of the map as implausible. The
recording itself is unchanged."* — rather than quietly changing the numbers. The thumbnail cache
key gained a `drawingVersion`, because a single bad fix can be a 20-pixel spur on a 96-pixel
thumbnail and images cached before the filter had to be redrawn.

**5. ~~Backfill detail for everything~~ — done 2026-09-20.** *(feature)*

"Missing Detail" lives in the sync panel beneath Start Sync, as agreed. The button states the
count and the cost — *"Download 24 Workouts — about 1 minute"* — so the price is visible before
committing rather than discovered in a progress bar. A scope choice between all workouts and the
current filter appears **only when the filter actually narrows the backlog**, so it costs nothing
when it would say the same thing twice. Work proceeds newest-first, refreshes the table every few
workouts so a long run fills in visibly, and stops cleanly, keeping everything already fetched.

Two things fell out of building it. `SyncStatus` now carries which job is running — the banner
previously said "Syncing week 3 of 8" during a backfill, which counts workouts, not weeks. And the
per-workout cost moved into `SyncEstimate` in `MaxActCore`, shared with the range picker so the
two estimates can't drift, with the measured 2.4 s pinned by a test since the UI quotes it.

Not built: the opt-in background trickle. The manual action covers the need, and an automatic one
that occupies the phone for hours deserves its own design pass rather than being tacked on.


**Issues 9, 10, 11 and 13**, moved from `PLAN.md` on 2026-10-10 as written there (issue 12 remains open; the sidebar-inset fix that was recorded under it follows issue 10).

**9. ~~Search by region and country, not just the stored label.~~ — done 2026-10-09.**

Searching "British Columbia", "Canada" or "Switzerland" now finds rides whose visible label only
says "Greater Vancouver BC" or "Geneva, Switzerland". A hidden `placeSearchTerms` field holds city,
subdivision as given *and* expanded, and country; it is stored pre-folded for case and diacritics,
so "geneve" finds Genève. `placeTermsVersion` makes the backfill automatic — a row below the
current version re-resolves itself, at one request per ~1 km cell rather than per workout.

**One MapKit request, with the subdivision parsed from MapKit's own string** *(revised
2026-10-10)*. MapKit's address representations expose no structured subdivision — `regionCode` is
documented but absent from the SDK, `regionName` is the country — and the structured sources that do
(`CLGeocoder`, `MKMapItem.placemark`) are **deprecated in macOS 26**. Issue 9 first used
`CLGeocoder`, wrongly believing it current; the deprecation warning surfaced only when the file
recompiled. So the subdivision is now read from `cityWithContext(.full)` — "Vancouver BC Canada"
minus city and country leaves "BC" — which measured regular across ten places.

The label keeps MapKit's short form ("Vancouver BC", "Geneva, Switzerland"). An empty
`cityWithContext` is **not** a home-country behaviour, as first written: across ten places it
happened only at UBC (outside any municipality). New UBC-like places therefore get "Vancouver" and
no province; places resolved before this change keep their richer stored terms, since the terms
version was deliberately not bumped.

The subdivision is an abbreviation in Canada, the US and Switzerland but a full name in the UK
("Scotland"), so expansion uses a bundled ISO 3166-2 table for CA, US and AU, keyed by country
because "WA" and "NT" collide. Anywhere else the raw value is still stored and searchable.

**Borrowing the province, 2026-10-10** *(user-requested)*. When MapKit gives a city and country but
no province — UBC — the place borrows the province every other resolved place in that city and
country agrees on, in a local pass after each round of lookups (`borrowMissingSubdivisions`). It
declines when places disagree (two Richmonds) rather than guess. Places now store city, province
and country separately to make this possible (`PlaceTerms.version` 2). Measured on the user's data:
3 distinct start cells, one of which MapKit returns with no province, and it now reads "Vancouver
BC" and matches "British Columbia". **To revisit one day:** a city where *no* resolved place has a
province has nothing to borrow from and stays province-less — judged rare, and accepted.

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

**Related, fixed 2026-10-10 — the sidebar's inset vanished with the inspector open.** Not an
inset problem: the panes laid out **1,318pt wide in a 1,300pt window**, and SwiftUI centres
oversized content, clipping 9pt off *both* edges. Cause: the inspector opened at its 560pt ideal and
never shrank toward its minimum to fit. Now it opens at the minimum, and while it's open the
window's minimum width rises from 1,040 to 1,200 (measured: the three panes' floor), so even a
window dragged narrow can't reproduce it. Tested at both widths, and the test fails with the guard
removed.

**11. ~~Strange pace splits around km 5 on the 2026-09-21 ~1 PM commute ride.~~ — done 2026-10-10.**

A single bad GPS fix jumped **2,516 m out and straight back** in two seconds. It had no speed — the
known signature of a bad fix — but an accuracy of 27 m, just inside the 30 m limit, so the filter
kept it. Its phantom 5 km swallowed km 4–5 in two seconds ("3,600 km/h"), and because splits are
scaled to the ride's real 8.68 km, it also shrank every other kilometre: the whole ride read
13–17 km/h instead of 19–29.

Measured across all 8 stored routes before fixing: 10 out-and-backs over 100 m, **all speedless**,
none on a fix with a speed, 9 already caught by accuracy. So `RouteQuality` now also drops a
speedless fix over 100 m from both neighbours when they sit within half that of each other. It
found a second, smaller case on the 16:02 ride the same day (161 m out, while stopped); across the
library the rule adds those two fixes and nothing else. Tests reproduce both shapes, and fail with
the rule removed. Thumbnails redraw (drawing version 3).

**Follow-up, done 2026-10-10:** the user confirmed both 9/21 rides were bugged on Strava and deleted
them there. That exposed the next item.

**13. ~~The sync check didn't notice activities deleted on Strava.~~ — done 2026-10-10.** *(reported
by the user)* The check only ever *added* matches, so the deleted 9/21 rides kept their orange check
and a link to a dead activity. It now reconciles both ways: a synced workout whose activity is
missing from the listing is looked up directly, and only a **404** (measured: what Strava returns
for a deleted activity) resets it to "not uploaded", clearing the link but keeping its tags. Any
other error stops the check rather than unmarking anything; candidates are limited to the window
the listing covered; and `activity:read_all` is now required at connect, so a private activity
can't pass for a deleted one. The banner reports both counts.

**To confirm live:** run Settings → Strava → "Check for Workouts Already on Strava". Expected:
"2 were deleted on Strava and are marked not uploaded", both 9/21 rides back to not-uploaded, and
they can then be re-uploaded with the spike fix.

**Confirmed live 2026-10-10** by the user: the check marked the two deleted 9/21 rides not uploaded.

**12. ~~The table gets cramped when the inspector is open.~~ — closed 2026-10-11.** *(eased 2026-10-10)*

At the default 1,300pt window the table now gets **664pt** with the inspector open, up from 562pt,
because the inspector opens at its 440pt minimum instead of a 560pt ideal (the sidebar-inset fix; see `HISTORY.md` §2, under issue 10).
Still below the sum of the column minimums, so some columns compress. Remaining options, none
measured: automatically hiding low-value columns under some width, or accepting it — widening the
window once is sticky and solves it per-user. Decide with real content in the window.

**Closed 2026-10-11 — after checking with real content, which the first closing skipped.** It was
first closed on the numbers alone; the user asked why, since the plan's own note said to decide with
real content. A test-only launch mode (`--ui-testing-real-copy`) then opened a *copy* of the real
library, isolated as for every UI test, and photographed the window. Two findings the numbers had
hidden: with the inspector open the table doesn't *compress* columns, it **cuts off** the ones that
don't fit — and the cut-off ones included **Strava**, last in the order, at both the default 1,398pt
window and 160pt wider. The Strava column now sits third, after Date (user's choice), with the
layout key bumped to `v6` so the new order takes effect. Pace, Energy and Avg HR are what's cut off
now, all shown in the inspector beside them. Long place names ("Greater Vancou…") were left as they
are, also the user's choice: the full name is in the inspector.

**14. ~~The real app asks for the Keychain password after every rebuild.~~ — done 2026-10-11.**

Now signed with the user's free **Personal Team** (`DEVELOPMENT_TEAM` on all three targets; signing
style stays automatic, which picks "Apple Development" once a team is set). Verified on the build:
signed by "Apple Development", chaining to Apple Root CA, sandbox and network entitlements
unchanged, and a designated requirement of *bundle id + certificate* with no per-build hash — which
is what lets "Always Allow" survive rebuilds. 34/34 app and UI tests.

**To confirm live (the user):** launch MaxAct from Xcode; expect one last Keychain prompt — choose
**Always Allow** — and possibly a one-time macOS prompt about the app's data, since its signer
changed. Then rebuild (⌘B) and launch again: there should be no prompt. Strava should still show
as connected, since the Keychain service name is unchanged.

Getting there needed one fix on this Mac: the Apple Development certificate showed as *not valid*
because the keychain held only Apple's old developer intermediate (expired February 2023), not the
**G3** one that issued it. G3 was downloaded from apple.com/certificateauthority, its SHA-256
fingerprint checked against Apple's, and installed into the login keychain with the user's OK.
The personal-team certificate expires **2027-10-11**; Xcode renews it.

**Confirmed live 2026-10-11.** The user ran the signed app, chose Always Allow once, and saw no
prompt after a rebuild. They pointed out that rebuilding with nothing changed can produce an
identical binary, which would prove nothing — so a one-line change to a used string was built
(code hash `6f52…` → `e955…`, signature still the same certificate and team), run with no prompt,
and then reverted.


**6. ~~Link the charts and the map to each other.~~ — done 2026-10-11.**

Pointing at any chart highlights that moment in **every** chart — a rule with that chart's value
— and puts a marker on the map where the athlete was. Clicking the route does the reverse;
clicking empty map clears it. One `highlighted: Date?` drives everything, looked up against the
full cleaned route (`RouteLookup` in `MaxActCore`), never the thinned chart points or simplified
line. A time inside a pause shows no map marker and no chart value; a click counts as "on the
route" within 20 screen points, so it behaves the same at every zoom. While highlighted, each
chart's VoiceOver value becomes "<value> at <time>".

Measured: on macOS, `chartXSelection` **follows the pointer** — hovering is enough, no click
needed — and the highlight clears when the pointer leaves the chart. A UI test covers chart→map,
map→chart and the clear, and was confirmed to fail with route clicks broken.

**To try (the user), on a real ride:** hover the heart-rate chart and watch the marker move along
the route; click a point on the route and see the rules land in the charts; check a ride with a
pause shows no marker inside it. Close the issue if it reads well.

**Confirmed by the user 2026-10-11**, who then noticed the heart-rate chart's time axis didn't
match the others. Measured on 22 stored workouts: heart rate starts **1–55 s after** the workout
(the watch locking on) and ends a few seconds early, while route-derived series run the full span —
and each chart was fitting its axis to its own data. All charts now share one range,
`WorkoutCharts.timeDomain(for:charts:)`: the workout's start to end, widened only for a stray
sample. Checked on a copy of the real library and judged aligned — but **only on a walk**.

**Reopened the same day:** the user's screenshot of a ride showed the lines still off. A shared
domain isn't enough; the *plot areas* must be the same width too, and Swift Charts shrinks each
plot by its y-axis label width — "175" for heart rate, "36.0 km/h" for speed. A walk's pace labels
("18:00 /km") happen to be close to heart rate's width, which hid it. Every chart's y labels now sit
in a fixed 64 pt column (`SeriesChart.axisLabelWidth`), and the speed axis prints "0.0 km/h" rather
than "—" at zero. Verified on a real ride: ticks and highlight rule at the same x in all three, the
widest label ("14.4 km/h") untruncated.

**8. ~~Summary statistics.~~ — done 2026-10-14, confirmed by the user.**

A **Statistics** row at the top of the sidebar swaps the table for: totals (this week, month, year,
all time), a history bar chart by week/month/year, this year against last year and the best year
(HealthFit's comparison), a calendar heat map with day and week streaks, and personal bests per
activity that open their workout. Its own activity picker; it follows the search field. Arithmetic
in `WorkoutStatistics` (package, tested); missing values are counted, never summed as zero. The
year comparison stays a single line until older history is synced (the library starts
2026-08-23). Deferred, as separate ideas: training load (CTL/ATL/TSB), heart-rate zones, a route
heat map.

The user's check (2026-10-12) found two layout problems, both fixed 2026-10-12 and checked by the
user; their check of the fix raised 8c, still open:
- **8a/8d. The inspector over the statistics.** *(fixed 2026-10-14, awaiting the user's check)*
  The window's real inspector can't sit beside the statistics: SwiftUI pins a pure-SwiftUI
  column's width when it opens (measured with a layout dump; a plain colour does it), so the panes
  overflowed and the sidebar was cut off. An interim sheet worked; the user preferred the inspector
  (8d). Now, over the statistics, **the same detail view is drawn as a panel inside the statistics'
  own column** (`StatisticsWithInspector`), so the split view never changes: full 440pt width, its
  own drag handle (440–760pt, remembered), the toolbar toggle and ⌃⌘I (now our own View ▸ Inspector
  command) work as beside the list, and a personal best opens there. The statistics take what's left
  and scroll sideways below 480pt. The window's real inspector stays shut over the statistics.
  8c (the sheet's header) is moot — the sheet is gone. UI test mutation-checked.
- **8b. The statistics didn't adapt to a narrow window.** Every section now reflows to a 480pt
  minimum (controls stack, totals tighten, the heat map shows as many weeks as fit, best cards go
  to one column).

**7. ~~Sync to TrainingPeaks as well as Strava.~~ — closed 2026-10-14, not built (the user's call).**

TrainingPeaks' API is **closed to personal use**. Its Partner API FAQ: "At this time, we are not
accepting any API requests for personal use" — only organisations may apply, via
api.trainingpeaks.com/request-access, and are then developed against a sandbox before promotion.
The API itself would have fitted (OAuth 2.0; `POST v3/file` takes FIT, TCX or PWX), and its docs
are public on the PartnersAPI GitHub wiki. Community tools get round the gate by calling the
website's internal API (`tpapi.trainingpeaks.com`) with a copied browser session; that's
unsupported, breaks without notice and may breach the terms, so it was ruled out. The fallback the
plan proposed — an Export TCX… command for manual upload — was offered and declined; nothing was
built. Revisit only if TrainingPeaks opens personal access.

**15. ~~Deeper statistics.~~ — done 2026-10-14, confirmed by the user.** *(deferred from issue 8)*
The HealthFit-style analyses left out of issue 8's first cut, as separate pieces:
- **Training load** *(built 2026-10-14)* — Fitness/Fatigue/Form
  (CTL 42 days, ATL 7 days, TSB = yesterday's difference) from Banister's TRIMP on each workout's
  average heart rate, in the package (`TrainingLoad`, 8 tests against independently computed
  values, mutation-checked). Statistics gets a Training Load section (last 90 days) that asks for
  resting HR, maximum HR (suggesting the highest recorded, 182) and the TRIMP curve on first use;
  the same fields are in Settings. The curve (male 1.92 / female 1.67) is the user's choice, never
  defaulted. Workouts without heart rate are counted and reported. Checked on a copy of the real
  library with placeholder rates.
- **Heart-rate zones** *(built 2026-10-14)* — five zones by heart-rate
  reserve (Karvonen: Z1 50–60% … Z5 90%+, plus Below Z1) from the Training Load profile. A
  Statistics section above Routes: the current period's time per zone with bpm ranges, and
  stacked bars per period, following the period, activity picker and search. Each workout's time
  at each bpm is a histogram read in the same cached pass as the route sketches (each reading
  counts until the next; gaps over 30 s count nothing — measured, 30.7 h of 275 h are such gaps),
  so changing the profile is instant. Says how many workouts counted. Checked on a copy of the
  real library: all 418 counted. The inspector shows the same breakdown for the selected workout
  (below the charts), sharing one view (`HeartRateZoneBreakdown`) with Statistics.
- **Route heat map** *(built 2026-10-14)* — a Routes section in
  Statistics: every route on one map, faint so overlaps build up, following the activity picker
  and search. Routes are grouped into places by where they start (25 km), named from place labels;
  the map opens on the biggest and frames its densest 96%, with a menu for the rest. Explorer
  squares (zoom-14 tiles, counted from the full routes) as a total and per place, with an optional
  overlay. Sketches are built once (all 418 routes: ~9 s) and cached beside the series. Checked on
  a copy of the real library: 83 squares, 32 in Vancouver.

**18. ~~Sparse heart rate on Apple Workout-app recordings.~~ — done 2026-10-14, confirmed by the user.** 17 workouts (1–21 Oct 2025, all recorded by the watch's Workout app, "MaxWatch7")
had 2–22 heart-rate readings — one per ~10 minutes — where Strava has 1 s. Measured live: Health
Auto Export's `get_workouts` averages the Workout app's heart-rate series samples (~10-minute
chunks) into one reading each; `get_health_metrics` (`heart_rate`, `aggregate: true`,
`interval: "seconds"`) has every reading (353 at 5 s for the Oct 8 run, 83–169 bpm, matching its
summary). WorkOutDoors stores readings individually, so its 400 workouts were never affected.
Fixed: a detail download whose heart rate is under one reading a minute fetches it from
`get_health_metrics` instead (one extra ~1 s query, only for such workouts). On first launch the
app marks the stored sparse ones as needing detail (measured on a copy: exactly the 17), so
**Download Detail** re-fetches them with the phone in front. **To check:** after that download, the
Oct 8 run's heart-rate chart should be dense and its zones filled.

**19. ~~Partial routes on interval-style Apple Workout-app recordings.~~ — done 2026-10-14, confirmed by the user.** 3 runs (Oct 2, 5, 8 2025) had routes covering 0–17% of the workout
(27 s of 48 min, 15 of 90 min, 57 s of 30 min); every other route covers ≥ 98%. Measured live:
Health Auto Export's `get_workouts` sends only one piece of these routes — the Oct 8 piece starts
3 s after the first of its 8 `activities` ends — and no HAE tool returns the rest. Strava has the
full tracks. Fixed: a route covering under half its workout, on a workout linked to Strava, is
replaced by the activity's `latlng`/`altitude`/`time`/`velocity_smooth` streams (2 read requests) —
once for the stored ones when Strava is connected, and after any detail download. Checked live:
Strava's tracks span 51/30/91 min, start at the workout's start, and match HAE's piece within 4 m
at the same timestamp. Unlinked partial routes show "Route incomplete — Health Auto Export sent N
of M" in the inspector. **To check:** open MaxAct (Strava connected); the three runs' maps, splits
and moving pace should be whole.

Follow-up the same day: 9 more partial routes in September 2025 (after the library grew to 464).
Every HAE path returns the same single piece — MCP at any aggregation, with or without metadata, a
whole-day window (no neighbouring workouts to stitch), and HAE's manual JSON and GPX export (28
points, 17:45:13–17:45:40, exactly interval 3 of the run's 28). All 9 are on Strava (with maps) but
weren't linked, since no Strava check had run since September was imported; the Strava check now
fills partial routes on workouts it newly links. Reported to HAE as issue 21.

**20. ~~Missing descent.~~ — done 2026-10-15, confirmed by the user.** — Health has no
descent for any Apple Workout-app recording (36 of 36) nor for 59 of 428 WorkOutDoors ones; 20 lack
ascent too. The inspector now estimates what's missing, marked "≈" with a tooltip: descent =
recorded ascent + (start height − end height), else both summed from the route's heights. Measured
against the 347 workouts reporting both: the first rule's typical error is 2 m (p90 6 m), the
route sum's 5 m (p90 17 m; it under-read the marathon's ascent by 28%). The Oct 12 2025 marathon
shows ≈ 269 m beside its 268 m ascent (checked on a real copy). Only the inspector; statistics
still total recorded ascent.

**22. ~~Flag data that was repaired.~~ — done 2026-10-15, confirmed by the user.** — each saved
series now records its repairs (`SeriesProvenance`: route from which Strava activity and what the
export had sent; heart rate from `get_health_metrics` and how many readings the export had), and
the inspector shows them ("Route from Strava — Health Auto Export sent only 27 secs. of 42 mins").
Repairs made before this left no record, so on first launch the 36 Workout-app workouts (picked
as the source of the Strava-filled routes, recognisable by their missing GPS accuracy — measured
exactly 36 of 464) go back to needing detail; **Download Detail** (phone in front, Strava
connected) re-fetches them and records the repairs. Not yet a sidebar filter — add one with 21 if
finding them by eye proves tedious.

**23. ~~Similar routes in the inspector.~~ — done 2026-10-24, confirmed by the user.** — a "Same
Route" section under the inspector's stats gives how often the route was done, the fastest (time,
pace, date), this one's rank by time, and time per attempt over the dates. Decided with the user:
the same route means the same kind and mostly the same path in the same direction. Matching is
measured (see §8, 2026-10-23): ends within 200 m, at least 80% of each route within 50 m of the
other in order, and ranking by time. Checked on a copy: the newest commute 92 times, 69th; a run 4
times, 3rd. Extended the next day: pointing at an attempt shows its exact date, time and
duration, and clicking it opens that workout and scrolls the table to it (`AppModel.reveal`). If
a search or filter hides it, the table goes back to All Workouts. Going back is issue 32.

**30. ~~`testPointingAtAChartHighlightsTheMap` failed.~~ — done 2026-10-23.** — "Pointing at a chart
didn't put a marker on the map", every run, on `main` too. The app was fine: the user checked it by
hand. Measured: the window was 780 pt tall (y 471–1251) and the heart-rate chart sat at y 1190–1320,
so the hover at its centre (y 1255) landed 4 pt outside the window. Scrolling the inspector from the
test didn't move the chart. Fixed in the test: if the chart reaches below the window, drag the
bottom edge down by the shortfall (109 pt here), then assert the chart is inside before hovering.
The fix passed. Disabling `.chartXSelection` in the app made it fail again, so it still checks the feature.

**26. ~~Simpler "already on Strava" text.~~ — done 2026-10-23, confirmed by the user.** — the
inspector's note for a workout found already on Strava said "Already on Strava — uploaded from
another app, most likely the watch." The guess about the watch was dropped; it now reads "Already
uploaded to Strava." (`DetailPane.swift`).

**16. ~~Mark races on Strava.~~ — done 2026-10-14, confirmed by the user.**

Measured on the user's account: Strava's "Race" is `workout_type` — a race run reads 1, an ordinary
run 0, a walk has none — and `PUT activities/{id}` with `workout_type: 1` set it on the April 26,
2026 run (read back as 1, shown as Race on Strava). Built: a **Race** tag, Strava-backed like
Commute and Trainer, for runs (1) and rides (11 — Strava's documented value, not yet seen live);
on other sports it stays Mac-only. Sent in the post-upload `PUT`; tag edits push it; the Strava
check mirrors it back (so already-raced activities gain the tag). Removing the tag only clears a
race — a Long Run or Workout set on Strava is left alone (one read to check). 8 new package tests,
mutation-checked.

**17. ~~Import a specific month.~~ — done 2026-10-14, confirmed by the user.**

The sync panel's Import menu has "A specific month…", with Month and Year pickers back seven years,
the estimate for that month, and no way to pick one that hasn't started. `SyncPlanner.month(_:of:)`
gives the month's local span (ending now for the current month); 3 package tests, including a DST
month. Labelling its pickers for VoiceOver also fixed the existing Import menu, which had no
accessible name.

---

## 3. Seeded UI tests

### Seeded UI tests — done 2026-09-20

`SampleData` in `MaxActCore` generates deterministic synthetic workouts, and
`--ui-testing-seed <n>` plants them in the throwaway in-memory store at launch (only alongside
`--ui-testing`, so it can never reach the real database). `SeededTableUITests` covers scrolling,
the three thumbnail placeholder states, thumbnail rendering, row selection, select-all with the
aggregate summary, and sidebar filtering.

Two decisions that made these worth having:

- **Real coordinates.** Routes are laid over Vancouver, because `MKMapSnapshotter` returns blank
  ocean tiles for the middle of nowhere and any assertion about a rendered thumbnail would pass
  without meaning.
- **Assert on the placeholder state machine, not pixels.** The renderer falls back to drawing the
  polyline alone when tiles can't be fetched, so an image appears either way and the tests hold
  offline — while a *hang* still produces no image and fails.

**What these do and don't catch, checked rather than assumed.** Reintroducing the indoor-icon bug
makes `testThumbnailPlaceholdersDistinguishTheirThreeStates` fail, so that one is real. But
removing `withExtendedLifetime(snapshotter)` — the change made while chasing thumbnails that never
appeared — leaves `testSeededRoutesRenderThumbnails` **passing**, which means that fix was not the
cause of the original hang and the test does not discriminate on it. The real cause was more
likely the throttle rewrite or the `.task(id:)` retry landed in the same round. Neither is pinned
down.

Still uncovered:

- **Detail arriving after first render** — the `.task(id:)` retry bug. Seeding is static, so no
  test watches a thumbnail appear once a series lands. Would need the seed to add a series on a
  delay, or a test hook to trigger a detail fetch.
- **The table-cell environment crash** is exercised by the scroll test, but that was never
  confirmed to reproduce it either; the fix removed `@Environment(AppModel.self)` from the
  codebase entirely, so the original condition can't be restored to check.

---

## 4. Original context and research

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

## 5. Original architecture sketch

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

## 6. Phase write-ups, 0–7

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

### Phase 5 — Detail view *(complete)*

Map, stats grid, three Swift Charts — heart rate, pace or speed, elevation — and per-kilometre
splits, all fed by `WorkoutSplits` and `WorkoutCharts` in the package so the view only draws.

**Splits had to be computed: the MCP path carries no lap or split data.** (`.hae` files do, under
`intervals.splits` — another argument for that reader.) Three things produced visible nonsense
when done the obvious way, and each is now a measured decision recorded in `WorkoutSplits`:

- **Distance is scaled to the workout's own total.** Summing raw 1 Hz steps overstates distance by
  4.5–12.9% even after `RouteQuality` filtering, which moves every kilometre mark.
- **Split time is moving time.** Elapsed time put a 51.7-minute pause inside one kilometre and
  rendered it as "57.80 min, 1.0 km/h". Excluding long gaps alone wasn't enough either — a rider
  stopped at lights is still sampled at 1 Hz, and 14 minutes of one ride sat in no gap at all.
  Splits now sum to within a few percent of HAE's `duration`, which is the check worth having.
- **Elevation gain needs smoothing *and* hysteresis.** Raw rising deltas claimed 590 m of climbing
  on a walk that gained 43 m. A 61-sample moving average got it to 53 m; adding a 1 m threshold
  gives 45 m against HAE's 43, and 8 against 10 and 83 against 77 on the other two workouts that
  report the figure.

Two chart decisions worth the same treatment:

- **Nothing is drawn across a pause.** Series are split into segments at gaps over 60 s, because
  one line spanning a 51.7-minute stop asserts a steady heart rate and altitude right through it.
- **Pace is its own series on a reversed axis, not a relabelled speed axis.** Plotting speed and
  formatting the ticks as pace looked fine until a slow walk exposed it: every tick below about
  1 m/s converts to a pace beyond 30 min/km, and the chart came out with one label and two em
  dashes.

And one feature that measurement removed: the **heart-rate min–max band**. HAE's `{Min, Avg, Max}`
buckets argue for drawing the range each point flattened, but at the `"seconds"` aggregation we
request for detail, min, avg and max were **identical in all 2,580 samples** across five workouts —
a 5-second bucket holds one watch reading. The band is emitted only when it spans ≥1 bpm, so it
would appear for a coarser aggregation without costing anything now.

Accessibility: each chart is one element with a spoken summary ("136 to 170 bpm over 36 minutes,
2 pauses") rather than several hundred unlabelled marks; split rows combine into one phrase; the
pace bars are hidden from VoiceOver since the numbers beside them already say it.

Not done, deliberately: **Liquid Glass on floating map overlay controls.** There are no map overlay
controls yet, and inventing some to have somewhere to put the material would be backwards. Revisit
if the map gains real controls.

### Phase 6 — Approximate location *(complete)*

`PlaceGrid` in the package snaps a route's first fix to a ~1 km grid; `PlaceResolver` (an actor in
the app, where MapKit belongs) turns cells into names and caches them.

**Snapping happens before the request, not just before storage — and that turned out to matter
more than the plan assumed.** Reverse-geocoding an unsnapped start returns the *street address*:
measured, a real coordinate came back as `4629 Haggart St, Vancouver`. So the precise point must
never reach Apple either, and the resolver reads only `cityWithContext(.automatic)`, never
`name`/`shortAddress`/`fullAddress`, which all leak the address.

The plan's `cityName` + `regionCode` recipe doesn't work: **`regionCode` doesn't exist** on
`MKAddressRepresentations` despite being documented. `cityWithContext(.automatic)` gives MapKit's
own localized `"Vancouver BC"` directly, which is better than reassembling parts — it reads
correctly outside Canada. `cityName` is the fallback, and a start over water returns an **empty
string** rather than nil, which would otherwise be stored as a blank that never retries.

Measured against the real library: stored cells sit **132–491 m** from the true starts (704 m worst
case over a sampled grid), and five workouts collapsed to **three distinct cells**, so caching
already saved two of five requests. That is the mechanism that makes a seven-year corpus cost a
request per *place* rather than per workout.

Throttling is defensive rather than observed: a request measured ~0.1 s and five back-to-back
lookups all succeeded with no sign of a limit. Apple documents a limit without publishing it, so
the resolver still spaces requests a second apart, backs off on failure and gives up after three
consecutive ones.

Two things the plan didn't anticipate:

- **Everything synced before Phase 6 needed backfilling.** The coordinate is snapped at upsert,
  when a route is in hand, so existing workouts had routes on disk and no cell.
  `backfillPlaceCoordinates` reads the stored series for those, which is why the feature worked on
  the existing 33-workout library without a re-sync.
- **Geocoding is off under `--ui-testing`.** A test suite that depends on Apple's geocoder fails on
  a train. The three Place states are still covered offline, since indoor-versus-not-yet is local.

The column distinguishes a resolved name, **indoor** (no route, so never a place — an em dash there
reads as "still loading"), and not-yet. Same distinction the thumbnail placeholder gets right.

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

**Tags — partially possible, and worth building either way.** *(researched 2026-09-20, not yet
verified against the live API)*

Strava's UI exposes two different things that both look like tags, and only one is reachable
programmatically:

| | In Strava's UI | In API v3 |
|---|---|---|
| **Commute** | checkbox | **`commute`** on `PUT /activities/{id}`, integer `1`/`0` |
| **Trainer / indoor** | checkbox | **`trainer`**, same shape |
| **Activity Tags** — With Kid, With Pet, Recovery, For a Cause | tag picker | **No documented field.** Nothing in `UpdatableActivity` or `DetailedActivity`. App/website only. |

Two consequences for the uploader:

- **Flags need a second call.** Multiple reports say the multipart upload body honours `name` and
  `description` but silently ignores `commute`, `trainer` and `sport_type`. So setting them means
  upload → poll to completion → `PUT /activities/{id}`. That's an extra **write** per workout on
  top of the existing POST, against the overall 200/15 min budget, so a tagged batch upload runs
  meaningfully slower than an untagged one. Only issue the `PUT` when something actually needs
  setting.
- **Re-verify before building.** Strava has been adding tags recently and the set is still rolling
  out unevenly, so a tags field may appear. Check `DetailedActivity` on
  `developers.strava.com/docs/reference/` at the start of Phase 7 rather than trusting this table.

**Therefore: build tagging as a local feature, and sync the subset Strava accepts.** This is worth
doing regardless of what the API supports, because tags are how you'd actually want to filter and
batch-operate on seven years of workouts.

- A `Tag` model with a name and colour, and a many-to-many against `WorkoutRecord`. Local state,
  so Phase 3's rule applies: a re-sync must never drop tags.
- Two built-in tags, **Commute** and **Trainer**, marked as mapping to Strava's boolean fields.
  Everything else is local-only.
- Batch editing from the list: a Tags submenu in the context menu and the toolbar, applying to the
  whole selection. This is the feature that makes tagging worth having — tagging 400 commutes one
  at a time is not a thing anyone will do.
- Tags become sidebar filters alongside the saved filters, and join the `.searchable` fields.
- For local-only tags, optionally append them to the Strava **description** on upload (e.g.
  `#withkid`), behind a setting. That is the only honest way to get them across today, and it is
  lossy — worth offering, not worth pretending it is real tag support.

**Mute on upload — to check, and to build alongside tags.** *(added 2026-10-07)*

Strava's "Mute Activity" keeps an activity off followers' home feeds. It is in the API:
`hide_from_home` on `UpdatableActivity`, documented as *"Whether this activity is muted"* (spec
checked 2026-10-07). It is **not** an upload parameter — `POST /uploads` takes only `file`, `name`,
`description`, `trainer`, `commute`, `data_type` and `external_id` — so muting means
`PUT /activities/{id}` once processing finishes.

That is the same call the uploader already makes to correct the sport for anything but runs and
rides, so the cost is small and the shape obvious: **fold every post-upload change into one
`PUT`** — sport type, mute, and later any tag-derived flags — and skip the call entirely when
nothing needs changing. For walks and hikes muting is then free; for runs and rides it adds one
write against the 200 / 15 min overall budget.

Why it matters most here: a multi-year backfill could put hundreds of old workouts in front of
followers. Whether backdated uploads actually appear in feeds at all is **unverified** — check it
on the live run before deciding the default. Likely shape: a Settings toggle ("Mute uploaded
activities"), on by default for batch uploads, plus a per-batch override in the upload action.

Things to confirm live: that `hide_from_home` takes effect via `PUT` for an app with
`activity:write` (some fields are owner-only in the UI); that it can be set as soon as
`activity_id` appears, rather than after Strava's own post-processing; and whether muting after
the fact still briefly shows the activity in a feed — if so, muting can't fully prevent the
notification, and the setting's description should say that.

**Tests:** golden-file TCX; the rate-limit actor under a simulated 429 and header sequence; the
duplicate-activity response path; token refresh on 401; tags surviving a re-sync; batch tag apply
and remove over a selection; and that a workout with no flag changes issues no `PUT`.

---

## 7. Original risk table

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

## 8. Change log

- **2026-10-24** — Same Route polish, from the user: the chart's tooltip now gives the attempt's
  rank ("3rd of 4", the section's wording; `RouteHistory.rank(of:)`, mutation-checked). A jump no
  longer scrolls the table sideways: `scrollTo(_:anchor: .center)` centred the row horizontally
  too, by 95 pt (measured), hiding the thumbnails under the sidebar. It now anchors at
  `UnitPoint(x: 0, y: 0.5)`. The UI test compares the Date column's x before and after, and fails
  with `.center`. Full suite 58 passed, 3 skipped.

- **2026-10-24** — **Issue 23 closed**, confirmed by the user. Extended (UI test, mutation-checked; full suite 58 passed, 3 skipped): the Same Route chart's
  points show their exact date and time on hover and open their workout on click. The table
  scrolls to the row (`ScrollViewReader` around the `Table`). Planned 32: Back to the previous
  selection.

- **2026-10-23** — **Issue 23 built: Same Route in the inspector.** Measured on a copy (479 routes,
  12,290 same-kind pairs with ends within 500 m):
  - **Fréchet distance was rejected.** It's a worst case, so GPS scribble at a walk's destination
    pushed identical routes past 300 m while different loops sat at 420 m.
  - **Ordered overlap was chosen**: the share of each route within 50 m of the other at about the
    same share of the way along (±15%). It splits cleanly: 7,798 pairs ≥ 90%, a valley of 55–80%,
    and drawings showed 80–90% to be the same commute with a different end block. The user picked
    80%.
  - **Direction:** 12 loop pairs match only when reversed, and the aligned window rejects them.
  - **Ends:** 99% of matching pairs start within 98 m and finish within 73 m, so the limit is 200 m.

  `RouteMatcher` and `RouteHistory` in `MaxActCore` (10 tests, three mutation-checked). They agree
  with the Python measurement on 8,166 of its 8,184 pairs, with none extra. A lookup
  against 226 rides went from 0.42 s to 0.07 s (debug): plain arrays, the latitude cosine
  applied per comparison (a per-point projection was off by up to ~80 m east–west and lost pairs),
  an outward search and an early exit. Sketches are prepared once per load. The inspector shows a
  progress line while sketches build. Under XCTest, building 479 took 4 min 20 s against ~16 s
  without it. Seeded UI test, plus a real-content test (skipped without a copy). The section
  pushed the charts below the window, so `testInspectorShowsTheWorkoutsHeartRateZones` lost the
  chart it scrolled over. It now scrolls over a fixed point in the inspector.

- **2026-10-23** — Order set by the user: 23, then 24, 25, 29 and 31; the audits (27, 28) last, when
  the app is close to finished.

- **2026-10-23** — **Issue 30 fixed** (in the test: the hover pointed below a too-short window).
  How to avoid it is recorded in the Xcode conventions reference.

- **2026-10-23** — Planned 31: colour a workout's route by elevation, heart rate or pace, with the
  heatmap kept in the flat route colour.

- **2026-10-23** — **Issue 26 closed**, confirmed by the user.

- **2026-10-23** — **Issue 26 built:** the inspector's duplicate note now reads "Already uploaded to
  Strava." Build clean, 344 package tests pass. UI run: 55 passed, 2 skipped, 1 failed. The failure is
  `testPointingAtAChartHighlightsTheMap`, which fails on `main` too and is filed as 30.

- **2026-10-23** — Planned 29: click the route heatmap to open a workout in the inspector; then a
  list when the click lands on many overlapping routes.

- **2026-10-23** — **Issue 21: data for HAE.** Made a zip of three Workout-app interval runs (2025-09-17,
  10-02, 10-08). Each run has HAE's `get_workouts` and `get_health_metrics` replies, unmodified, plus a Strava
  GPX with a privacy zone removed, and a README. Measured: each exported route is exactly one `activities[]`
  entry. Oct 5 and Sept 5 were rejected because their HAE route pieces show the finish or pass home. Found
  for 28: the HAE token is stored in UserDefaults.

- **2026-10-23** — Planned 27 (code quality audit) and 28 (security audit), each producing a
  findings list to triage before changes.

- **2026-10-15** — **Issue 22 closed**, confirmed by the user. Planned 26: drop "most likely the
  watch" from the inspector's already-on-Strava text.

- **2026-10-15** — **Issue 20 closed**, confirmed by the user. **Issue 22 built: repairs recorded
  and flagged.** `SeriesProvenance` (optional in the blob, so old series decode — tested) is set by
  the heart-rate fallback and the Strava route fill; the inspector shows a note per repair. Past
  repairs left no record: Strava-filled routes are recognisable (no GPS accuracy — exactly 12 on a
  copy) but metrics-filled heart rate isn't, so the user chose a one-time re-download of the
  workouts sharing those routes' source (36, all Workout-app recordings) to record them exactly.
  Seeded workout 0 carries both repairs for a UI test (mutation-checked, as is the selection).
  344 package tests, 58 app and UI tests (2 real-content skipped).

- **2026-10-15** — **Issue 20 built: estimated ascent/descent.** Measured on a copy (464
  workouts): descent missing on all 36 Workout-app recordings and 59 WorkOutDoors ones. Two
  estimators against the 347 reporting both: route-summed descent (median |error| 5 m, p90 17 m,
  p99 83 m) and recorded ascent + net drop (2 m, 6 m, 15 m) — the second used where an ascent
  exists. `ElevationEstimate` in the package (3 tests; the formula mutation-checked); the inspector
  shows "≈" values with an explanation. Marathon: ≈ 269 m (real copy). A synthetic-route test first
  failed because 61-point smoothing rounds a sharp peak (72 m for 80) — a test tolerance issue, not
  a code one. 341 package tests, 57 app and UI tests (2 real-content skipped).

- **2026-10-15** — The user confirmed the Strava check filled the September routes. Planned: 22
  (flag repaired data, for re-doing once HAE fixes 21), 23 (similar routes in the inspector), 24
  ("Everything" is capped at 7 years — make it unbounded), 25 (app icon). Issue 21 stays open.

- **2026-10-14** — The user sent the HAE bug report (issue 21). Paused; next is ⌥⌘U to fill the 9
  September routes, then issue 20.

- **2026-10-14** — **Issues 18 and 19 closed**, confirmed by the user. The user found a partial
  route on 17 Sep 2025 and asked whether HAE could supply the rest. Measured: no — every
  `get_workouts` variant and HAE's manual GPX/JSON export give the same one-interval piece; 9
  September Workout-app runs are partial, all on Strava but unlinked. The Strava check now fills
  partial routes for workouts it newly links. Drafted the HAE bug report (issue 21).

- **2026-10-14** — **Issue 19 fixed (partial Workout-app routes); issue 20 noted** (no descent on
  some workouts, e.g. the Oct 12 2025 marathon). Measured on a copy: 3 routes cover 0–17% of their
  workout, the rest ≥ 98% — cut short, not sparse (1 s fixes, cleaning dropped none). A raw
  `get_workouts` with routes returned the same fragments (Oct 8: 12:22:04–12:23:01 of a 12:06–12:37
  run; Oct 2: 26 s mid-run), both interval-style recordings with 8 and 20 `activities`. Strava's
  streams have the whole tracks. Built: `StravaClient.route(ofActivity:)`, `routeIsIncomplete`
  (under half the duration), a once-per-library fill when Strava is connected plus a fill after
  each detail download (re-downloads bring the fragment back), thumbnail and digest invalidation,
  and an inspector note for unlinked partial routes (checked on a real copy: "sent 26 secs. of 48
  mins."). Live check: tracks span the workouts, 0 s start offset, ≤ 4 m from HAE's fragment at the
  same time. A new no-GPS test caught a real bug (a count mismatch threw instead of returning no
  route); timing mutation-checked. 338 package tests, 57 app and UI tests (2 real-content skipped).

- **2026-10-14** — **Issue 15 closed**, confirmed by the user. **Issue 18 found and fixed:** the
  user saw missing heart rate for 8–21 Oct 2025. Measured: not a date range but a recording app —
  17 of the 18 Apple Workout-app workouts (all of them in 1–21 Oct 2025) had one reading per ~10
  minutes; all 400 WorkOutDoors workouts have 5 s. Strava's stream for the Oct 8 run: 1,825
  readings at 1 s. A raw `get_workouts` reply (curl; Homebrew Python is blocked by Local Network
  privacy — "No route to host" while ping and curl work) had 3 `heartRateData` entries at either
  aggregation, non-integer averages with `sampleCount: 1`, while steps and energy were per second:
  the export averages the Workout app's series-sample chunks. `get_health_metrics` had 367 readings
  at 5 s. Built: the detail fetch falls back to it for sparse heart rate; a one-time pass marks
  stored sparse workouts as needing detail (exactly the 17, on a copy); re-downloads invalidate
  the cached digest. Checked live: 353 readings for the Oct 8 run in 4 s. 5 package tests,
  mutation-checked (fallback skipped; device filter dropped). Opened 19 (thin Workout-app routes).
  335 package tests, 57 app and UI tests (2 real-content skipped).

- **2026-10-14** — **Issue 15: heart-rate zones in the workout inspector** (the user's request).
  The zone breakdown is now one view, `HeartRateZoneBreakdown`, used by the Statistics section
  and by the inspector, which shows it below the charts for the selected workout (from its own
  series, so a profile change shows at once). UI test, mutation-checked; checked on a copy of the
  real library at the inspector's narrowest width. That check showed 32 min of readings for a
  28:14 ride; measured, not a bug — its recording runs 32:25, and the workout's duration leaves out
  pauses. Over all 417 workouts with heart rate, zone time never exceeds the recording. The
  footnote now says it's recording time. One full-suite run failed
  `testPointingAtAChartHighlightsTheMap` on an XCTest snapshot error; it passed on rerun (a flake,
  not this change). 330 package tests, 57 app and UI tests (2 real-content skipped).

- **2026-10-14** — **Issue 15: heart-rate zones built** (the user chose zones by heart-rate
  reserve). Measured first on a copy of the series: all 418 workouts carry heart rate (174,683
  readings, median gap 5 s, 99th percentile 13 s; gaps over 30 s total 30.7 h of 275 h, so they
  count nothing). `SeriesDigest` (cache version 2) now holds each workout's sketch *and* a
  bpm histogram, read in one pass; `HeartRateZone.byPeriod` buckets them like the history chart.
  Two test-tooling findings: `-key value` defaults passed after `--ui-testing` are swallowed
  (AppKit pairs `-ui-testing` with the next token and opens the stray value — no window), so
  `launchMaxAct` now takes `defaults:` placed before it; and modifiers on a `GridRow` apply to
  every cell, so a row's accessibility element goes on its first cell. UI test mutation-checked.
  330 package tests, 56 app and UI tests (2 real-content skipped).

- **2026-10-14** — The full suite caught two personal-best tests clicking a moving target: the
  Routes section first showed a one-line "Preparing routes…", then grew 380pt when the map arrived,
  pushing the cards below it down mid-click. Routes now sits last in Statistics and reserves the
  map's height while preparing. 326 package tests, 55 app and UI tests (2 real-content skipped).

- **2026-10-14** — **Issue 15: route heat map built.** Measured first on a copy of the series
  (418 routes, 926k points): 7.4 s to load, 1.7 s to simplify to 72k points, 83 explorer squares;
  half of all workouts start within 70 m of home but 10% more than 1,600 km away. So sketches are
  cached, and routes are grouped into places. The real-content check took three tries: fitting the
  whole place showed Vancouver-to-Seattle (one Victoria trip stretched it), so the map frames the
  2nd–98th percentile; that still spanned the strait, because a 100 km place radius merged
  Vancouver with Victoria (~95 km, with real workouts in both) — now 25 km, and the map opens on
  Vancouver's routes. Verified the cache stays beside the series (inside the test copy, never the
  real folder). Squares are counted from the full route (mutation-checked: from the simplified one,
  a straight ride loses its middle squares).

- **2026-10-14** — **Issues 16 and 17 closed**, confirmed by the user (Race tag round-trips with
  Strava; specific-month import works). Back to issue 15.

- **2026-10-14** — **Issue 16 built: Race tag mirrored to Strava.** Read-only first: the 2025-10-12
  marathon reads `workout_type` 1, the day-before run 0, a walk null. Then, with the user's go-ahead,
  `PUT workout_type: 1` on the April 26, 2026 run (uploaded by MaxAct) succeeded and read back 1.
  The first attempt found no activity — the run hadn't actually been uploaded yet; the script
  stopped without writing. Token read once from the Keychain (user approved the prompt) after
  MaxAct refreshed it, so the stored refresh token was never rotated outside the app.

- **2026-10-14** — **Issue 17 built: import a specific month** (the user's request, to make issue 16
  checkable). Mutation-checked: without the "hasn't started" guard a future month builds an interval
  ending before it starts, and Foundation traps. UI test found the Import menu had no accessible
  name; and that `labelsHidden()` plus `.accessibilityLabel` reads "Year, Year". One run hit
  "Timed out while enabling automation mode" — macOS, not the app; a retry ran normally.

- **2026-10-14** — Recorded issue 16 (the user's request): check whether Strava's API can mark an
  activity as a race (`workout_type`). Research first; the user is downloading detail meanwhile for
  issue 15's route heat map.

- **2026-10-14** — **Issue 15: training load built.** Measured first: all 49 workouts have an
  average HR, highest max 182, history only seven weeks (Fitness is still ramping — the view says
  so). The user chose to be offered both TRIMP curves and asked on first use. UI-testing found three
  real bugs: unset rates displayed as "0" rather than the prompt; the inline fields wrapped in a
  nested `Form` scrolled out of reach; and the curve picker had no accessibility label (VoiceOver
  heard a bare "Choose…"). The reading dots' tint didn't apply (all grey) — now drawn circles.

- **2026-10-14** — **Issue 7 closed**: TrainingPeaks' API isn't available for personal use
  (confirmed on its Partner API FAQ). The user chose to drop it rather than add Export TCX…;
  findings in §2. Next: issue 15.

- **2026-10-14** — **Phase 8 complete**, checked by the user (welcome sheet, Test Connection, empty
  states, remembered sidebar and sort; sync error wording untestable while sync works). The
  statistics deferred from issue 8 (training load, HR zones, route heat map) had left PLAN.md along
  with issue 8's diagnosis — the user noticed; restored as issue 15. Lesson: when moving a fixed
  issue to §2, carry anything still open back into PLAN.md.

- **2026-10-14** — The user confirmed Test Connection works against their phone after the timeout
  fix.

- **2026-10-14** — **Test Connection timeout fixed.** The user saw HAE's log answer a few seconds
  after MaxAct declared a connection problem. Measured on the real phone: handshake 0.05–0.6 s;
  listing 1 day ~3 s, 7 days 11–16 s, 14 days 19–21 s — past the single 15 s limit, which was a
  guess (only the *absent*-phone case had been measured). Now the handshake alone has a 10 s
  deadline, the listing gets 90 s with a progress line, and the lookback is one week. Live check
  after the fix: success in 11.5 s, 5 workouts. New test for a slow listing; mutation-checked.

- **2026-10-14** — **Phase 8 built.** Surveyed first: much existed (a one-screen setup guide, a
  token-vs-network split), but every empty filter said "No Results for ''", an empty sync said "No
  new workouts", unreadable workouts vanished, raw errors leaked ("MCP error -32600"), load errors
  were never shown, and nothing was remembered across launches. The user chose a welcome sheet with
  Test Connection and remembering sidebar + sort. `SyncProblem` and `ConnectionCheck` in the package
  (9 tests); the URLError mapping was measured with `URLSession` (closed port → cannotConnectToHost,
  silent address → timedOut, bad name → cannotFindHost). The test connection's timeout is 15 s —
  the transport's default is 600 s, which would have left an absent phone "checking" for ten
  minutes. Sort-key properties made `nonisolated` so `KeyPathComparator` accepts them. New hosted
  unit tests (7) and UI tests (4), all mutation-checked. 303 package tests, 52 app and UI tests.

- **2026-10-14** — **Issue 8 closed**: the user confirmed the inspector over the statistics (8a/8d).
  Diagnosis moved to §2. Next: Phase 8.

- **2026-10-14** — **Issue 8d: the inspector is back over the statistics**, drawn as a panel inside
  their own column rather than as the window's split-view inspector, so nothing gets pinned.
  Replaced `InspectorCommands()` with our own ⌃⌘I command (the system one drives the real
  inspector's binding, held shut over the statistics). Statistics scroll sideways below 480pt.
  First test run mis-measured the panel (its identifier lands on an inner element) — screenshots
  showed it right; the test now measures by edges. Mutation-checked: letting the real inspector open
  over the statistics cuts the sidebar off by 105pt. The 8c sheet header (done earlier today) is
  superseded along with the sheet.

- **2026-10-14** — Issue 8c: the personal-best sheet is headed by the record ("Longest — 11.66 km")
  instead of repeating the activity and date. The best's title and formatting moved to an
  extension on `PersonalBest`, shared by the cards and the sheet. UI test extended and
  mutation-checked (a sheet headed "Cycling" fails it).

- **2026-10-12** — The user confirmed the issue 8 layout fixes work, and asked for 8d: explore
  putting the inspector back over the statistics (scrolling sideways if needed), keeping the sheet
  if that proves impossible. Recorded with first ideas; paused.

- **2026-10-12** — The user checked the issue 8 layout fixes and asked for one change, recorded as
  8c: the personal-best sheet should name the best at the top rather than repeat the workout's
  activity and date.

- **2026-10-12** — **Issue 8a/8b fixed** (awaiting the user's check). The user chose a sheet for a
  personal best's workout; the inspector is now kept shut while Statistics is showing. Reverted the
  partial workarounds the sheet made unnecessary (inspector inside the column, a raised window
  minimum); kept pulling the window back on screen when its minimum grows. UI test
  `testStatisticsKeepTheirLayoutAndOpenABestInASheet` mutation-checked (letting the inspector show
  over the statistics brings back the cut-off sidebar). Hosted unit tests check every section's
  narrowest width.

- **2026-10-12** — Issue 8a: the time-boxed AppKit-host attempt (statistics in an `NSScrollView`)
  failed — same frozen width — and was reverted. Back to the user for the fallback.

- **2026-10-12** — Issue 8a: root cause found. A temporary layout dump showed SwiftUI pinning the
  detail column's minimum to its current width when the inspector opens beside SwiftUI content
  (a plain colour does it; the table doesn't). Ruled out by experiment: content, scroll view,
  `ViewThatFits`, toolbar, search field, subtitle, `navigationSplitViewColumnWidth`, how the
  inspector opens. Also found and removed two stale `xcodebuild` copies of the app registered with
  the same bundle id, which UI tests launch by identifier. Scheme now never records the screen.
  Partial fixes on `issue-8-layout`; not merged.

- **2026-10-12** — Issue 8a/8b in progress on `issue-8-layout`. The user chose to keep the
  inspector beside the statistics. Wrote the UI test first; it measured the inspector opening at
  40pt. Made every section reflow (8b), which brought it to ~260pt, then traced the rest by
  experiment: in statistics mode the detail column holds ~920pt with the inspector open regardless
  of content, scroll view, subtitle or how the inspector opens, while table mode shrinks correctly.
  A `List` host quit the app. Also measured: the totals footnote's *ideal* width is 1,114pt (one
  line). Paused with 8a open; branch not merged, its layout test failing as expected.

- **2026-10-12** — The user checked issue 8: the statistics work. Two problems recorded in
  `PLAN.md` as 8a (a personal best opens a narrow, fixed-size inspector that fights the sidebar
  for space) and 8b (a narrow window neither reflows nor scrolls the statistics). Paused there.

- **2026-10-12** — **Issue 8 built: statistics.** Researched HealthFit's statistics; the user chose
  the summary-based set (period totals and history, year comparison, calendar heat map, personal
  bests), ISO weeks, and a sidebar row. `WorkoutStatistics` + 14 package tests, mutation-checked
  (missing-as-zero, streak through today, best year drawn twice, UTC instead of local day). Measured
  first: the real library is 49 workouts since 2026-08-23; 5 lack climb; rides auto-pause (26 of
  38 have span > duration) while walks don't, so "Time" is labelled as recorded duration. Streaks
  took 154 ms per pass with `Calendar` stepping, even in release; integer day numbers made it 9 ms.
  Checked on a copy of the real library — totals match SQLite to the kilometre — which caught a heat
  map drawn as hairlines (`RectangleMark` on a date axis; now a grid of shapes), grey bars
  (`accentColor` in a chart), a "best year" claimed with one year of data, and personal bests
  missing from accessibility (`LazyVGrid` below the fold). Xcode's MCP tools stopped responding
  mid-session, so builds and tests ran through `xcodebuild`; its default records the screen on a
  failure, which captured two recordings (deleted unviewed) before recording was turned off in the
  generated `.xctestrun`. 294 package tests.

- **2026-10-12** — **Added `CLAUDE.md`** with the standing working rules, at the user's suggestion.
  It loads every session, unlike `PLAN.md`, whose §7 rules had been missed (fixed issues weren't
  moved to §2). `PLAN.md` §7 now points to it. New rule from the user: ask, and wait, before any
  UI test run, since it takes over the Mac.

- **2026-10-11** — Paused before issue 8. Dropped a stale PLAN.md limitation (ad-hoc signing
  prompts), fixed by issue 14.

- **2026-10-11** — **Issue 6: charts aligned for real.** The user showed a ride whose plots were
  still offset: y-axis labels of different widths ("km/h" vs bpm) shrank each plot differently.
  Fixed-width y-label column on every chart; "0.0 km/h" instead of "—". The earlier check had only
  looked at a walk, whose pace labels match heart rate's width; the real-content test now selects a
  ride. Verified on a copy of the real library (copy and screenshots deleted). 280 package tests,
  35 app and UI tests (1 skipped without a copy), zero warnings.

- **2026-10-11** — **Issue 6 closed; charts share one time axis.** The user confirmed the linking and
  spotted misaligned axes. The measurement contradicted the hypothesis that heart rate ran longer:
  it's the *shortest* series, starting up to 55 s late, and each chart fitted its own axis. Added
  `WorkoutCharts.timeDomain(for:charts:)` (3 tests) and applied it to every chart; checked on a copy
  of the real library, then deleted the copy and screenshots. 280 package tests, 35 app and UI tests.

- **2026-10-11** — Paused with issue 6 waiting on the user's check on real rides; plan status refreshed.

- **2026-10-11** — **Issue 6 built: charts and map linked.** `RouteLookup` (binary search by time,
  linear nearest-by-coordinate, chart value within the segment spanning a time) with 5 tests
  including pauses; a shared highlighted moment drives a rule and value in every chart and a map
  marker; route clicks judged in screen points. Measured that `chartXSelection` follows hover on
  macOS. The UI test reads the map marker, since chart groups expose no accessibility value to
  XCUITest; it was mutation-checked against broken route clicks. Left open for the user to try on
  real rides. 277 package tests, 35 app and UI tests.

- **2026-10-11** — **Issue 14 confirmed live and closed.** No Keychain prompt after a rebuild that
  genuinely changed the binary — the user's improvement on the first check, which rebuilt with
  nothing changed. The probe change was reverted and its branch deleted.

- **2026-10-11** — **Issue 14: signing with the Personal Team.** The user signed into Xcode and
  had a certificate, but `security find-identity -v` found no valid identity: the certificate's
  issuer, Apple's **G3** developer intermediate, was missing, and the keychain held only the G1
  intermediate that expired in 2023. Downloaded G3 from Apple, verified its fingerprint and that it
  issued the user's certificate, and installed it with the user's approval; the identity became
  valid. Set `DEVELOPMENT_TEAM` on all three targets. The build is signed "Apple Development" with a
  hash-free designated requirement, so Keychain "Always Allow" will persist across rebuilds — to be
  confirmed live.

- **2026-10-11** — **Issue 12 re-examined with real content and fixed properly.** The earlier
  closing that day skipped the check the plan called for. Added `--ui-testing-real-copy` (a copy of
  the real library in the app's temp folder, isolated as for UI tests) and a self-skipping
  `RealContentUITests` that photographs the window. It showed the Strava column cut off whenever
  the inspector was open; moved it after Date, layout key now `workoutTableColumns.v6`. The copy and
  screenshots were deleted afterwards. 35/35 app and UI tests.

- **2026-10-11** — **Issue 12 closed** by the user as fixed enough after the inspector change, with
  no further code change; the remaining narrowness is a Known limitation. Also corrected dates: the
  work of the evening of 2026-10-10 had been recorded as 2026-10-11, and one entry as 2026-10-12,
  across the plan, history, skill references and four code comments.

- **2026-10-10** — Issue 13 confirmed live by the user: the sync check noticed the two rides deleted
  on Strava and marked them not uploaded. Removed from the plan's live checks.

- **2026-10-10 (late night)** — **Plan housekeeping, prompted by the user** asking whether §7 had
  been followed. It hadn't, in one respect: fixed issues 9, 10, 11 and 13 had stayed in `PLAN.md`,
  struck through, instead of moving to `HISTORY.md` §2 — which had grown the plan from ~233 back to
  337 lines. Moved them verbatim (with the sidebar-inset fix that sat under open issue 12), kept
  what remains open from them under Known limitations, and rewrote the stale "Where things stand".

- **2026-10-10** — Place reset closed: the user confirmed the re-resolved places, and the pre-reset
  database backup was deleted at their request.

- **2026-10-10 (late)** — **Borrowing the province for places MapKit gives none**, requested by the
  user after the reset showed UBC rides losing "BC". Places now store city, province and country
  (`PlaceTerms.version` 2), and a local pass after each round of lookups lends a city's agreed
  province to places in that city missing one, declining when places disagree. Measured on the
  user's data from a standalone test process: 3 distinct start cells, one of them province-less in
  MapKit; it now reads "Vancouver BC". **Incident:** a `RunCodeSnippet` run, meant to resolve places
  on a *copy* of the database, launched the full app instead — migrating the user's real database
  and re-resolving their places with unmerged branch code. Harmless in outcome (the same result
  the merged code gives) but not consented to; the pitfall is now in the Xcode conventions
  reference, and live probes use gated `swift test` runs instead.

- **2026-10-10 (night)** — **Two corrections to issue 9.** A clean rebuild surfaced deprecation
  warnings: `CLGeocoder` is **deprecated in macOS 26**, contrary to what issue 9 recorded, and so is
  the obvious alternative, `MKMapItem.placemark`. The earlier warning check had missed it because
  the file hadn't recompiled. There is no supported structured subdivision now, so the resolver uses
  one MapKit request and parses the province from `cityWithContext(.full)`, which measured regular
  across ten places. Measuring those ten also overturned the second claim: an empty
  `cityWithContext` is not a home-country behaviour but a UBC quirk (no municipality). Terms
  version not bumped, so stored places — including UBC's richer CLGeocoder-era terms — are kept.

- **2026-10-10 (evening)** — **⌥⌘U for "Check Strava for Existing Activities"**, beside ⇧⌘U upload,
  and **UI tests no longer touch the Keychain.** The user diagnosed the recurring first-test
  failure: a Keychain password prompt stole focus. Measured with the unified log: one UI test made
  five `SecItemCopyMatching` calls, each able to prompt because every ad-hoc build is a new
  signature to the Keychain. Under `--ui-testing` secrets now live in an `InMemorySecretStore`.
  **Correction, same evening:** the commit claimed zero Keychain calls across the full suite, but
  that had been measured over two UI tests only. Measured over a full run, one lookup remained —
  from the **unit-test host**, which XCTest launches as the full app without `--ui-testing`, so it
  read the *real* Strava entry (the actual source of the prompt) and also opened the real database
  and settings. The app now detects hosting from `XCTestBundlePath` / `XCTestSessionIdentifier` and
  isolates itself the same way; a full run then logged **zero** lookups, 34/34 passing first time.
  The real app's prompts remain until there's a stable signing identity.

- **2026-10-10** — **Sync check now notices activities deleted on Strava** (issue 13). The user
  deleted the two spiked 9/21 rides on Strava; MaxAct kept showing them synced, because the check
  only ever added matches. Measured first: a deleted activity's direct lookup returns 404 "Record
  Not Found". The check now nominates synced workouts missing from its listing, confirms each with a
  lookup, and resets only on a 404 — never on an outage. Limited to the listed window, since the
  upload pre-check lists only the selection's dates. `activity:read_all` is now required at connect
  so a private activity can't masquerade as a deleted one.

- **2026-10-10 (evening)** — **Known issue 11 done.** Printed the 13:00 ride's splits against its raw
  route: a speedless fix 2,516 m out and back, accuracy 27 m, survived the 30 m accuracy rule, and
  its phantom distance broke every split on the ride, not only km 5. Rather than lower the
  threshold to fit one case, measured the whole library: all 10 out-and-backs over 100 m were
  speedless, so the shape itself is now a rule. A first version (neighbours within a quarter of the
  excursion) missed a second real case at 0.28, found by checking what survived; loosened to half,
  which adds exactly two fixes library-wide. Strava's copies of both 9/21 rides predate the fix.

- **2026-10-10 (afternoon)** — **Sidebar inset with the inspector open**, reported by the user, and
  a standing rule to **work on branches**. Measuring the pane frames showed the inset wasn't being
  removed: the content was 1,318pt in a 1,300pt window and SwiftUI centred it, clipping 9pt off each
  side, because the inspector opened at its ideal width and never shrank to fit. Opening at the
  minimum fixed the default window and gave the table 100pt back (issue 12). A minimum window width
  of 1,200 while the inspector is open covers narrow windows; the test drags the window narrow and
  was confirmed to fail without that guard. `showsDetail` moved onto `AppModel` so the scene can
  read it, which kept the window's frame autosave key — and so everyone's saved window position —
  unchanged. The test restores the window width in a teardown block, after a failing run left a
  narrow frame saved into the shared defaults.

- **2026-10-10** — **One window.** The user asked what tabs were for. Nothing: `WindowGroup`
  supplied them, and every window shared the model's filter, search, selection and sync panel, so
  a second tab differed only in scroll position and inspector. Offered removing them or making
  windows independent; the user chose removal. Done with `allowsAutomaticWindowTabbing = false`
  and an empty `.newItem` group, keeping the `WindowGroup` rather than switching to a `Window`
  scene so the hard-won launch behaviour is untouched. Tested on the menus *and* on ⌘N.

- **2026-10-10** — **View ▸ Hide Sidebar with ⌃⌘S**, requested by the user. `SidebarCommands()`
  was tried first and toggled correctly, but its title read "Show Sidebar" in both states, because
  it validates against AppKit's split-view item rather than the SwiftUI binding that owns
  visibility. Replaced with a command that drives the same binding via `focusedSceneValue`, and a
  test that the title flips.

- **2026-10-09 (evening)** — **Known issue 9 done: search by region and country.** Measured both
  geocoders first, which changed the design twice. MapKit has no structured subdivision
  (`regionCode` is documented but absent from the SDK), so Core Location supplies the parts while
  MapKit still composes the visible label. And `cityWithContext` turned out to return an empty
  string for the *device's own region*, not just over water — so a naive fallback would have
  demoted every local label from "Greater Vancouver BC" to "Vancouver" the moment the library
  re-resolved. Composing `locality + administrativeArea` as the second fallback reproduces the old
  label exactly, verified against four countries. Terms are stored folded for case and diacritics,
  and `placeTermsVersion` makes the backfill self-starting at one request per place. Search
  matching moved into `MaxActCore` so the rules are covered by `swift test`. 248 package tests.

- **2026-10-09** — **Phase 7 confirmed live and known issue 10 done.** The user ran the three
  outstanding checks: tag import, tag push on a synced workout, and a tagged, muted upload all
  work. Then built the inspector's toolbar toggle, and made an explicit close stick rather than be
  undone by the next row click. The "sidebar squeeze" the issue was paired with **did not
  reproduce**: measuring the panes found the sidebar keeping its full 217pt and the table dropping
  1,079 → 562pt instead, so stating `columnVisibility` had fixed the collapse itself, not just its
  persistence. A window-widening fix was written, worked, and was deleted — AppKit's frame autosave
  made the width stick, so one selection would have left the window permanently wider, and the
  platform shrinks content instead. The cramped table is recorded as issue 12 with its numbers.
  Two testing lessons went to the skill reference: a squeezed pane still reports `exists`, and
  window geometry is shared with the real app and keyed per display.

- **2026-10-07 (night)** — **Split the plan.** `PLAN.md` had grown to 1,465 lines, mostly
  history. It is now ~230 lines of current status, open issues, decisions and architecture; this
  file holds the rest verbatim. The one durable fact found only in the plan (the
  `MKMapSnapshotter` lifetime bug) moved to the Xcode conventions reference. `HISTORY.md` is
  excluded from the app target like `PLAN.md`.

- **2026-10-07 (late)** — **Tags and mute-on-upload built.** Probed the live API before designing:
  commute and trainer are readable from the activity list, mute only from the full record, and
  "With Kid"-style Activity Tags from neither. Local tags with Commute/Trainer mirrored to Strava
  (imported on every check, sent on upload, pushed when edited, protected by a pending flag); batch
  Tags menu with all/some/none state; sidebar, search, detail chips, optional column; mute as a
  setting folded into the one post-upload `PUT`. Along the way, found the UI suite failing because
  the real app had saved its sidebar as collapsed — the inspector squeezes it out at 1,300pt and
  AppKit remembers that — and the tests share those defaults. The split view now starts with the
  sidebar explicitly shown. A detour worth recording: an apparent "alert clears its binding before
  the button runs" bug was a wrong guess, disproved by reverting the fix; the sidebar was the only
  problem. 233 package tests, 28/28 app and UI tests.

- **2026-10-07 (evening)** — **Phase 7 upload proven live** by the user: the already-on-Strava
  check matched two watch-uploaded rides, and a walk and a ride uploaded correctly (the walk as a
  Walk, confirming the sport `PUT`). Merged to `main`. Then two UI fixes from using it: the found
  rows read "Duplicate" in the detail pane — the internal name for found-already-there — which is
  wrong when there's one copy here and one on Strava. Both states now say **"Synced to Strava"**
  with an **orange check** (Strava's #FC4C02; a tinted symbol rather than their logo, which their
  brand guidelines restrict), the tooltip and detail pane say how it got there, and failures
  moved from orange to red so they can't be mistaken for synced.

- **2026-10-07** — Recorded known issue 10: the detail inspector can only be closed from the menu
  or ⌃⌘I. Proposed a trailing toolbar toggle bound to the same state, and flagged the related
  auto-open rule (empty → non-empty selection only), which leaves the pane shut after a manual
  close until the selection is cleared. For after Phase 7.

- **2026-10-07** — Noted mute-on-upload for Phase 7, to build alongside tags. Strava exposes it as
  `hide_from_home` on `PUT /activities/{id}` — not at upload — so it joins the existing sport
  correction in a single post-upload `PUT`. Matters most for backfills; whether backdated uploads
  reach feeds at all is to be checked live before choosing a default.

- **2026-10-07** — Recorded known issue 9: search by region and country, so "British Columbia"
  or "Switzerland" find workouts labelled "Vancouver BC" or "Geneva". Design is a hidden search
  field beside the short label. The constraint worth knowing: MapKit supplies country names but not
  full region names (its documented `regionName` doesn't exist in the SDK), so regions need a table
  or more measurement. Not started.

- **2026-10-07 (latest)** — **Phase 7 built, paused before the live check.** TCX writer validated
  against Garmin's XSD and every real stored series; two-bucket rate limiter; Strava client and
  uploader behind a fake transport; Keychain, Settings → Strava, Upload with rate-limit pauses and
  resume; and — added at the user's request — matching against the athlete's existing Strava
  activities by time overlap, so workouts the watch already uploaded show "Already on Strava" and
  are skipped by batches. Re-verifying Strava's spec changed two things: flags travel with the
  upload, and the sport needs a follow-up `PUT` because uploads take no type. Also fixed the app
  relaunching windowless (session restoration), which had been failing the UI suite
  intermittently, and stopped UI tests leaking scratch directories (324 had accumulated).
  220 package tests, 27/27 app and UI tests. Not yet run against the live API.

- **2026-09-22 (latest)** — Refreshed *Where things stand*: current tree state (`4a2296a`, pushed),
  a summary of the post-Phase-6 layout polish, and a sharper Phase 7 starting point including a
  suggested order within it and two things worth deciding early.

  Also generalised the "measure, don't derive" note. It had been about the data series; the layout
  work made the same point again in a new area, where three shipped-then-corrected values all came
  from trusting arithmetic over a measurement. Added the two cheap instruments — decode the stored
  blobs for data questions, read the persisted state back after a launch for layout ones — and
  recorded that the centred Strava glyph is the one recent change not independently verified,
  since the window's accessibility tree isn't reachable.

- **2026-09-22** — Widened the default window to 1,300 and centred the Strava glyph in
  its column.

  The previous 1,090 was too narrow with the sidebar showing, and the arithmetic is why: the
  sidebar (223) plus the persisted column widths (824) is 1,047, but an `.inset` table adds
  roughly **185pt of gutters and insets that `currentWidth` does not include**. Measured by
  widening in steps and watching when the columns stop sitting at their minimums — squeezed at
  1,230, slack at 1,250 — after which the content's own ideal settles at 1,300 and a smaller
  requested width is simply ignored.

- **2026-09-21** — Narrowed the Strava column and sized the default window to the table.
  The Strava cell shows the **symbol alone** (44pt, down from 96): the six states have six
  distinct symbol *shapes*, so colour was never carrying the meaning, and `help` plus the
  accessibility label still give the wording. The detail pane keeps symbol-and-text.

  Two things measured on the way, both now in the skill reference. In the current two-column
  layout the table settles at the sum of its column **minimums** and never stretches — the
  opposite of the three-column finding below — so `min:` is the only lever that matters and the
  earlier mins had been cut far enough to truncate "11.66 km". And **`.defaultSize` does not
  take**: with no saved frame the window opened at SwiftUI's 700×780 fallback, narrower than the
  table. An `idealWidth` on the scene's root content is what the window actually sizes to;
  `.windowResizability(.contentMinSize)` made it worse, opening at the content minimum.

  Table is now 824pt (sidebar 223 + table = a 1,090pt window, verified at a clean first launch).

- **2026-09-21** — Narrowed the table's default column widths: the columns now need
  992pt rather than 1,198, a 17% reduction, with the surplus left as trailing space instead of
  inflating every column.

  Two measurements were needed, and the first attempt was wrong. `TableColumnCustomization`
  persists a **`currentWidth` per column**, so the saved arrangement silently overrode the
  declared widths and retuning them changed nothing until the `@AppStorage` key was bumped. Then,
  with the key bumped, narrowing every `ideal:` *still* changed nothing: reading the persisted
  widths back gave a total of exactly 1,094pt before and after, merely reapportioned between
  columns, because the table distributes all available width across its flexible columns.
  **`max:` is what actually stops a column growing**, so every column now has one. Reading the
  defaults key back after a launch turned out to be the only reliable way to see what the table
  really did — no screenshot required.

- **2026-09-21** — Recorded two speculative features: **TrainingPeaks** as a second sync
  destination (7) and **summary statistics** by week, month, year and all time (8). Both are
  unresearched wants rather than plans, written up mainly to capture constraints already
  established elsewhere: that TrainingPeaks' API may be partner-gated and so the feature could be
  impossible rather than hard; that upload state in `WorkoutRecord` is currently Strava-shaped, so
  Phase 7 should put its uploader behind a `WorkoutDestination` protocol to avoid a later
  migration; and that summing `duration` mixes moving time with elapsed time, which makes a naive
  season total two different measurements added together.

  Also noted where things stand: everything is merged, and Phase 7 is the next real build step.

- **2026-09-21** — Two layout defaults. **Place is now the third column**, beside the
  date, since where a workout happened helps identify it. And the **detail pane starts hidden**,
  with a 440pt minimum instead of 300 — at 300 a splits row's six columns wrapped and collided.

  It is an **inspector** rather than a third `NavigationSplitView` column, because the split view
  cannot express this: `columnVisibility` controls only the *leading* columns, and `.doubleColumn`
  on a three-column view hides the **sidebar**. There is no value that hides the detail, and
  trying it hid the wrong thing — caught by a test. An inspector is the macOS control for a
  trailing pane that comes and goes: standard View ▸ Show Inspector toggle with its shortcut (now
  wired up via `InspectorCommands`), a resizable width with a real minimum, and presentation state
  restored by the framework. It reveals itself on the first selection and is then left alone.

- **2026-09-21** — **Phase 6 complete.** The Place column fills in with coarse names.
  `PlaceGrid` snaps a route's first fix to a ~1 km cell in the package; `PlaceResolver` is an actor
  in the app that geocodes cells, caches them, throttles and backs off.

  Measuring the API first changed two things. Reverse-geocoding an *unsnapped* start returns the
  street address (`4629 Haggart St, Vancouver`), so snapping is a precondition of the request and
  not merely of storage, and only `cityWithContext(.automatic)` is read — `name`, `shortAddress`
  and `fullAddress` all leak it. And the plan's `cityName` + `regionCode` recipe is impossible:
  **`regionCode` does not exist** on `MKAddressRepresentations` despite being documented.
  `cityWithContext(.automatic)` returns MapKit's own localized "Vancouver BC" instead.

  Verified against the real library: stored cells sit 132–491 m from the true starts, and five
  workouts collapsed to three cells, so caching already saved two of five requests. Two unplanned
  pieces were needed: a backfill that snaps from stored series, without which everything synced
  before today would have needed a re-sync, and disabling geocoding under `--ui-testing`, because
  a suite that depends on Apple's geocoder fails offline.

- **2026-09-21** — Paused here. Refreshed *Where things stand*, which still described
  Phase 4 as the frontier: current test counts and real-data coverage, a suggested order for
  picking up (Phase 6, then known issue 6, then Phase 7), a revised outstanding list, and the
  habit that has repeatedly earned its keep — measure the stored blobs before building anything
  derived from the series, because three of the last four designs were contradicted by doing so.

- **2026-09-21** — Recorded known issue 6: linking the charts and the map to each other,
  so clicking a point in either highlights the corresponding point in the other. Written up with
  the shared-key decision (timestamp, not index) and the four traps that follow from Phase 5's
  downsampling, pause handling and pace filtering. Not started.

- **2026-09-21** — **Phase 5 complete.** Heart-rate, pace/speed and elevation charts plus
  per-kilometre splits, with the derivation in `MaxActCore` (`WorkoutSplits`, `WorkoutCharts`) and
  the view reduced to drawing. Splits had to be computed because the MCP path carries no lap data.

  Measuring the five real workouts first again changed the design rather than confirming it: split
  distance has to be scaled to the workout's stated total, split *time* has to be moving time (a
  51.7-minute pause otherwise landed inside one kilometre as "57.80 min, 1.0 km/h"), elevation gain
  needs smoothing **and** a 1 m hysteresis threshold to get from a claimed 590 m of climbing down
  to the 45 m that matches HAE's own 43, pace needs its own reversed-axis series rather than a
  relabelled speed axis, and the heart-rate min–max band turned out to be degenerate in all 2,580
  real samples, so it is now emitted only when it actually spans something. Each is documented at
  the code that implements it, including what was tried and rejected.

  Verified against real data: the Swift splits reproduce the Python prototype exactly (km 1 2:30,
  km 2 1:56, km 11 3:14, 663 m tail 2:28) and the per-split gains total 70 m against HAE's 77 m
  ascent for that ride, 45 m against 43 m for the walk.

- **2026-09-21** — Fixed the last two known issues, both of which the list had
  **misdiagnosed**; an hour measuring five real workouts first changed what got built.

  *Pace (issue 1)* was blamed on stopped time. In fact HAE's `avgSpeed` is the mean of
  instantaneous per-point speeds — matching to six significant figures — and `duration` is
  already moving time. Preferring `distance ÷ duration` fixes it with no series dependency; the
  walk went 19:40 → 14:50 /km and the rides tightened from a 3.75–4.87 m/s scatter to 5.37–5.55.
  Moving time survives as a labelled refinement for activities the watch doesn't auto-pause.

  *Bad GPS fixes (issue 4)* were expected to need an implausible-speed detector. Measured, that
  detector fires on 3–5 metre jitter at any useful threshold and on nothing at a safe one. The
  real signature is a fix with **no speed and accuracy above 30 m**; dropping those removes every
  kilometre-scale teleport for 0.0–0.7% of the points. Filtering is on read, the raw series is
  untouched, and the detail pane says how many fixes it left out.

  Also fixed, found while running the suite: **13 seeded UI tests could not launch the app at
  all.** `--ui-testing-seed 40` as two tokens leaves a stray `40` after `NSUserDefaults` pairs
  arguments, AppKit reads a stray argument as a file to open, and that suppresses `WindowGroup`'s
  window — `App.body` runs, its content closure never does. Now passed as `--ui-testing-seed=40`.
  Worth knowing that this is invisible under `open --args`, which launches fine.

- **2026-09-21** — Fixed the detail map inheriting the previous selection's region (known
  issue 2) by driving it from a bound `MapCameraPosition` set after the series loads, rather than
  `initialPosition`, which applies once per view and so never moved on a reused view. The same
  reuse was silently showing the previous workout's route under the new header; the loaded series
  is now tagged with its workout id and a mismatch can't be drawn. Region framing moved into
  `CoordinateBounds.displaySpan` and is shared with the thumbnail renderer.

  Two things surfaced on the way, neither related to the map. **Select All:** the app had a custom
  "Select All Visible" on ⌘⇧A, which Zoom takes globally, so the keystroke never reached the app —
  and rebinding it to ⌘A would have put two ⌘A items in one menu. The standard `.pasteboard`
  command group already provides Edit ▸ Select All and SwiftUI wires it to the table's selection,
  so ⌘A worked all along; the custom command and `AppModel.selectAllVisible` are gone, and a test
  now asserts there is exactly one Select All. **Seed data:** every routed seed workout landed on
  an index where the generator's arithmetic coincides, giving them all identical durations and so
  identical series; route point count is now derived from distance, which also makes the seeded
  thumbnails distinguishable by eye.

- **2026-09-20** — Fixed the grey route lines (known issue 3). The empty `AccentColor`
  colorset was deleted so the app follows the system accent, and route tracks stopped following the
  accent at all: `RouteColor` in `MaxActCore` holds six saturated choices with Sunset (`#FA590F`)
  as the default, chosen in Settings → Appearance. The colour is part of the thumbnail cache key,
  so changing it redraws rather than leaving stale images in the old colour. Renamed `SyncSettings`
  to `AppSettings`, since it now carries appearance too. Confirmed by decoding a rendered
  thumbnail, not just by eye.

- **2026-09-20 (later)** — Added "Delete All Workouts" to Settings, with a confirmation naming the
  count and the cost of re-downloading. Removes rows, series blobs and thumbnails together, since
  all three are keyed on the HealthKit UUID and a leftover blob would be silently adopted by a
  re-synced workout with the same id — there's a test for exactly that. Server address and token
  are deliberately kept. Building it exposed that `RouteThumbnailRenderer`'s cache directory was
  hardcoded, so UI tests had been reading and writing the real thumbnail cache despite their
  isolated database and defaults; it is now injected, and the delete test would otherwise have
  wiped it.

- **2026-09-20 (late)** — Seeded UI tests added: `SampleData` in `MaxActCore`, a
  `--ui-testing-seed` launch argument, and seven tests over the table, scrolling, thumbnails,
  selection and filtering. Two findings while writing them. SwiftUI's `Table` is exposed to
  XCUIAutomation as an **outline**, not a table, so `app.tables` matches nothing — both it and the
  sidebar now carry accessibility identifiers. And verifying the tests against reintroduced bugs
  showed one genuinely catches its bug while the thumbnail test does not discriminate on
  `withExtendedLifetime`, so that earlier fix cannot be credited with resolving the hang; the
  comment now says so.

- **2026-09-20 (evening)** — Used the app against the real phone for the first time and found five
  bugs no test caught: a force-unwrapped URL that crashed on a pasted address, two separate
  `@Environment` crashes in detached AppKit hosting (popover, then table cell), an indoor icon on
  every outdoor ride, a `.task(id:)` that never retried after Download Detail, and an
  `MKMapSnapshotter` released before its completion fired. All fixed; the environment one is now
  structurally impossible since `@Environment(AppModel.self)` no longer exists in the codebase.
  Confirmed working end to end: 13 workouts synced, 3311 route points and 664 HR samples fetched,
  thumbnails rendering as real maps. Loosened two performance assertions that failed spuriously at
  load average 86 — they are regression detectors, not benchmarks. Paused with seeded UI tests as
  the agreed next step.

- **2026-09-20** — Phase 4 complete; the app is usable end to end for browsing. `NavigationSplitView`
  with saved-filter sidebar, a sortable `Table` with persisted column customisation and multi-select,
  search, an aggregate summary for multi-selection, and sync wired to the toolbar and menu bar.
  Route thumbnails are pre-rendered bitmaps cached in memory and on disk — never a live `Map` in a
  row. Getting simplification fast took three measured attempts, 259 ms → 42 ms → 8.1 ms per route.
  `RouteThumbnailRenderer` ended up `@MainActor` rather than an `actor`, because `NSImage` and
  `MKMapSnapshotter.Snapshot` are main-actor-isolated in this SDK and an actor would have meant
  sending non-`Sendable` AppKit types across boundaries. Verified by launching the app and dumping
  the accessibility hierarchy, which caught a detail column collapsing to 196 pt; screenshots were
  not possible (no screen-recording permission), so the UI has not been reviewed visually.

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
