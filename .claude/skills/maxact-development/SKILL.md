---
name: maxact-development
description: Hard-won facts for building MaxAct, the macOS Health Auto Export workout browser. Use when working anywhere in this repo — decoding Health Auto Export payloads, choosing or implementing a sync path, touching Xcode build settings / schemes / test targets, writing TCX, or calling the Strava API. Covers things that are not discoverable from the code and that vendor documentation gets wrong or omits.
---

# MaxAct development

`PLAN.md` at the repo root is the source of truth for *what* we're building and which phase we're
in. This skill is the *how* — the facts that cost research or a failed build to establish, and that
will otherwise be rediscovered the hard way.

## Ground rules

- **Read `PLAN.md` first** and keep it current. Edit affected sections in place rather than leaving
  a contradiction, bump *Last updated*, append a dated change-log line, and update the phase table.
- **Never hand-edit `MaxAct2.xcodeproj/project.pbxproj`**, and never read it to answer a question
  that `GetTargetBuildSettings` can answer. Grepping it to *verify* a change landed is fine.
- **Prefer `xcode-tools` MCP tools** over shell commands for anything project-shaped.
- Swift 6 language mode with complete concurrency checking is on for every target. `async`/`await`
  throughout; no Combine.

## The fast inner loop

1. `XcodeRefreshCodeIssuesInFile` after an edit — seconds, catches most type errors.
2. `swift test` in `MaxActCore/` — the real test loop. Model, decoder, TCX and rate-limiter logic
   all live in the package precisely so they can be exercised without launching the app.
3. `BuildProject` per phase; `RunAllTests` for the app bundles.

Put logic in `MaxActCore` by default. Only code that genuinely needs SwiftUI, SwiftData or AppKit
belongs in the app target.

## Four facts that shape the data model

**Never assume units.** Energy arrives in **kJ**, distance in **km**, speed in **km/hr**, heart rate
as `count/min` in some fields and `bpm` in others — and HAE's unit preferences are user-configurable,
so none of this is stable across installs. Every scalar is a `{qty, units}` pair; read `units` and
convert. This is the single easiest way to ship a wrong number.

**Heart rate is bucketed, but the bucket is ours to choose.** HAE emits
`{Min, Avg, Max, date, units}` per time bucket, not beat-by-beat samples. `metadataAggregation:
"seconds"` yields a 5 s median interval — the Apple Watch's native workout rate, so effectively
lossless — against 60 s for the `"minutes"` default. Ask for `"seconds"` whenever the data will be
charted or exported, and accept the ~30× payload cost.

**Activity type is a display name, not an enum.** HAE sends `"Outdoor Cycling"`, not an
`HKWorkoutActivityType` raw value. `ActivityKind` needs an `.other(String)` case; an integer
fallback is wrong.

**Sync cost is per workout, not per byte.** The phone spends ~2.3–2.5 s answering for each workout
regardless of how much of it you ask for. Backfill is therefore minutes-to-tens-of-minutes of
foreground time and must be chunked and resumable; shrinking the payload doesn't help.

## Reference material

Load these when the task touches them — they're detailed and not needed for every change.

- `references/hae-data-contract.md` — the Health Auto Export payload shape (envelope, required vs
  optional fields, `{qty, units}`, date format, route point fields), and the exact invocation
  details for all three sync paths (MCP JSON-RPC, REST push, `.hae` files).
- `references/xcode-project-conventions.md` — build settings that are and aren't writable through
  the tooling, the scheme/test-target wiring that Xcode gets wrong by default, SwiftPM manifest
  requirements, and the settings that must never change.
- `references/strava-api.md` — 2026 rate limits (there are two independent buckets), the upload
  and polling flow, and OAuth constraints.
