# proxyp (/srv/apps/proxyp)

## Overview
Simple cross-domain HTTP proxy for CList. Receives GET or POST requests
from the browser, forwards them to the target URL, and returns the response
with CORS headers. Allows CList (a 100% client-side app) to reach external
APIs without browser CORS restrictions.

## Container
- Name: proxyp  Port: 8081 (internal only)
- Domain: proxyp.mooc.ca (Caddy route not yet configured)

## Network
- web (external) — shared with other apps

## Language & Runtime
Perl/PSGI via Starman. Entry point: app.psgi

## History
- v0.1: Originally a CGI script (proxyp.cgi) extracted from the CList GitHub repo
- v0.2: Rewritten as Plack/PSGI app
  - Replaced Apache CGI with Plack/PSGI (matches redirector pattern)
  - Fixed bug: url param was being forwarded back to upstream in GET requests
  - Tightened URL validation: rejects bare IPs and localhost
  - Logs to stderr (visible via docker logs proxyp)
  - Handles CORS OPTIONS preflight

## URL Validation
Accepts only http(s) URLs with a proper hostname — no bare IPv4 addresses,
no localhost. Tighten further (e.g. allowlist specific domains) if abuse occurs.

## Still To Do
- Configure Caddy route for proxyp.mooc.ca
- Test live requests end-to-end
