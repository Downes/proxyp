# proxyp

A simple authenticated cross-domain HTTP proxy for [CList](https://github.com/Downes/CList) and similar browser-based applications.

Browser apps are blocked by CORS from directly calling many external APIs. proxyp runs server-side and forwards those requests on the browser's behalf, returning the response with CORS headers that allow the browser to read it.

## How it works

The browser sends a GET or POST request to proxyp with the target URL as a parameter. proxyp validates the request, fetches the target URL server-side, and returns the response.

```
Browser → proxyp (your server) → external API
                ↑
         CORS headers added here
```

### Authentication

proxyp requires a valid [kvstore](https://github.com/Downes/kvstore) Bearer token on every request. When a request arrives, proxyp calls the kvstore `/auth/verify` endpoint to validate the token. Valid tokens are cached in memory for 5 minutes to keep latency low.

This means **users must be logged in to kvstore** before they can use proxyp. A user who logs out of kvstore loses proxy access within 5 minutes (when the cache expires).

Unauthenticated requests receive a `401 Unauthorized` response.

### Request format

**GET request:**
```
GET https://proxyp.yourdomain.com/?url=https%3A%2F%2Fapi.example.com%2Fdata
Authorization: Bearer <kvstore-token>
```

**POST request:**
```
POST https://proxyp.yourdomain.com/
Authorization: Bearer <kvstore-token>
Content-Type: application/x-www-form-urlencoded

url=https%3A%2F%2Fapi.example.com%2Fdata&param1=value1
```

### URL validation

proxyp only forwards requests to valid public hostnames — bare IP addresses and `localhost` are rejected. Tighten further with a domain allowlist if abuse is a concern.

## Stack

- **Perl 5** / **Plack/PSGI** — request handling
- **Starman** — PSGI server
- **LWP::UserAgent** + **LWP::Protocol::https** — HTTP/HTTPS upstream requests
- **Docker** — containerised deployment

## Setup

### Prerequisites

- Docker and Docker Compose
- A running [kvstore](https://github.com/Downes/kvstore) instance (required for authentication)
- A reverse proxy (Caddy recommended) for HTTPS

### 1. Clone

```bash
git clone https://github.com/Downes/proxyp.git
cd proxyp
```

### 2. Configure

Edit `docker-compose.yml` to point to your kvstore instance if it is not on the same Docker network under the name `kvstore`:

```yaml
environment:
  - KVSTORE_URL=http://kvstore:5000   # adjust if needed
```

### 3. Run the container

Both proxyp and kvstore must be on the same Docker network so proxyp can reach kvstore internally:

```bash
# Create the shared network if it doesn't exist
docker network create web

docker compose up -d
```

The app listens on port 8081 (internal only).

### 4. Configure Caddy

proxyp handles its own CORS headers internally, so a simple reverse proxy entry is sufficient:

```caddyfile
proxyp.yourdomain.com {
  handle /.well-known/acme-challenge/* {
    root * /srv/www/proxyp.yourdomain.com
    file_server
  }

  handle {
    reverse_proxy proxyp:8081
  }
}
```

Create the ACME challenge directory:
```bash
mkdir -p /srv/www/proxyp.yourdomain.com
```

### 5. Configure CList

In the CList Manage Accounts panel, add a **Proxyp** account:

- **Title:** a display name (e.g. `My Proxy`)
- **Proxy URL:** the full URL of your proxyp instance (e.g. `https://proxyp.yourdomain.com`)
- **Permissions:** `p`

CList will use this account to route requests through proxyp, sending the user's kvstore Bearer token automatically.

## Licence

Copyright National Research Council of Canada 2025
Licensed under [Creative Commons Attribution 4.0 International](https://creativecommons.org/licenses/by/4.0/)
