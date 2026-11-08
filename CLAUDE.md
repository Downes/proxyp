# proxyp (/srv/apps/proxyp)

## Overview
Simple cross-domain HTTP proxy for CList. Receives GET or POST requests
from the browser, forwards them to the target URL, and returns the response
with CORS headers. Allows CList (a 100% client-side app) to reach external
APIs without browser CORS restrictions.

## Container
- Name: proxyp  Port: 8081 (internal only)
- Domain: proxyp.mooc.ca (live via Caddy, confirmed working)

## Network
- web (external) — shared with other apps

## Language & Runtime
Perl/PSGI via Starman. Entry point: app.psgi

## Auth
Every request (GET, POST, multipart) requires **either**:
- a valid kvstore Bearer token: `Authorization: Bearer <token>`, verified
  against `kvstore:5000/auth/verify` and cached in-memory for 5 minutes per
  token, **or**
- the admin-declared access key: `X-Access-Key: <key>`, checked against
  `ACCESS_KEY` in `/app/data/settings.json` — only honoured while `ENABLED`
  is true in that same file (default: false). This is how a logged-out
  CList visitor can use "Load from URL" and similar features — see
  `/public-key` below for how the browser learns the current key, and the
  **Access key is not a secret** note under Admin settings for why that's
  an acceptable tradeoff, not an oversight.

No token and no matching key → 401. This is a change from v0.1 (the old CGI
script), which had no auth at all.

## Admin settings
`GET/PUT /admin/settings` — gated by kvstore Bearer token + `ADMIN_USERNAMES`
(comma-separated, in `docker-compose.yml`), same convention as every other
app in this project. Hand-rolled in Perl (no `clist-server-admin` package
available outside Python) but matches its HTTP contract exactly — `200
{"schema": [...], "values": {...}}`, `401`/`403 {"error": "..."}` — so
CList's generic admin-settings UI (`js/kvstore.js`) needs no special-casing.
Settings persist to `/app/data/settings.json` (bind-mounted via
`./data:/app/data`, survives rebuilds).

Fields:
- `ENABLED` (boolean) — kill switch for the whole unauthenticated-access path.
- `ACCESS_KEY` (text, deliberately unmasked) — **not a secret.** CList is
  100% client-side JS, so any value it sends automatically to authorize an
  unauthenticated request must itself be learnable by anyone who inspects
  network traffic or calls the (deliberately public) `GET /public-key`
  route below. Its value is raising the bar above zero gate, and letting
  the admin instantly revoke/rotate it from the App Settings UI with no
  redeploy — not confidentiality.

## Public route
`GET /public-key` (no auth) — returns `{"enabled": true, "key": "..."}` when
`ENABLED` and a key are set, else `{"enabled": false}`. This is how a
logged-out CList session learns the current key to send as `X-Access-Key`.

## Usage
This is CList's exclusive Etherpad and OASIS proxy (`js/etherpad.js`,
`js/oasis.js` at `/srv/www/clist.mooc.ca/`) — replaces the old, unauthenticated
`proxyp.cgi` under `/srv/apps/grsshopper/site/cgi-bin/` for that traffic.
That old CGI script is left running as-is for other, unrelated consumers
(ple.mooc.ca, an older CList copy under www.downes.ca/CList) — do not remove it.

## Upstream error convention
A reachable-but-failed upstream request returns HTTP 200 with a JSON
`{"error": "..."}` body, not a non-200 status — callers must check for this
JSON shape even on a 200 response. Real HTTP error codes (401) are reserved
for this proxy's own auth gate, not upstream failures.

## History
- v0.1: Originally a CGI script (proxyp.cgi) extracted from the CList GitHub repo
- v0.2: Rewritten as Plack/PSGI app
  - Replaced Apache CGI with Plack/PSGI (matches redirector pattern)
  - Fixed bug: url param was being forwarded back to upstream in GET requests
  - Tightened URL validation: rejects bare IPs and localhost
  - Logs to stderr (visible via docker logs proxyp)
  - Handles CORS OPTIONS preflight
- v0.3: Added kvstore Bearer token auth gate (required on every request)
- v0.4: Added multipart/form-data relay support (POST with a `file` upload
  field, e.g. relaying Etherpad's `/import` endpoint) — detects a `file`
  upload via Plack::Request and posts it upstream with LWP's form-data
  support, separate code path from the flat url-encoded POST relay.
- v0.5: Added `ADMIN_USERNAMES`-gated `/admin/settings` (JSON file settings
  store, `/app/data/settings.json`) and a declarable `ACCESS_KEY` + `ENABLED`
  toggle that lets unauthenticated requests through (GET, POST, and
  multipart alike) when the key matches — added so logged-out CList
  visitors can use "Load from URL" via this proxy. Added public
  `GET /public-key` so CList's JS can learn the current key. Fixed GET
  success responses to pass through the real upstream `Content-Type`
  instead of always forcing `application/json`, needed by "Load from URL"
  to detect feed/HTML format on the proxied response.

## URL Validation
Accepts only http(s) URLs with a proper hostname — no bare IPv4 addresses,
no localhost. Tighten further (e.g. allowlist specific domains) if abuse occurs.
