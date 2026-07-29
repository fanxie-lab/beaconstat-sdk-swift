# How the SDK works

A one-page tour of the internals: what happens to an event, where things are
stored, and when data actually leaves the device. For the public API and
options, see [README.md](README.md).

## The mental model

A **mailbox with a courier**. Your app drops letters in the mailbox — cheap,
non-blocking, never throws. A courier collects them in batches on a schedule,
and a letter is only crossed off the list once the server says "got it."

Everything that matters follows from that: the mailbox is on disk, so it
survives a crash; and nothing is deleted until it is acknowledged, so an
interrupted send replays instead of disappearing.

## Data flow

```
Beaconstat.track("feature_used")        ← callable from any thread
   │
   ├─ hop onto the serial queue          BeaconstatCore.swift — one isolation domain
   ├─ validate + sanitise                name regex, ≤1024-char values, ≤49 property keys
   ├─ attach _bcs.session.id             starting a session first if one is due
   │
   ├─ EventQueue.enqueue                 → writes queue.json to disk IMMEDIATELY
   │
   └─ if count >= batchSize → flush
          ├─ select a batch              ≤100 events AND ≤80 KB encoded
          ├─ JSON-encode ONCE
          ├─ HMAC-sign those exact bytes never re-encoded before transmission
          ├─ checkout                    mark in flight; deletes NOTHING
          ├─ POST /v1/events
          └─ 202  → acknowledge → the file finally shortens
             fail → release   → selectable again, retried with backoff
```

`BeaconstatCore` is a class with a serial `DispatchQueue`, not an `actor`. That
is deliberate: actor isolation would insert suspension points into the
`select → encode → sign → checkout` sequence whose atomicity is what prevents a
double-send, and it would make every entry point `async` — which a synchronous
`UNNotificationServiceExtension` delegate callback cannot use. The serial queue
*is* the isolation domain.

## Storage — three separate places

| What | Where | Why there |
|---|---|---|
| Queued events | `Application Support/Beaconstat/queue.json` — atomic writes, excluded from iCloud/iTunes backup | Survives crash, jetsam and suspension. Excluded from backup so restoring onto a second device doesn't replay stale telemetry |
| Install id, session state, last-seen app version | Keychain, mirrored to `identity.json` when the Keychain refuses a write | Survives reinstall. Stability matters more than secrecy here — an unstable install id reports one install as many |
| Site token | Keychain **only**, never mirrored | It's a bearer credential, and it costs exactly one handshake to replace |

Backup exclusion is applied to the queue *file*, never its directory:
`identity.json` is a neighbour and is deliberately durable, and the attribute is
inherited by directory contents.

The install id never leaves the device raw — only as
`SHA256(bundleId|installId)`. The same physical device therefore presents a
*different* value to every app that embeds the SDK, which is why the SDK is
structurally incapable of cross-app linkage.

## Sessions

An inactivity window, default 300 s. `startIfNeeded()` refreshes last-activity
if the window is still open, otherwise mints a new UUID and emits
`_bcs.session_started`. A cold start always begins a new session (a fresh
process has no in-memory session). Foreground transitions call it too, so
returning after five minutes away starts a new session; returning after five
seconds does not.

## When it flushes

Six triggers, not just the timer:

1. **The queue reaches `batchSize`** — default 50.
2. **The periodic timer** — 30 s under `DEBUG`, **4 hours in release**. Release
   is battery-friendly by design; it is not the only path data takes.
3. **The app backgrounds** — `flushOnBackground`, default on. The background
   assertion is taken on the *notification thread*, before hopping onto the
   serial queue, because the OS starts its ~5 s countdown at the notification.
4. **The network reconnects** — `NWPathMonitor`.
5. **The retry backoff fires** — see below.
6. **Immediately, for high-value events** — `_bcs.install_detected` and
   `_bcs.apple.app_updated` don't wait for `batchSize` or the timer.

Plus a drain loop: a successful batch immediately triggers the next one while
anything is still pending. And `flush()` forces one by hand.

On macOS, losing focus (⌘-Tab) triggers a flush but emits nothing — only hide
and quit count as backgrounding.

## Retries and backoff

Exponential with **equal jitter** (half the backoff plus a random half), capped
at 30 s, `maxRetries` 3 per round. A server's `Retry-After` wins over the local
schedule — clamped to 15 minutes so a hostile `Retry-After: 999999` can't park
the SDK for eleven days, and still jittered so a whole fleet doesn't return in
one spike.

