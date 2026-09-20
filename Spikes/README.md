# Spikes — Phase 1 throwaway tooling

Kept for reference and for regenerating fixtures. **Nothing here is part of the app.** Every file
is matched by `EXCLUDED_SOURCE_FILE_NAMES` on the `MaxAct2` target, so it is browsable in Xcode but
never compiled and never copied into the bundle. Verify with the recipe in
`.claude/skills/maxact-development/references/xcode-project-conventions.md` after adding files.

| File | What it does |
|---|---|
| `hae_mcp_probe.py` | Queries the MCP server. Still the quickest way to regenerate a capture, and a known-good reference to check the Swift client against. |
| `hae_analyze.py` | Reports route and heart-rate sample counts and intervals for a payload — the Phase 1 measurement. |
| `make_fixture.py` | Anonymises and truncates a capture into `MaxActCore/Tests/Fixtures/`. |
| `hae_capture.py` | Probe B's REST receiver. Never used: probe B was not run. |
| `hae_file_probe.py` | Finds `.hae` files and identifies their container. |
| `hae_decode.swift.txt` | Working `.hae` decoder (LZFSE). Deliberately not named `.swift`, or Xcode compiles it into the app. |

Captures are written **outside the repository**, to `~/.maxact-spike-captures` (override with
`MAXACT_CAPTURES`). They hold real GPS traces and heart rate, so they must not sit in the project
tree: Xcode swept them into Copy Bundle Resources once already, and gitignored files referenced by
the project dangle on a fresh clone.

```
python3 Spikes/hae_mcp_probe.py --host <phone-ip> --token <bearer> --list-tools
python3 Spikes/hae_mcp_probe.py --host <phone-ip> --token <bearer> --days 7 --aggregation seconds
swift Spikes/hae_decode.swift.txt <file.hae>
```

The Swift-side equivalent, which is the one that matters now that Phase 2 exists:

```
MAXACT_LIVE_HOST=<ip> MAXACT_LIVE_TOKEN=<token> swift test --filter LiveMCPTests
```
