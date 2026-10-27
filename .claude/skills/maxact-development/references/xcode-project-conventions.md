# Xcode project conventions and tooling limits

Established while executing Phase 0. Most of this is about what the `xcode-tools` MCP layer can and
cannot do, which is not documented anywhere else.

## Settings that must not change

| Setting | Value | Why it's load-bearing |
|---|---|---|
| `PRODUCT_BUNDLE_IDENTIFIER` | `com.swiatlowski.MaxAct` | Keychain items for Strava credentials and tokens are keyed to it. Changing it orphans them. |
| `SWIFT_VERSION` / `SWIFT_STRICT_CONCURRENCY` | `6.0` / `complete` | On all three targets. Don't relax to silence a warning. |
| `SUPPORTED_PLATFORMS` / `SDKROOT` | `macosx` | The project began as the multiplatform template; iOS and visionOS were deliberately removed. |
| `MACOSX_DEPLOYMENT_TARGET` | `26.0` | Set per-target. |

## Build settings

- Use `GetTargetBuildSettings` to read and `UpdateTargetBuildSetting` to write. Omitting
  `buildSettingValue` deletes the setting.
- **`UpdateTargetBuildSetting` is target-scoped only** — there is no way to write a *project-level*
  setting. Consequence: `MACOSX_DEPLOYMENT_TARGET` is still the stale template value `26.6.2` at
  project level. All three targets override it to `26.0`, so it's inert, but a newly added target
  would inherit the wrong value. Fix that one in Xcode's UI if it ever matters.
- **`TEST_TARGET_NAME` is rejected** as an unknown build setting. See the UI-test workaround below.
- Sandbox and privacy settings have build-setting forms (`ENABLE_APP_SANDBOX`,
  `ENABLE_OUTGOING_NETWORK_CONNECTIONS`, `ENABLE_USER_SELECTED_FILES`, `INFOPLIST_KEY_*`) and the
  project uses `GENERATE_INFOPLIST_FILE = YES` with no checked-in entitlements file. Prefer the
  build-setting form; use `AddInfoPlist` / `AddEntitlement` for anything without one.
- If the REST push path is ever adopted, the app needs `ENABLE_INCOMING_NETWORK_CONNECTIONS = YES`.
  It's `NO` today because the Mac is currently only ever a client.

## Schemes and test targets

Xcode's defaults are actively wrong here, and the failure is silent.

- **The autocreated scheme runs zero tests.** Adding test targets does not add them to the scheme's
  test action, so `RunAllTests` reports success having run nothing. The fix is a checked-in shared
  scheme at `MaxAct2.xcodeproj/xcshareddata/xcschemes/MaxAct2.xcscheme` with an explicit
  `<TestAction>` / `<Testables>` block referencing each test target's `BlueprintIdentifier` (read
  those from the `PBXNativeTarget` section). Bonus: it lives in the repo instead of `xcuserdata`.
- **Always confirm with `GetTestList` after touching test wiring.** `0 tests` is the tell.
- The unit-test template creates an *unhosted* bundle. `TEST_HOST`
  (`$(BUILT_PRODUCTS_DIR)/MaxAct2.app/Contents/MacOS/MaxAct2`) and `BUNDLE_LOADER` (`$(TEST_HOST)`)
  are ordinary writable settings — set both, or `@testable import MaxAct2` won't resolve.
  `MaxAct2Tests` deliberately asserts against the app bundle identifier and an app type so this
  wiring fails loudly if it regresses.
- The UI-test template sets no target application, and `TEST_TARGET_NAME` can't be written. The
  workaround is in code: launch `XCUIApplication(bundleIdentifier: "com.swiatlowski.MaxAct")`
  rather than `XCUIApplication()`. The scheme's build action builds the app for testing, so the
  bundle exists when the test runs. Don't "fix" this back to the bare initialiser.

## Xcode silently absorbs new files into the app

**Anything you create under the project directory while Xcode has the project open gets added to
the `MaxAct2` target** — `.swift` into Sources, everything else into Copy Bundle Resources. The
three target folders are `PBXFileSystemSynchronizedRootGroup`s, and files at the repo root get
real `PBXFileReference`/`PBXBuildFile` entries written for them.

This bit three times: a `.swift` spike script went into Sources and broke the build; the whole
`Spikes/` directory went into Copy Bundle Resources, including raw captures of real GPS traces and
heart rate that would have shipped inside `MaxAct.app`; and `PLAN.md` was quietly being copied in
too.

**The defence is `EXCLUDED_SOURCE_FILE_NAMES` on the target**, which drops matching files from
every build phase while leaving them in the navigator — so non-app material stays browsable in
Xcode without being built or bundled. Current value:

```
Spikes/* Spikes/**/* PLAN.md HISTORY.md *.py *.pyc *.swift.txt
```

Both path- and basename-style patterns are listed, because which form matches is not worth
relying on. Extend it whenever non-app files are added.

**Always verify at the bundle, not the build.** A clean build only proves nothing broke; it says
nothing about what got copied in:

```
APP=$(find ~/Library/Developer/Xcode/DerivedData/MaxAct2-*/Build/Products/Debug \
        -maxdepth 1 -name MaxAct2.app | head -1)
find "$APP" -type f | sed "s|$APP|MaxAct2.app|"
```

A correct bundle contains only `Info.plist`, `PkgInfo`, `_CodeSignature/`, the binaries under
`MacOS/`, and the test bundle under `PlugIns/`.

**Adding an existing on-disk folder to the project is awkward.** `XcodeMakeDir` and `XcodeWrite`
refuse to adopt a directory that already exists — they create `Spikes 2` beside it. The working
sequence is: move the real folder aside, `XcodeMakeDir` the group, `XcodeWrite` a one-line
placeholder per file to create the references, then copy the real contents back over the
placeholders. The project references survive the overwrite. Remove with `XcodeRM` and
**`deleteFiles: false`** to detach without losing the files, and note it may take two calls — the
first can leave an empty group behind.

Give standalone Swift scripts a non-`.swift` extension; `swift` runs a file whatever it's called.

## An empty `AccentColor` colorset greys out the whole app

The multiplatform template ships `Assets.xcassets/AccentColor.colorset` containing a `universal`
idiom with **no colour components at all**. It is picked up by *naming convention* — there is no
`ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME` in the project to point at, and nothing warns —
so `.tint` and `NSColor.controlAccentColor` resolve to a default grey app-wide. This is what made
every route line render grey, and it would have been easy to misread as a MapKit problem.

