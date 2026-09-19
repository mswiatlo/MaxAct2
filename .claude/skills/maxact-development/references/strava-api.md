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

1. `POST /api/v3/uploads`, multipart: `file`, `data_type=tcx`, `name`, `description`,
   `activity_type`, and `external_id` set to our workout id.
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
