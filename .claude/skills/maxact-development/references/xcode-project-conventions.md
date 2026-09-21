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
Spikes/* Spikes/**/* PLAN.md *.py *.pyc *.swift.txt
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
something unrelated invalidated it. The same applies to any future appearance input.

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
token. To diagnose this class of thing, probe whether `WindowGroup`'s content closure runs at all
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