Either fill the colorset or delete it. Deleting is usually right on the Mac: the app then follows
the user's system accent, which is what people expect. Asset catalogs are folder-synchronized, so
`git rm -r` on the colorset needs no project edit.

Separately: **don't draw content in the accent colour.** The accent is a user preference and
graphite is a legitimate choice, so anything that needs to stay legible — a route over map tiles,
a chart series — needs its own colour. `RouteColor` in `MaxActCore/Model` is the pattern: sRGB
components (not a SwiftUI `Color`) so it lives in the model layer and is testable, with thin
`NSColor`/`Color` bridges at the one place each is needed.

## Cached artwork must key on everything that affects its appearance

`RouteThumbnailRenderer.Key` is `(workoutID, width, height, isDark, routeColor)` and the filename
is derived from all five. The colour was added when it became configurable: thumbnails are cached
on disk indefinitely, so omitting it would have left every existing image in the old colour until
something unrelated invalidated it. The same applies to any future appearance input. The key also
carries a `drawingVersion`, bumped whenever *how* a route is drawn changes (e.g. when bad GPS fixes
started being filtered), so stale images are redrawn rather than served.

## `MKMapSnapshotter` must be kept alive across the await

If `start` is the snapshotter's last use, Swift may release it as soon as the call returns, and the
completion never fires — every thumbnail spins for ever with no error. Hold it for the duration
(`withExtendedLifetime(snapshotter) { … }`). Separately, the renderer's throttle once parked
cancelled tasks on continuations nothing resumed, wedging every later render; it polls instead.
The seeded UI tests do **not** catch a regression of the first (removing the lifetime extension
leaves them passing), so treat it as a rule rather than something the suite guards.

## SwiftUI reuses a detail view across selection changes

The detail pane is the same view type in the same position in the hierarchy for every selected row,
so SwiftUI keeps one instance and its `@State` survives the selection changing. Two bugs came from
that, and both are worth generalising:

- **`Map(initialPosition:)` applies its position once, when the map is created.** On a reused view
  that means the *first* workout's region sticks forever. Use `Map(position: $camera)` with a
  `@State var camera: MapCameraPosition` — the documented behaviour of the binding form is that the
  map re-aims whenever the value changes. Set it *after* the async load, because the map is built
  long before the route arrives.
- **Async-loaded state must carry the identity it belongs to.** `@State var series: WorkoutSeries?`
  reassigned in `.task(id:)` leaves the previous workout's route drawn under the new workout's
  header until the load finishes. Tagging the loaded value with its id and refusing to draw a
  mismatch rules the whole class out structurally, instead of depending on clearing it in the right
  order.

## `NavigationSplitView` cannot hide its detail column

`columnVisibility` controls only the **leading** columns. On a three-column split view,
`.doubleColumn` means "content + detail" — it hides the *sidebar*. `.detailOnly` hides both
leading columns. **No value hides the detail column**, so "start with the trailing pane closed"
is not expressible, and setting `.doubleColumn` hides the wrong thing.

Use `.inspector(isPresented:)` for a trailing pane that should come and go. It gives a standard
View ▸ Show Inspector item (add `InspectorCommands()` to the app's `commands` to get it and its
shortcut), `inspectorColumnWidth(min:ideal:max:)` for a real minimum, and the framework restores
whether it was open. Reveal it when there's something to show, then leave it alone — toggling it
shut on every deselect makes it flap as someone arrows down a list.

## Reverse geocoding: what the documentation gets wrong, and what leaks

*(macOS 26, measured against the live geocoder)*

- **`MKAddressRepresentations.regionCode` and `.regionName` don't exist**, though both are listed
  in the documentation. `cityWithContext(_:)` is a **method**, not the documented property. What
  compiles: `item.addressRepresentations?.cityName` and
  `item.addressRepresentations?.cityWithContext(.automatic)`.
- **`cityWithContext(.automatic)` is the one to use.** It returns MapKit's own localized
  `"Vancouver BC"` — better than assembling city + region yourself, which only reads correctly in
  the locale you happened to test. `.short` gave the same result; `.full` adds the country.
- **`name`, `address.shortAddress` and `address.fullAddress` return the street address** —
  `4629 Haggart St, Vancouver` for a real workout's start. Never read them for a coarse label.
- **Geocode a snapped coordinate, not a precise one.** The leak above means the precise point
  shouldn't reach Apple either, not just the database. See `PlaceGrid`.
- **A location with no city returns an empty string, not `nil`.** Measured over water. Trim and
  check for empty, or you store a blank label that never retries.
- **It's fast and didn't rate-limit**: ~0.1 s per request, five back to back with no failures.
  Apple documents a limit without publishing it, so throttling is still worth having — but cell
  caching is what actually keeps the count down.

## Don't add a command that macOS already provides

`CommandGroupPlacement.pasteboard` already includes **Select All** in the Edit menu, and SwiftUI
wires it to a `Table`'s selection binding — ⌘A selects every visible row with no code at all. A
custom "Select All Visible" button was therefore redundant, and it had a second problem: to avoid
colliding it was bound to ⌘⇧A, which **Zoom claims as a global shortcut**, so the keystroke never
reached the app and a UI test failed only while Zoom was running. Rebinding it to ⌘A would have put
two ⌘A items in one menu, where AppKit routes the keystroke to the first — the custom item would
show a shortcut that never fires.

Check the standard groups (`.pasteboard`, `.undoRedo`, `.textEditing`, `.sidebar`, `.toolbar`)
before adding a command, and be suspicious of any shortcut chosen to *dodge* a conflict.

## Target dependencies need a hand edit

The Swift explicit-module scanner warns `'MaxAct2Tests' is missing a dependency on 'MaxAct2'`
whenever a test bundle `@testable import`s the app without a declared `PBXTargetDependency`.
`TEST_HOST`/`BUNDLE_LOADER` make it *link*, but the graph is still under-specified, which risks
nondeterministic build ordering.

**No MCP tool can add a target dependency or a package product dependency** — `UpdateTargetBuildSetting`
only reaches build settings. The options are Xcode's UI (target → General → Frameworks and
Libraries → **+**) or a hand edit of `project.pbxproj`, which the server otherwise forbids. One was
authorised on 2026-09-20; the objects added were a `PBXContainerItemProxy`, a `PBXTargetDependency`
on it, and a `dependencies = (…)` array on `MaxAct2Tests`, with `AC…`-prefixed 24-hex ids so
hand-added objects are distinguishable from Xcode's. Verify with `plutil -lint` before building.

