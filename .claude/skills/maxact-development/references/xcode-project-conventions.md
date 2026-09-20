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
