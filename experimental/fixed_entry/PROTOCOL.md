# Fixed-entry prototype contract

This contract is shared by the isolated Python CLI prototype and CATunnel's
optional native Swift client. Normal connections do not install a remote service;
CATunnel provides a separate explicit user-scoped installation action. The
Python reference uses Python 3.9+ and its standard library; the native Mac
client does not require Python. The Python helper runs on the remote host,
while a client and a small gateway run on the Mac. The existing HTTP/mixed
proxy remains the egress. Fixed-entry mode is disabled by default in CATunnel.

## Processes and endpoints

- `relay.py serve --runtime-dir DIR --port PORT --lease-seconds 20`: owns an IPv4
  loopback TCP entry plus `DIR/control.sock`. Port 0 is allowed for fixtures.
  Publish non-secret `DIR/ready.json` with `port`, `epoch`, and `pid` when ready.
- `relay.py control --runtime-dir DIR`: read one bounded JSON line from stdin,
  send it to the private Unix control socket, and print one JSON response.
- The runtime directory must be owned by the current Unix user, mode 0700, and
  not a symlink. Use an exclusive file lock; never replace a running helper's
  socket or another process's listener. Bind conflicts fail without cleanup of
  foreign processes. Control socket and lock files are private.
- The client starts a private OpenSSH master without a fixed `-R`, then requests
  `-O forward -R 127.0.0.1:0:127.0.0.1:GATEWAY_PORT`. Parse the allocated port.
  All remote control calls use that exact master, with `ProxyCommand=/usr/bin/false`
  to prohibit fallback. Strict host-key verification stays enabled.
- All TCP endpoints owned by this prototype bind only to 127.0.0.1. The gateway
  forwards ordinary proxy traffic to a configured Mac loopback proxy port.

## Control protocol, version 1

Each request/response is one UTF-8 JSON object followed by LF, at most 4096 bytes.
Every response contains `ok` (boolean). Failures contain a stable `error` string;
never include request bodies, lease tickets, or health keys in errors or logs.
No authentication material is placed in command-line arguments or persisted.
The private Unix account is the trust boundary; malicious processes with that
same account are not isolated from one another.

- `{"op":"status"}` returns `epoch` (random daemon-instance string), `generation`
  (last issued generation, initially 0), `port`, `active_generation` (or null),
  `backend_port` (or null), and `lease_seconds`. No tickets/keys are returned.
- `begin`: provide `epoch` and `expected_generation`. Compare-and-swap against
  the current epoch/generation; on success increment generation, invalidate the
  previous pending candidate, and return `epoch`, `generation`, `ticket` (64
  lowercase hex characters). The active route stays unchanged. Pending tickets
  expire after 30 seconds. Only one pending candidate exists.
- `activate`: provide `epoch`, `generation`, `ticket`, `backend_port`, and
  `health_key` (64 lowercase hex characters). Validate pending identity and
  expiry, probe only 127.0.0.1 at the proposed port, and recheck pending identity
  after the asynchronous probe before atomically activating the route. Never
  allow the entry's own port as a backend. Failure preserves the old active
  route. Success returns `epoch`, `generation`, `backend_port`, `lease_seconds`.
- `renew`: provide the active `epoch`, `generation`, `ticket`; verify the active
  backend's health, recheck identity, and extend its monotonic lease. A stale
  renew never changes a newer route. Return `lease_seconds` on success.
- `release`: provide active identity; clear only that generation. A stale release
  cannot clear a newer route. Never terminate SSH/sshd processes.

An older identity no longer active after a newer generation was issued returns
`superseded`; the losing client stops instead of repeatedly taking the entry back.
An expired lease in the current generation returns `stale_lease`, allowing normal
recovery. A failed `begin` compare-and-swap returns `stale_generation` and likewise
stops that competing client. Beginning a candidate alone does not retire a still
active older route or prevent its valid renewal.

Use bounded 3-second backend health/connect timeouts. A failed renew clears only
the route it actually checked. Lease expiry clears the backend but keeps the
fixed listener open; new requests with no active backend fail promptly.
Switch/release/expiry may close data streams belonging to the retired generation;
TCP streams are not migrated. Bound data/control concurrency and buffer sizes,
and apply a shared idle timeout to bidirectional transfers with TCP half-close
support. Cancel owned tasks and close owned sockets on SIGTERM/SIGINT.

## End-to-end health proof

For each connection attempt the client generates a fresh 32-byte health key,
kept only in the client, gateway, and authenticated helper exchange. The helper
sends this line through the candidate reverse forwarding port:

`CATUNNEL-HEALTH-1 <64-hex-random-challenge>\n`

The Mac gateway first confirms its configured loopback proxy accepts a TCP
connection, then replies:

`CATUNNEL-HEALTH-1 <HMAC-SHA256(key, ASCII challenge), lowercase hex>\n`

This proves the candidate reaches the expected gateway and a listening local
proxy, without public-network requests. It does not establish external Internet
reachability. Non-health traffic is relayed unchanged to the local proxy;
normal HTTP and SOCKS prefixes must not be consumed or rewritten. Unknown or
malformed health requests fail closed.

## Client interface for fixture integration

`client.py` exports `FixedEntryClient` with keyword arguments:
`host`, `user`, `ssh_port`, `identity_file`, `known_hosts_file`, `remote_helper`,
`remote_runtime`, `local_port`, and optional `on_event` callback receiving a
non-secret dict. Events include `connected` (entry_port, backend_port,
generation), `disconnected`, `retrying`, and `stopped`.

- `await client.run()` connects, renews every lease_seconds/3, and reconnects
  after transport/lease failure while requested. Authentication/host identity
  and missing helper errors stop with a clear diagnostic. Backoff is bounded.
- `await client.stop()` cancels recovery, best-effort releases only its active
  lease through the owned master, and waits for owned child/gateway cleanup.
- Expose read-only `master_pid` for the test to fault only its owned client and
  `connected`/`backend_port` for bounded fixture waits. A fresh client may take
  over only through a new begin/health-checked activate sequence.
- CLI `connect` requires explicit host/user/SSH port/identity/known-hosts/helper/
  runtime/local-port arguments. Do not read or write CATunnel's normal settings.

## Acceptance

Use temporary strict-key sshd servers and a byte-dropping TCP relay. Retain the
old server-side SSH session and its dynamic listener after client loss, establish
a new SSH session/dynamic listener, and prove the same fixed entry now transfers
an exact fixture response while the old listener still exists. Test stale ticket
operations, wrong health proof, no active lease, expiry, same-runtime duplicate
start, independent entry isolation, user stop/no resurrection, and cleanup. Do
not connect real servers, use user keys, or change the installed application.