**The minimal fix is the right one.** Also adding `MaxActCore` as a package product dependency of
the test target cleared the warnings too, but made SwiftPM link it dynamically and embed
`MaxActCore_….framework` into both the app and the test bundle. The `PBXTargetDependency` on
`MaxAct2` alone clears *both* warnings — the `MaxActCore` edge resolves transitively — and leaves
the bundle lean. Check `Contents/Frameworks/` after any change here.

Warnings are reported by `XcodeListNavigatorIssues` with `severity: "warning"`; `BuildProject`
reports only errors, so a clean build result does not mean a clean build.

## A launch argument's value must be `=`-joined, or the app gets no window

This cost an hour and looked like everything except what it was. Thirteen seeded UI tests failed
with *"no window appeared"* while the twelve non-seeded ones passed, and the app was demonstrably
healthy: launched with `open -n -a MaxAct2.app --args --ui-testing --ui-testing-seed 10` it came
up correctly with ten seeded workouts.

The cause is argument parsing, and seeding was irrelevant — `--ui-testing --dummy-flag 10`
reproduced it exactly. `NSUserDefaults` builds its argument domain by pairing each `-key` with the
*following* token, so with

```
--ui-testing --ui-testing-seed 40
```

it consumes `--ui-testing-seed` as the value of `-ui-testing`, leaving a bare `40`. **AppKit reads
a stray argument as a file to open**, and that request — for a document this app can't open, in an
app with no `DocumentGroup` — suppresses `WindowGroup`'s window entirely. `App.body` evaluates;
its content closure never does; the process sits idle in the event loop at 0% CPU with no window,
forever. Pass `--ui-testing-seed=40` as one token and there is nothing stray.

Two things that make this hard to find, worth remembering:

- **`open --args` doesn't reproduce it.** LaunchServices doesn't turn leftover arguments into open
  requests, so the app looks fine exactly when you test it the convenient way. XCUITest's launch
  does reproduce it, as does exec'ing the binary directly.
- **Raising the timeout doesn't help**, so it doesn't look like slowness. 60 s fails the same as
  15 s.

The general rule: any launch argument that carries a *value* should be a single `--key=value`
token. **Settings as `-key value` defaults** (e.g. a heart-rate profile, which sits over the
throwaway settings domain) must come *before* `--ui-testing`, or `-ui-testing` swallows the key and
the value is stray — same symptom, hit again 2026-10-14. `launchMaxAct(defaults:)` places them. To diagnose this class of thing, probe whether `WindowGroup`'s content closure runs at all
— and write the probe to `NSTemporaryDirectory()`, because the sandbox blocks `/tmp`.

## UI tests must be launched with `--ui-testing`

`MaxAct2UITests` drives the real app, which means it also drives the real *data*. A test that typed
into the sync panel's connection fields overwrote the user's actual Health Auto Export token with
`test-token`, because `SyncSettings` wrote straight to `UserDefaults.standard`.

`SyncSettings` now takes its store by injection, and `MaxActApp` switches to a throwaway defaults
domain plus an in-memory database when launched with `--ui-testing`. **Every** `XCUIApplication`
must set `app.launchArguments = ["--ui-testing"]` before `launch()`. It also makes the tests
deterministic, since they no longer depend on whatever happens to be synced.

The full UI suite is mildly flaky when several tests launch the same app at once — a run once had
every test fail on "no window appeared" and passed unchanged on a retry. Re-run before believing a
sweeping UI-test failure.

**A UI test can't assume an element is inside the window** *(measured, issue 30)*. The window's
height is whatever the last run or the real app left. The inspector scrolls, and XCUI reports
frames for elements below the window's bottom edge. At 780 pt tall, the heart-rate chart's centre
was 4 pt below the window, so `hover()` pointed outside the app and the test failed while the app
worked. `scroll(byDeltaX:deltaY:)` on the inspector's scroll view didn't move it (frames unchanged
both ways). The fix is to drag the window's bottom edge down by the shortfall, then assert the
element is inside `window.frame` before pointing at it.

**Two accessibility facts that cost a test run each** *(measured, issue 23)*:
- A table cell's text is its **value**, with an empty label, so `staticTexts["Sep 9, 2025"]`
  never matches. Use `matching(NSPredicate(format: "value == 'Sep 9, 2025'"))`. A query that
  can't match also makes "it starts off-screen" assertions pass vacuously.
- Anything drawn **inside** a chart marked `accessibilityElement(children: .ignore)`, such as
  a hover annotation, never reaches XCTest. Test the chart's effect instead (click a point,
  check what opened) and screenshot the window to check the drawing by eye.
- `ScrollViewReader` + `proxy.scrollTo(id)` **does** scroll a macOS SwiftUI `Table` to a row
  (mutation-checked). Don't anchor it at `.center`: that centres the row **horizontally** too, and a
  table wider than its view (inspector open) jumped 95 pt sideways. Use `UnitPoint(x: 0, y: 0.5)`. And don't wrap it in
  `withAnimation`: an animated scroll stopped ~15 rows short in about one full run in three,
  presumably interrupted by the table's own scroll to the new selection.
- Table cells are recycled, so a query for a cell's text can match a recycled copy with an
  empty frame. `firstMatch` alternated between x 1516 and x 0 across two reads. Read only a
  match whose frame has width.

**Another app in front of MaxAct sends a UI test's clicks to that app** *(2026-10-26)*. Mid-run,
Xcode was frontmost over MaxAct's window: the heatmap sweep and the jump test clicked into
Xcode, and a "window" screenshot captured Xcode, including the user's conversation. Tests that
click by coordinates call `app.activate()` and assert `.runningForeground` first. Evidence
screenshots are taken only while MaxAct is frontmost. If one ever shows another app, delete it and
its result bundle at once.

**Notification banners land in "window" screenshots, and over the controls** *(2026-10-27)*. A
window screenshot from `XCUIElement.screenshot()` includes whatever is drawn over the window. One
caught calendar invites, a reminder and a chat message, so the screenshot and its result bundle
were deleted at once. The banners also covered the inspector's top right, where the colouring
menu is, and that test failed "not hittable". Ask the user to turn on **Do Not Disturb** before a
full run. Don't keep failure-evidence screenshots in tests that run unattended: print frames
instead.