When a round's budget is spent, the next round is scheduled in ~5 minutes rather
than deferring to the periodic flush — otherwise a release build would sit for
four hours after fourteen seconds of trying, with the queue cap evicting
underneath it the whole time. `maxRetries: 0` opts out of the retry timer
entirely and leaves the work to the periodic flush, the next event, and
reconnect.

## Failure handling — nothing wedges the queue

Every flush outcome must either `acknowledge()` (gone for good) or `release()`
(selectable again). Leaving a batch marked in-flight would block everything
behind it forever, so each status has an explicit decision:

| Response | What happens |
|---|---|
| `202` (or any 2xx) | Acknowledged and deleted. A non-202 2xx is accepted with a warning — a captive portal's `200` must not loop forever |
| `400`, `403`, `404`, `422`, `451`… | **Dropped.** Resending cannot help, and keeping it would block every event behind it |
| `413` | Halve the byte budget and retry the same events in smaller pieces — converging on whatever body limit the deployment actually has. Dropped only once it can shrink no further |
| `401` | Requeued, then the SDK halts until `configure()` runs again |
| `408`, `429`, `5xx`, offline | Requeued and retried on backoff |

An event too large to *ever* fit in a batch (>64 KB) is refused at the door
rather than parked at the head of the queue forever.

## Eviction is value-aware

At the `maxQueuedEvents` cap (default 500), ordinary events go first, oldest
first. `_bcs.install_detected`, `_bcs.session_started` and
`_bcs.apple.app_updated` are sacrificed only when nothing cheaper is left —
each is emitted at most once per install, session or version transition and
cannot be reconstructed afterwards. Since these are enqueued *first* on a
launch, naive oldest-first eviction dropped precisely the events the SDK exists
to report.

In-flight events are never eviction candidates, so residency is bounded by
`maxQueuedEvents + one batch`.

## Idempotency

Every event gets a UUID at creation, carried through the queue file unchanged,
so a retry presents the same ids. The batch's `x-idempotency-key` is a hash of
its member event ids in order — stable across retries of the same batch, and
different the moment the composition changes. A lost `202` therefore doesn't
duplicate data server-side.

The per-event `id` stays off the wire by default (`sendEventIds`): the ingest
API validates with `forbidNonWhitelisted`, so an undeclared `id` rejects the
*entire* batch, not just the offending event.

## The handshake

`configure()` posts the fingerprint to `/v1/handshake` and gets back a site
token plus server time (used to correct a skewed device clock). Two things make
a failure survivable:

- **Launch events are enqueued before the call, not in its success branch.** An
  offline cold launch still records `session_started`, `install_detected` and
  `app_updated`; they wait on disk.
- **The handshake is retried from every flush trigger**, and a token persisted by
  an earlier run is read back at `configure()`. A single failure no longer
  disables the SDK for the whole process.

If no durable install id can be established — Keychain refused *and* the disk
mirror refused — the SDK stays silent for that run rather than registering a
fingerprint that would change on the next launch.

## Signing

`HMAC-SHA256` over `"{timestamp}.{publicKey}.{sha256hex(body)}"`, keyed with the
UTF-8 bytes of the `hmacSecret` string (not hex-decoded), matching the server's
`signature.guard.ts`. The body is encoded once and the same `Data` is both
signed and transmitted — `Transport` never re-encodes.

## Consent

`optOut()` is a real kill switch, not a filter: it purges the queue *and* local
identity, cancels the timers, stops the path monitor, and removes the lifecycle
observers. It records the decision on the caller's thread, before the queue hop,
so `optOut(); assert(isOptedOut)` cannot race. The opt-out flag itself is the
one thing kept — it *is* the consent record — so a later `optIn()` starts a
fresh anonymous install.

To pause collection *without* destroying identity, use `shutdown()` and
`configure()` instead.

## Where to look in the source

| Concern | File |
|---|---|
| Orchestration, flush, retry, lifecycle | `BeaconstatCore.swift` |
| Public entry points and sanitisation | `BeaconstatCore+Collection.swift` |
| Batching, checkout/ack/release, eviction | `EventQueue.swift` |
| On-disk queue file | `Persistence.swift` |
| Keychain + disk mirror | `SecureStore.swift` |
| HTTP, status classification, `Retry-After` | `Transport.swift` |
| Backoff schedule | `RetryPolicy.swift` |
| Wire format, idempotency key | `Event.swift` |
| HMAC | `Signer.swift` |
| Environment snapshot | `EnvironmentCollector.swift` |
