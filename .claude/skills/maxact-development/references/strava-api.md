# Strava API (as of 2026)

Relevant to Phase 7. The user already holds a Strava API application (client ID + secret).

## Rate limits — there are two independent buckets

| Bucket | 15-minute | Daily |
|---|---|---|
| Overall | 200 | 2,000 |
| Read (non-upload) | 100 | 1,000 |

The headroom between them is what's available for uploads. **Upload-status polls are `GET`s and
therefore consume the *read* budget**, not the upload allowance — this is the easy mistake, and it
means an aggressive polling loop throttles reads long before uploads.

- The 15-minute window resets on the quarter hour (:00, :15, :30, :45); the daily window at
  midnight UTC. Over-limit returns `429`, and a request that breaks the short-term limit still
  counts against the daily one.
- Usage is reported in `X-RateLimit-Usage` / `X-RateLimit-Limit` and `X-ReadRateLimit-*`. Track both
  buckets from these headers rather than counting locally.
- OAuth token requests are the only calls that don't count.

Design consequence: one actor, upload concurrency of 1, both budgets tracked, back off to the next
quarter-hour boundary on `429`.

## Upload flow

1. `POST /api/v3/uploads`, multipart: `file`, `data_type=tcx`, `name`, `description`, `trainer`,
   `commute`, and `external_id` set to our workout id. **That is the complete documented list
   (spec checked 2026-10-07) — there is no `activity_type`.** Strava infers the type from the TCX
   `Sport` attribute (Running / Biking / Other), so anything else needs `PUT /activities/{id}`
   with `sport_type` once processing finishes. MaxAct writes walks and hikes as "Other" so a
   failed correction leaves a generic workout rather than a false run.
2. Poll `GET /api/v3/uploads/{id}` until `activity_id` appears or `error` is set. **"Queued" is
   in-flight, not success** — the request succeeding does not mean the activity exists.
3. Persist the upload id so a relaunch resumes polling instead of re-uploading.

`external_id` gives server-side dedupe: Strava replies "duplicate of activity N", which should be
recorded as already-uploaded rather than surfaced as a failure.

## OAuth

- `ASWebAuthenticationSession` with a custom callback scheme (`CFBundleURLTypes` gets added when the
  scheme is chosen, in Phase 7 — not before).
- Scope `activity:write,activity:read_all`.
- **Strava's OAuth does not support PKCE.** The client secret is genuinely required for the token
  exchange, which is exactly why the user supplies their own rather than us shipping one.
- Store client ID, secret, access token, refresh token and expiry in the Keychain
  (`kSecClassGenericPassword`, `.whenUnlocked`). Refresh proactively on expiry and reactively on a
  `401`.

## Program constraints

- Creating an API application now requires a paid Strava subscription.
- New apps start in **single-player mode** — only the owner's account can authenticate. That's
  exactly our use case, but it means this app can never be distributed as-is.
- A new base URL `https://api-v3.strava.com` becomes available 2027-01-04; the current one has no
  announced shutdown.


## Tags and flags *(researched 2026-09-20, unverified against the live API)*

Two different things in Strava's UI look like tags; only one is reachable from API v3.

| | UI | API v3 |
|---|---|---|
| Commute | checkbox | `commute` on `PUT /activities/{id}`, integer `1`/`0` |
| Trainer / indoor | checkbox | `trainer`, same shape |
| Activity Tags — With Kid, With Pet, Recovery, For a Cause | tag picker | **no documented field** in `UpdatableActivity` or `DetailedActivity` |

**The multipart upload body ignores `commute`, `trainer` and `sport_type`**, though it does honour
`name` and `description`. Setting a flag therefore costs a second call: upload → poll to
completion → `PUT /activities/{id}`. That is an extra *write* per workout against the overall
200/15 min budget, so only issue the `PUT` when a flag actually needs changing.

Re-check `DetailedActivity` before building on this. Strava has been adding tags recently and the
feature is still rolling out unevenly, so a real tags field may land.


## Finding what's already there *(added 2026-10-07)*

`GET /athlete/activities?after=&before=&page=&per_page=200` returns `SummaryActivity` with
`start_date` (ISO 8601), `elapsed_time`, `distance`, `sport_type` and `external_id`. A read request
per 200 activities — about a dozen for seven years. Most of a user's activities arrived from the
watch or another app, so `external_id` won't match ours; `StravaActivityMatcher` matches by start
within 10 minutes plus ≥50% overlap of the shorter interval, one-to-one. Those thresholds are
**unmeasured** against real data — check them on the first live run.

## Spec source

`https://developers.strava.com/swagger/swagger.json`, with models in `upload.json` and
`activity.json` beside it. The HTML reference page is too long to fetch whole; query the JSON.
The September note above about the upload ignoring `commute`/`trainer` came from community
reports and predates the current spec, which documents both — unconfirmed live either way.

## Muting *(added 2026-10-07)*

"Mute Activity" is `hide_from_home` (boolean, *"Whether this activity is muted"*) on
`UpdatableActivity`, set with `PUT /activities/{id}`. Not an upload parameter. Combine it with the
sport-type correction into a single post-upload `PUT`, and issue none when nothing needs changing.
Unverified live: whether it applies via the API for `activity:write`, whether it can be set the
moment `activity_id` appears, and whether backdated uploads reach followers' feeds at all.