**Statistics' accessibility frames are off by the sidebar's width once its inspector has opened**
*(2026-10-27)*. With the inspector open, and still after it closes, every element in Statistics
reports a frame 223 pt left of where it's drawn. The map reported x 129.5 while drawn at ~353,
then 328 instead of 551. A click aimed with `element.coordinate(...)` lands off target. Read
frames before anything opens and aim from the window, as the heatmap test does. An open app
issue; see `PLAN.md`.

**A screensaver or locked screen breaks UI tests in two recognisable ways** *(2026-10-25)*: window
screenshots fail with "Failed to look up screen N: Failed to match screen with displayID N", and launches
fail with "Failed to activate application … (current state: Running Background)". Every check before
those steps had passed. Rerun once the screen is awake; don't chase them as test bugs.

**A new app icon may not show in the Dock** *(issue 25)* when the app has run icon-less from the
same DerivedData path before: the Dock caches it. If the built bundle has `CFBundleIconName` and
`Assets.car`, `killall Dock` fixes it, with no project change needed.

**`UpdateTargetBuildSetting` rejects some real settings as unknown**, e.g.
`ASSETCATALOG_COMPILER_APPICON_NAME` (the target lists no `ASSETCATALOG_*` keys). That one was added
to `project.pbxproj` by hand, with the user's explicit override (issue 25). The rule against hand-editing
still stands, so ask before doing it again.

**Background work in the app is far slower while XCUI is polling it** *(measured, issue 23)*.
Building route sketches for 479 workouts took 4 min 20 s inside a real-content UI test, against
~16 s in a package test. Every `waitForExistence` poll snapshots the accessibility tree on the
main thread, and the build reports progress there. A UI test waiting on such work should wait on
a visible progress element going away (generous timeout), not on a fixed short timeout for the
result.

## Detached presentations lose `.environment(...)`

A `.popover` is a separate `NSWindow`, and its content does **not** reliably inherit environment
objects injected further up. `SyncPanel` read the model with `@Environment(AppModel.self)` and the
app trapped with *"No Observable object of type AppModel found"* when the main window re-laid out
while the popover was alive — pressing Start Sync does exactly that, because the progress banner
appears.

**Pass the model explicitly to anything presented detached.** `@Observable` tracking still works,
because it keys off property access rather than off how the reference arrived. The same applies to
`.contextMenu` content, which is hosted detached too.

Note the crash did **not** reproduce under XCUIAutomation, verified by re-running the smoke test
against the pre-fix code. Don't assume a UI test covers this class of bug.

## Querying SwiftUI views from XCUIAutomation

Two things that cost a debugging round each, both found by printing `app.debugDescription`:

- **A SwiftUI `Table` is exposed as an `outline`, not a `table`.** `app.tables` matches nothing.
  So is a `List`, so the sidebar and the workout table are both outlines — give each an
  `.accessibilityIdentifier` and query `app.outlines["WorkoutTable"]` rather than relying on order.
- **`.accessibilityLabel` on a row lands on the element's `label`; a `.badge` becomes its
  `value`.** Predicates must target the right one, and it changed when the badge did.

- **macOS mirrors alert and confirmation-dialog buttons onto the Touch Bar.**
  `app.buttons["Cancel"].firstMatch` can select the mirror, which fails at click time with
  *"cannot be called with Touch Bar elements"*. Scope to `app.sheets` / `app.dialogs` instead of
  querying the application root.

- **`outline.cells` enumerates every column, not every row.** `cells.element(boundBy: 1)` is still
  in the *first* row, so clicking it never changes the selection — a test comparing two rows'
  detail silently compared the same row twice. Click one cell to focus the table, then move with
  `app.typeKey(.downArrow, modifierFlags: [])`.

- **Modifiers on a `GridRow` apply to each cell, not the row.** `.accessibilityElement` plus an
  identifier on a five-cell row gave 30 matches for 6 rows. Put the row's label and identifier on
  its first cell and `.accessibilityHidden(true)` the rest (the zones breakdown does this).

When a query doesn't match, dump the hierarchy instead of guessing — a throwaway test that prints
`app.debugDescription` answers it in one run.

## Seeing the running app: screenshots and driving it by script

`DeviceInteractionStartWorkspaceSession` **rejects "My Mac"** — it only supports iOS/watchOS/tvOS
destinations — so there is no device-interaction path for this app. What works:

- `RunProject`, then `screencapture -o -x -R x,y,w,h file.png`. Check the window is actually on the
  captured display first: `osascript -e 'tell application "System Events" to tell process "MaxAct2"
  to get {position, size} of windows'`. It has come back at **x = −1475**, on a second display,
  which is why plain `screencapture` produced shots with no app window in them and made the app
  look unlaunched.
- To change the selection from a script, **System Events `click at {x, y}` does not produce a click
  SwiftUI honours** — it reports hitting the right element and nothing happens. Set the
  accessibility selection instead:
  `set selected of row 5 of outline 1 of scroll area 1 of group 2 of splitter group 1 of group 1 of window 1 to true`.
- Activate the app immediately before each scripted action; `osascript` and `screencapture` runs in
  between hand focus back to Xcode.

For anything drawn rather than laid out, a screenshot is still only a sanity check — decoding the
actual pixels of a written PNG is what settled the route-colour fix.

## SwiftPM

- `MaxActCore/Package.swift` needs **`swift-tools-version: 6.2`**. `.macOS(.v26)` was introduced in
  PackageDescription 6.2 and fails to compile the manifest under 6.0.
- Set `swiftLanguageMode(.v6)` per target in `swiftSettings`.
- **There is no MCP tool to add a local package to the project.** That is a genuine Xcode UI step:
  File → Add Package Dependencies… → Add Local. Verify afterwards by grepping `project.pbxproj` for
  `XCLocalSwiftPackageReference` *and* a `MaxActCore in Frameworks` build file — a package that's
  referenced but not in the Frameworks phase will type-check and fail to link.
- Adding an `import` alone doesn't prove linkage. Reference a real symbol and build.

## Signing

`DEVELOPMENT_TEAM` is unset; signing is ad-hoc by choice. Rebuilds change the cdhash, so macOS may
prompt to re-authorise Keychain items after a rebuild. If that becomes disruptive, create a
self-signed development certificate — don't work around it by moving secrets out of the Keychain.

