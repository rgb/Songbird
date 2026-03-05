# Warbler P2P + Reverse Proxy Demo

Added the `warbler-p2p-proxy` demo — a thin reverse proxy on `:8080` that routes by URL prefix to the 4 Warbler P2P domain services.

## What Changed

### New Demo: demo/warbler-p2p-proxy/

**WarblerProxy executable** — Hummingbird app using AsyncHTTPClient for HTTP forwarding:
- URL-prefix routing: `/users` → `:8081`, `/videos` → `:8082`, `/subscriptions` → `:8083`, `/analytics` → `:8084`
- Request logging with method, path, backend, status code, and duration
- `GET /health` endpoint checking all 4 backend services
- 502 Bad Gateway response when a backend is unreachable
- Implemented as `RouterMiddleware` to forward all HTTP methods

**Alternative configs:**
- `config/nginx.conf` — nginx reverse proxy config
- `config/Caddyfile` — Caddy reverse proxy config

**Launch script:** Starts all 4 P2P services + the proxy (5 processes) with signal handling.

## Architecture

Clients connect to `:8080` and see the same unified API as the monolith. The proxy has zero knowledge of event sourcing — it only routes by URL prefix. The 4 backend services are unchanged from the P2P demo.

## Feature Coverage

| Feature | Where |
|---------|-------|
| Unified API (single port) | WarblerProxy on :8080 |
| URL-prefix routing | /users, /videos, /subscriptions, /analytics |
| Request logging | Duration, backend, status code |
| Health check | GET /health (checks all 4 backends) |
| nginx alternative | config/nginx.conf |
| Caddy alternative | config/Caddyfile |
| Same P2P backend | Zero changes to domain services |
