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

## Xcode silently absorbs new files into the app target

**Anything you create under the project directory while Xcode has the project open gets added to
the target** — `.swift` into Sources, everything else into Copy Bundle Resources. Not a
synchronized group: Xcode writes real `PBXFileReference` and `PBXBuildFile` entries.

This bit twice from one directory of throwaway scripts:

1. A `.swift` script went into Sources and broke the build with "Statements are not allowed at the
   top level".
2. Far worse, the whole directory went into **Copy Bundle Resources** — Python scripts, a `.pyc`,
   and six raw captures containing real GPS traces and heart rate. Those are gitignored precisely
   because they're personal health data, and they would have shipped inside `MaxAct.app`.

So: **after adding any file to the tree, check what the target picked up.**

```
grep -c '<name>' MaxAct2.xcodeproj/project.pbxproj
awk '/Begin PBXResourcesBuildPhase/,/End PBXResourcesBuildPhase/' MaxAct2.xcodeproj/project.pbxproj
```

Remove with `XcodeRM` and **`deleteFiles: false`**, which detaches from the project while leaving
the files on disk; `recursive: true` for a whole directory. Give standalone Swift scripts a
non-`.swift` extension — `swift` runs a file whatever it's called, so
`swift Spikes/hae_decode.swift.txt <args>` still works.

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