## `Table` column widths: `ideal:` is not the rendered width

Two traps, both of which made a width change appear to do nothing.

**A saved customization overrides the declared widths.** `TableColumnCustomization` persists a
`currentWidth` per column alongside order and visibility, so once someone has used the app, the
`.width(...)` values in code are dead. Retuning them requires bumping the `@AppStorage` key
(`workoutTableColumns.v3` at the time of writing), which retires the old widths once.

**`ideal:` only matters when space is tight.** Given room to spare, the table distributes *all*
available width across its flexible columns. Narrowing every `ideal:` and relaunching produced a
persisted total of **1,094pt before and after** — identical to the point, just reapportioned.
`max:` is what stops a column growing; with a cap on every column the surplus becomes trailing
blank space, which is the normal Mac behaviour and what "narrower columns" actually means.

**How to verify.** Read the key back after a launch rather than eyeballing it — the table persists
its own computed widths, so this reports what it really did:

```bash
python3 -c "
import subprocess, plistlib, json
raw = subprocess.run(['defaults','export','com.swiatlowski.MaxAct','-'],capture_output=True).stdout
j = json.loads(bytes(plistlib.loads(raw)['workoutTableColumns.v3']).decode())
st = j['perColumnState']
print([(st[i]['base']['explicit']['_0'], st[i+1].get('currentWidth')) for i in range(0,len(st)-1,2)])
"
```

The Route column is exempt: it is fixed-width with `.disabledCustomizationBehavior(.resize)`, and
its width is part of the thumbnail cache key, so changing it invalidates every cached PNG.

## Window sizing: `defaultSize` loses, and the prefs are in the container

**`.defaultSize` on `WindowGroup` did not take.** With no saved frame the window opened at
SwiftUI's **700×780** fallback regardless of the requested size. What works is an ideal width on
the scene's root content:

```swift
ContentView(model: model)
    .frame(minWidth: 1040, idealWidth: 1090, minHeight: 480, idealHeight: 780)
```

`.defaultSize` is kept alongside it as a statement of intent, but the frame is what the window
sizes to. **Don't reach for `.windowResizability(.contentMinSize)`** to fix this — it makes the
window open at the content's *minimum* (measured: 700×700), which is the opposite of the goal.

**The app is sandboxed, so `defaults` reads the wrong file.** The real preferences are at

```
~/Library/Containers/com.swiatlowski.MaxAct/Data/Library/Preferences/com.swiatlowski.MaxAct.plist
```

`defaults read com.swiatlowski.MaxAct` hits `~/Library/Preferences/…`, which for this app doesn't
even exist. Several "resets" appeared to do nothing for exactly this reason.

**`killall cfprefsd` must come *before* editing the plist, not after.** `cfprefsd` holds the domain
in memory and flushes it on exit, so killing it after an edit writes the stale values straight back
over the change.

**Sizing a window to fit a `Table` cannot be done on paper.** The persisted `currentWidth` values
exclude the table's gutters and insets, which measured ~185pt across ten columns — so sidebar plus
column widths understated the requirement by that much, and a window sized from it left the table
scrolling. Measure instead: widen the window in steps and watch when the columns stop sitting at
their minimums. Note also that the content's own ideal width wins over a smaller requested one.

### Resetting the saved window state

**Run `Spikes/reset-window-state.sh` with the app quit.** Changing a default window size or column
width does nothing visible until the saved state is cleared, so this is needed after every such
change — and it is the first thing to try when a layout change "didn't work".

It keeps `syncHost` and `syncToken` and removes everything else: the `NSWindow Frame …` and
`NSSplitView Subview Frames …` keys, the `workoutTableColumns.vN` layout, and the container's
`Saved Application State` directory — window geometry lives in that directory as well as in the
plist, so deleting only the keys is not enough.

The script refuses to run while the app is open, because the app writes its state back on exit and
would undo the reset.

## The app relaunched with no window at all

**Symptom:** UI tests failed with "no window appeared", a different subset every run, and passed
only when someone clicked the app into focus. The real app did the same: quit with the window
closed, relaunch, nothing to see until a Dock click.

**Cause: session restoration, not focus.** macOS restores the previous session's *windows*; a
session that ended with none open relaunches with none. Activation doesn't create one — only a
"reopen" (Dock click) does. Diagnosed with the window server rather than guessed: `CGWindowList`
showed zero windows for a background launch where Calculator had one, and the unified log
(`/usr/bin/log` — zsh shadows `log` with a builtin) showed `hasPersistentStateToRestore=1`.

**Fix:** `UserDefaults.standard.register(defaults: ["ApplePersistenceIgnoreState": true])` in
`MaxActApp.init`, before AppKit restores anything. Window size and position survive — those are
frame autosave (`NSWindow Frame …`), not session restoration. Things that did **not** work:
`XCUIApplication.activate()` (activates a windowless app) and `.restorationBehavior(.disabled)`
on the `WindowGroup` (AppKit still restored the empty session and SwiftUI opened nothing). The UI
tests also pass `-ApplePersistenceIgnoreState YES` as the **first** launch arguments — after
`--ui-testing` it would be swallowed as that flag's value.

**Where the state lives on macOS 26:** `~/Library/Containers/<bundle id>/Data/tmp/<bundle
id>.savedState`, written through the `com.apple.appkit.restoration_storage` service — *not*
`Library/Saved Application State`, which no longer exists. `Spikes/reset-window-state.sh` clears it.

**Test scratch directories:** XCUITest ends each test by killing the app, so cleanup at quit
never runs. `AppModel.inMemoryFallback` sweeps `MaxActFallback-*` directories older than an hour at
the next launch instead (324 had accumulated). Doing it from the test runner would mean reaching
into another app's container, which triggers a privacy prompt.

## Split-view state leaks between the real app and the UI tests

The UI tests isolate settings, the database and the Keychain — but **AppKit's split-view autosave
(`NSSplitView Subview Frames …`) is written to the app's standard defaults**, which the tests share.
After a real session saved the sidebar as collapsed (`223, 780, YES` — the `YES` is "collapsed"),
every sidebar UI test failed: the sidebar simply wasn't in the window. Reverting code changed
nothing, which was the tell; reading the container plist found it.

