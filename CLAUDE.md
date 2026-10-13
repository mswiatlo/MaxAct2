# MaxAct — working rules

Standing rules for every session. **What's current** (status, open issues, decisions) is in
`PLAN.md` — read it first. Technical facts are in `.claude/skills/maxact-development/`. History,
fixed issues and the dated change log are in `HISTORY.md`.

## Workflow

- **Branch first.** Before any feature, fix or batch of work: `git switch -c <short-name>` from
  `main`. Commit there; merge to `main` and push only once verified or approved. Never commit
  straight to `main`.
- **Verify before merging:** `BuildProject` (zero warnings), `swift test` in `MaxActCore/`,
  `RunAllTests`.
- **Ask before any UI test run** (`RunAllTests`, or `RunSomeTests` on UI tests): they take over the
  mouse and keyboard for up to ~4 minutes. Use `AskUserQuestion` and wait for a go-ahead, so the user
  can finish what they're doing first. A warning alone isn't enough. `swift test` needs no permission.
- **Commit messages** end with the Co-Authored-By line from the session's attribution reminder.
- **If the Xcode tools fail** (`IDEStatefulActionError`, even on `XcodeListSchemes`): ask the user
  to restart Xcode; meanwhile build and test with `xcodebuild` (see the Xcode conventions reference).

## Keeping the docs current — every change

- `PLAN.md`: edit sections in place, bump **Last updated**, update the phase table. Keep it short.
- `HISTORY.md` §8: add a dated change-log entry.
- **When an issue is fixed**, move its diagnosis to `HISTORY.md` §2 and drop it from `PLAN.md`.
- Use today's real date. Earlier entries were misdated and had to be corrected.
- Durable how-to knowledge goes in the skill's references, not here or in `PLAN.md`.

## Verification

- **Measure, don't derive.** Here, measurement has repeatedly contradicted plausible reasoning.
- **Check that a test can fail** (a temporary mutation) before trusting a pass.
- **Check against real content** when the plan says so, or for anything visual. Use a copy of the
  library (`--ui-testing-real-copy`; see the Xcode conventions reference). Pick the case that
  stresses the change, not whichever row is first. Delete the copy and screenshots afterwards.

## Safety

- UI tests and the unit-test host must never touch real data or credentials (`--ui-testing`:
  in-memory stores, `InMemorySecretStore`, throwaway settings).
- Never run `RunCodeSnippet` against app-target files: it launches the real app on real data.
- Never hand-edit `project.pbxproj`; use `UpdateTargetBuildSetting`.
- No screenshots of the user's screen. Window-only screenshots via `XCUIElement` are fine.
- **UI tests must never record the screen.** The scheme's Test action keeps no system attachments
  (`systemAttachmentLifetime = keepNever`, `preferredScreenCaptureFormat = screenshots`); keep it
  that way, and delete any `.mp4` found in test results on sight.
- Confirm before changing the user's system configuration (certificates, keychains, settings).
