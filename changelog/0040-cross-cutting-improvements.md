# Cross-cutting improvements: launch scripts and command input validation

## Launch script improvements

### Socket/port polling replaces arbitrary sleeps

All four launch scripts previously used `sleep 1` or `sleep 2` to wait for services
to start before launching the gateway/proxy. This was unreliable — on slow machines
the services might not be ready, and on fast machines it was wasted time.

**Distributed scripts** (`warbler-distributed/launch.sh`, `warbler-distributed-pg/launch.sh`):
- Replaced `sleep 1` with socket-existence polling (`[ ! -S "$SOCKET_DIR/$sock" ]`)
- Each of the four worker sockets is checked in a tight loop with `sleep 0.1`

**P2P proxy scripts** (`warbler-p2p-proxy/launch.sh`, `warbler-p2p-proxy-pg/launch.sh`):
- Replaced `sleep 2` with TCP port polling (`nc -z localhost $p`)
- Each of the four service ports (8081-8084) is checked with `sleep 0.2` between retries

### Build errors no longer silenced

The two distributed launch scripts had `swift build 2>/dev/null || true`, which
silenced build errors and continued even if the build failed. Changed to
`swift build || exit 1` so build failures are visible and halt the script.

## Command input validation

### VideoAggregate

- Added `invalidInput(String)` case to `VideoAggregate.Failure`
- `PublishVideoHandler` now validates that `title` and `description` are non-empty
  before processing the command, throwing `.invalidInput("title cannot be empty")`
  or `.invalidInput("description cannot be empty")`

### UserAggregate

- Added `invalidInput(String)` case to `UserAggregate.Failure`
- `RegisterUserHandler` now validates that `email` is non-empty before processing
  the command, throwing `.invalidInput("email cannot be empty")`

### Tests

- Added `rejectPublishWithEmptyTitle` and `rejectPublishWithEmptyDescription` tests
  to `WarblerCatalogTests`
- Added `rejectRegistrationWithEmptyEmail` test to `WarblerIdentityTests`