The collapse itself came from the inspector: at the default width there's no room for three panes,
so AppKit squeezes the sidebar out and then remembers it as a preference. The fix is
`NavigationSplitView(columnVisibility:)` with `@State … = .all`, so launch state is stated rather
than restored. Two debugging lessons: **dump the hierarchy before theorising** — the sidebar's
absence was visible immediately in `app.windows.firstMatch.debugDescription` — and **when a fix
"works", revert it to check** — a plausible alert-binding fix turned out to be unnecessary.

## Window geometry is shared with the UI tests, and is per-display

`--ui-testing` isolates settings, the database and the Keychain, but **not** AppKit's window frame
autosave (`NSWindow Frame …`) or split-view state, which live in the standard defaults. Two
consequences:

- A test run can change where the **real** app opens. Anything that resizes the window in response
  to UI state will leak into the user's session.
- The saved frame is keyed **per display configuration** (`… 0 0 3008 1661` is the screen), so a
  test can't assume a starting width: a test that grew the window to the screen's full width then
  failed its own "did it grow?" assertion on the next run, because it was already at the maximum.

Assert on **relative** geometry (this pane kept its width) rather than absolute numbers, and treat
"resize the window for the user" as a thing that needs a strong reason.

## A squeezed pane is still in the accessibility tree

`XCUIElement.exists` — and `isHittable` — stayed true for a `NavigationSplitView` sidebar that had
been squeezed down by the inspector, so an existence check passed throughout the original bug.
Assert on `frame.width` when the question is whether something still has room.

## Reverse geocoding on macOS 26: MapKit only, and the subdivision is a string

*(Measured 2026-10-10 across ten places. Supersedes an earlier note that recommended `CLGeocoder`.)*

| | Status | Gives |
|---|---|---|
| `MKAddressRepresentations` | current | `cityName`, `cityWithContext(_:)`, `regionName` (**the country**). `regionCode` is documented but **absent from the SDK**. No subdivision field. |
| `CLGeocoder` | **deprecated in macOS 26** ("Use MapKit") | `locality`, `administrativeArea`, `country`, `isoCountryCode` |
| `MKMapItem.placemark` | **deprecated in macOS 26** ("Use location, address and addressRepresentations") | the same four fields |

So the subdivision comes out of `cityWithContext(.full)` by removing the city prefix and the country
suffix (`PlaceTerms.subdivision(inCityContext:city:country:)`): "Vancouver BC Canada" → "BC",
"North Vancouver BC, Canada" → "BC", "Seattle, WA United States" → "WA", "Edinburgh, Scotland" →
"Scotland", "Geneva, Switzerland" → none. The country code comes from matching `regionName` against
`Locale.localizedString(forRegionCode:)`.

**An empty `cityWithContext` means "no municipality", not "home country".** Of ten places only UBC
(University Endowment Lands) returned `""` — with `cityName` still "Vancouver". It's also `""` over
water. Treat `""` as absent.

**Deprecation warnings only appear when the file recompiles.** `XcodeListNavigatorIssues` reported
zero warnings after the `CLGeocoder` code was added, and the warning surfaced days later when
`PlaceResolver.swift` rebuilt. After adding a new API, grep that build's own log for the file, not
just the issue list.

**Privacy line, unchanged:** only the snapped ~1 km cell is ever sent, and only city-level fields
are read back. `fullAddress`, `shortAddress` and `name` all return a street address.

## `SidebarCommands()` mislabels a bound split view

With `NavigationSplitView(columnVisibility:)` bound to SwiftUI state, `SidebarCommands()` adds a
View-menu item whose ⌃⌘S works but whose **title reads "Show Sidebar" in both states** — measured
over four presses. It validates against AppKit's split-view item, which doesn't track visibility
SwiftUI owns. MaxAct uses its own `SidebarToggleCommand` instead, reading and writing the same
binding through `focusedSceneValue(\.sidebarVisibility, $columns)`, so the title can't drift.
The UI test asserts the title flips, not just that the item exists.

## Content wider than the window is centred and clipped, not shrunk

If the panes' combined minimums exceed the window, SwiftUI lays the content out at its own width
and **centres** it, clipping equally off both edges — measured, 1,318pt of panes in a 1,300pt
window lost 9pt each side, which looked like the sidebar "losing its inset". Two causes to check:

- **An inspector opens at its `ideal` width and does not shrink toward `min` to fit.** MaxAct's
  inspector now has `ideal == min`.
- **The window's `minWidth` must cover the panes actually showing.** It's `1,200` with the
  inspector open, `1,040` without; the scene reads `AppModel.showsDetail` for that.

Measure with `app.windows.firstMatch.splitGroups` frames against the window frame — the split
group being *wider than its window* is the tell.

**Don't move the window's `.frame` modifier between views casually:** the autosaved window frame is
keyed by the root view's *type* (`NSWindow Frame SwiftUI.ModifiedContent<…_FlexFrameLayout…>`), so
changing that type resets every user's saved window size and position once.

**UI tests that resize the window must restore it in a teardown block.** The frame is autosaved
into the shared defaults; a failing assertion that skipped an inline restore left a narrow window
saved for every later test and for the real app on that display. Leave ~1.5 s after the restoring
drag, or termination can beat the autosave.

## Keychain prompts and UI tests

The app is **ad-hoc signed**, so every build has a new code signature and the Keychain treats it as
a new app — any access can raise a password prompt. During UI tests that prompt steals focus and
the test fails with "Failed to activate application (Running Background)", usually the first test
after a build. Under test the app therefore uses `InMemorySecretStore` and makes **no** Keychain
calls.

**Two kinds of test launch, and both must be isolated.** UI tests pass `--ui-testing`. The
**unit-test host** gets no flags at all: XCTest launches the full app and injects the test bundle,
so without care it opens the real database, settings and Keychain — and it runs *first*, so its
prompt is what stopped the first UI test. Detect it from the environment XCTest provides
(`XCTestBundlePath`, `XCTestSessionIdentifier`); `MaxActApp.isIsolatedForTesting` covers both.

**Measure over a full run, not a sample.** Checking two UI tests showed zero lookups and was
reported as fixed; a full run still had one, from the host. Check with:

```
/usr/bin/log show --start "<time>" --style compact \
  --predicate 'process == "MaxAct2" AND eventMessage CONTAINS "SecItem"' | grep -c SecItem
```

It was 5 per UI test before, then 1 per run (the host), then 0. The real app still prompts after rebuilds until it has a stable
signing identity (`security find-identity -v -p codesigning` found none on this Mac).

## `RunCodeSnippet` on an app file launches the real app, on real data

Running a snippet "in the context of" a file in the `MaxAct2` target **launches the whole app**:
`MaxActApp.init` runs with no test flags, so it opens the user's real database, settings and
Keychain, and `AppModel.load` starts its background work. Found 2026-10-10 when a snippet meant to
resolve places on a *copy* of the database left the real one migrated to a new schema and its places
re-resolved by unmerged branch code. It is also a likely source of the Keychain prompts the user
saw, since each such launch is a fresh ad-hoc build reading the real Strava entry.

So for anything that needs live MapKit or real data, prefer a **gated test in `MaxActCore`**
(`swift test`, enabled by an environment variable): it runs in its own process and touches only
what it's given. MapKit's `MKReverseGeocodingRequest` works from there. Reserve `RunCodeSnippet` on
app files for pure code with no side effects, and never assume it is isolated.

## Checking layout against real content, safely

Seeded data has the wrong shape for layout questions — real place names, real numbers and real
lengths are what truncate. `--ui-testing-real-copy` (only honoured with `--ui-testing`) opens a
**copy** of the library at `<container>/Data/tmp/ui-testing-copy/` (`default.store*` plus
`Series/`), isolated like any UI test: in-memory secrets, no geocoding, throwaway settings.
`RealContentUITests` skips itself unless that copy exists, then attaches screenshots **of the
MaxAct window only** — never the screen — with the inspector closed, open, and wider.

```
C=~/Library/Containers/com.swiatlowski.MaxAct/Data; S="$C/Library/Application Support"
mkdir -p "$C/tmp/ui-testing-copy" && cp "$S"/default.store* "$C/tmp/ui-testing-copy/" \
  && cp -R "$S/com.swiatlowski.MaxAct/Series" "$C/tmp/ui-testing-copy/"
# run RealContentUITests, then:
xcrun xcresulttool export attachments --path <xcresult> --output-path /tmp/shots
# afterwards delete both the copy and the exported screenshots
```

First use (issue 12) overturned a conclusion drawn from widths alone: with the inspector open the
table cuts columns off rather than compressing them, and the cut-off one was Strava.

## Signing: Personal Team, and the G3 intermediate

The app is signed with the user's free **Personal Team** (`DEVELOPMENT_TEAM = 89YP9U4PKQ` on all
three targets, automatic signing). `CODE_SIGN_IDENTITY` resolves to "-" (ad hoc) when the team is
empty and "Apple Development" when it isn't, so the team is the only setting needed. The result's
designated requirement is *bundle id + certificate*, with no build hash, so a Keychain "Always
Allow" survives rebuilds — unlike ad-hoc signing, where every build is a stranger.

If `security find-identity -v -p codesigning` shows an Apple Development certificate but **0 valid
identities**, check its issuer: modern certificates come from the **"Apple Worldwide Developer
Relations Certification Authority — G3"** intermediate, and a keychain holding only the old one
(expired 2023-02-07) can't build the chain locally. `security verify-cert` still passes because it
fetches intermediates over the network, which is misleading. Fix: install
`https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer` (SHA-256 `DC:F2:18:78:…:91:60:1F`)
into the login keychain. OpenSSL's "unhandled critical extension" when verifying an Apple
code-signing certificate is OpenSSL not knowing Apple's extension, not a chain fault.

**Testing that signing survives a rebuild needs a real change.** Rebuilding with nothing changed
can produce a byte-identical binary, so "no prompt after rebuild" proves nothing. Change a string
the app actually uses (a comment won't reach the binary), confirm the hash of
`MaxAct2.app/Contents/MacOS/MaxAct2.debug.dylib` changed — in Debug builds the code lives there, not
in the main executable — then launch. Revert afterwards.

## Charts and maps under XCUITest *(measured 2026-10-11)*

- `chartXSelection(value:)` on macOS **follows the pointer**: `element.hover()` sets it, and moving
  off the chart clears it. No click needed.
- A chart made one element with `accessibilityElement(children: .ignore)` is exposed as a plain
  group (`otherElements`), and **its `accessibilityValue` reads back empty** — groups have no
  AXValue. Assert through something else that carries an identifier (MaxAct uses the map marker,
  `RouteHighlight`).
- A SwiftUI `Map` is its own element type, not `otherElements`; find it with
  `descendants(matching: .any)` and its label.
- **Stacked charts align only if both the x domain *and* the plot width match.** Swift Charts
  shrinks the plot by the y-axis label width, so "36.0 km/h" and "175" offset the plots. Give the
  y labels a fixed-width frame (`SeriesChart.axisLabelWidth`) and check alignment on the workout
  with the widest labels (a ride), not whichever row is first.
- When a test passes, check it can fail: the route-click assertion was confirmed by temporarily
  making every click miss, which a hover-then-click test could otherwise pass by accident.
- A merged chart element (`accessibilityElement(children: .ignore)`) keeps its **label** but drops
  an `accessibilityIdentifier`. Query it by label (`label CONTAINS ' per '`).
- `.buttonStyle(.link)` makes a **Link** in the accessibility tree: query `app.links`, not
  `app.buttons`.
- **`LazyVGrid`/`LazyVStack` content below the fold doesn't exist** for XCUITest or VoiceOver until
  scrolled to. For a handful of items use `Grid`.
- To scroll a page that contains charts, scroll over an empty margin
  (`window.coordinate(withNormalizedOffset:).scroll(...)`): a chart under the pointer takes the
  scroll event.

## Charts that don't render as expected *(measured 2026-10-12)*

- `RectangleMark` with a date x (`unit: .weekOfYear`) and categorical y drew each cell as a hairline.
  A calendar heat map is a grid of `RoundedRectangle`s instead.
- `Color.accentColor` inside a `Chart` came out grey. Use an explicit colour (`RouteColor.default`).
- A centred month label for December needs the x domain to run to 1 January, or it's dropped.

## When the Xcode MCP tools stop responding *(2026-10-12)*

Every `xcode-tools` call can fail with `IDEStatefulActionError error 0` (even `XcodeListSchemes`).
**Restarting Xcode fixed it** (2026-10-12, after it had failed for the rest of a session; an
earlier restart in the same day hadn't prevented it recurring, so the trigger is unknown). Check
with `XcodeListSchemes`, which is instant, before falling back.
Fall back to `xcodebuild` with a scratch derived-data folder, which leaves Xcode's own state alone:

```
xcodebuild build-for-testing -project MaxAct2.xcodeproj -scheme MaxAct2 \
  -destination 'platform=macOS' -derivedDataPath /tmp/maxact-dd -quiet
```

**`xcodebuild` records the whole screen when a UI test fails** (`SystemAttachmentLifetime =
deleteOnSuccess`, `PreferredScreenCaptureFormat = screenRecording` in the generated `.xctestrun`).
`-collect-test-diagnostics never` does **not** stop it. **Fixed at the source since 2026-10-12:** the
shared scheme's `<TestAction>` now carries `systemAttachmentLifetime = "keepNever"` and
`preferredScreenCaptureFormat = "screenshots"`, which flow into every generated `.xctestrun` and into
Xcode's own test runs (verified in the `.xctestrun`). The manual patch below is only a fallback for
an older checkout. Before any UI run, set both keys under
`MaxAct2Tests` and `MaxAct2UITests` in `/tmp/maxact-dd/Build/Products/*.xctestrun` to `keepNever` /
`screenshots` (`plutil -replace <target>.SystemAttachmentLifetime -string keepNever …`), then run
`xcodebuild test-without-building -xctestrun <file> -destination 'platform=macOS' -only-testing:…`.
Window screenshots attached by the tests themselves (`XCTAttachment`, `.keepAlways`) still come
through. Check the exported attachments for `.mp4` files and delete any on sight.

## Inspector beside pure-SwiftUI detail content *(measured 2026-10-12; designed around)*

**Cause, from a layout dump** (walk `NSSplitView.arrangedSubviews`, print
`constraintsAffectingLayout(for: .horizontal)`): when the inspector opens, the column's hosting
view gets `NSHostingView.minWidth >= <its current width>` at priority 999.9. Even a plain `Color`
does it; an AppKit-backed `Table` doesn't. Attaching `.inspector` inside the detail column helped
but didn't cure it.

Also tried, and no help: hosting the content in an AppKit `NSScrollView` with an `NSHostingView`
document sized to it — same pinned width, and XCUITest could no longer scroll links into view.
**What MaxAct does:** keeps the window's inspector shut while Statistics is showing, and draws the
same detail view as a panel *inside the statistics' column* (`StatisticsWithInspector`: an `HStack`
with a drag-handle divider), so the split view never changes and nothing is pinned. ⌃⌘I is our own
command toggling `showsDetail` — `InspectorCommands()` toggles the real inspector's binding, which
is held shut there. In UI tests, an `accessibilityIdentifier` on that panel lands on an inner
element; measure the panel by the content's edge and the window's.

**UI tests launch the app by bundle identifier**, so every extra build of the app LaunchServices
knows about (e.g. an `xcodebuild -derivedDataPath /tmp/...` copy) is a candidate to be launched
instead of Xcode's. Check with `lsregister -dump | grep 'path:.*MaxAct2.app'`, and unregister and
delete scratch builds (`lsregister -u <app>`) when done.

With `.inspector` on the `NavigationSplitView` and a 1,200pt window, opening the inspector shrinks
an AppKit-backed `Table` in the detail column (to 564pt) but **not** pure SwiftUI content: the
column stayed ~920pt whatever it held — a full statistics view, a plain colour, content capped at
560pt (which was centred in the column). The panes then overflowed and SwiftUI shifted them,
cutting the sidebar off on the left. Not the cause: the scroll view, the subtitle, opening via ⌃⌘I.
`List` as the host made the app quit on opening the inspector.

Measuring tools that worked: `NSHostingController(rootView:).sizeThatFits(in: 1×∞)` for a view's
narrowest width and `NSHostingView(rootView:).fittingSize` for its ideal, in a hosted unit test (no
window, no mouse); a UI test printing absolute pane frames (`window`, `app.outlines["Sidebar"]`,
the content's identifier) — relative widths alone hid the overflow.

## Phase 8 notes *(2026-10-14)*

- **URLError codes for a sync's network failures, measured:** closed port on a reachable host →
  `cannotConnectToHost` (-1004); an address nobody answers → `timedOut` (-1001, after the request
  timeout); unresolvable name → `cannotFindHost` (-1003). `SyncProblem` maps on these.
- **`MCPTransport`'s request timeout defaults to 600 s** (a sync can wait on a slow phone). Anything
  interactive must pass its own — `ConnectionCheck.timeout` is 15 s.
- **An `accessibilityIdentifier` on the text inside a `Label` isn't exposed** to XCUITest; find
  such text by its value (`staticTexts.containing(NSPredicate(format: "value CONTAINS %@", …))`).
- **Sheets shown on first launch must not appear under UI tests** — every test launches with
  fresh settings. `MaxActApp.showsWelcomeOnFirstLaunch` is false under `--ui-testing` unless
  `--ui-testing-welcome` is passed.
- **`KeyPathComparator` needs `Sendable` key paths.** Computed properties in the app target are
  main-actor-isolated by default, which makes key paths to them non-`Sendable`; mark such
  properties `nonisolated` when they only read the value.
- **A `Picker` outside a `Form` exposes its title as separate text**; the pop-up itself is
  unnamed (VoiceOver says only its value, e.g. "Choose…"). Add `.accessibilityLabel` to the picker.
- **Don't nest a `Form` inside a `ScrollView`** for a few inline fields: it's its own scroll view and
  clipped them out of reach. Plain rows of `LabeledContent` work.
- **A number `TextField` bound to an `Int` that uses 0 for "unset" shows "0"**, not its prompt.
  Bind through an `Int?` that maps 0 to `nil`.
- **`labelsHidden()` keeps the title as the accessibility label**; adding `.accessibilityLabel`
  too makes VoiceOver read it twice ("Year, Year"). Only pickers whose title is *shown* (and so
  rendered as separate text) need the explicit label.
- **"Timed out while enabling automation mode"** fails a UI run before any test starts. It's macOS's
  automation switch (sometimes an unanswered authorization prompt), not the app; retry.
- **Running UI tests quits a running MaxAct** (they launch it by bundle identifier). Check the user
  isn't mid-sync or mid-download first.
- **Content that arrives late must not move what's below it.** A section that grows when its
  data loads shifts everything under it mid-click (two UI tests failed on exactly that). Reserve
  its final size while loading, and put late sections last.
