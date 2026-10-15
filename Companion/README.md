# Advanced Swift Concurrency Architecture Companion

This is a synthetic reference implementation for the accompanying article. It does not contain bank code, credentials, customer records, or measured production results.

## Requirements

- macOS with a Swift 6.2 or newer Apple toolchain.
- Swift 6 language mode.
- Nonisolated default isolation; UI types explicitly use `@MainActor`.
- The `NonisolatedNonsendingByDefault` upcoming feature enabled.

Validation used Apple Swift 6.3.3. All twelve scenario groups passed on macOS. The architecture source separately passed type-checking for arm64 iOS 17 simulator with the installed iOS 26.5 SDK. No device latency, energy, or transport benchmark is included.

## Run

From this directory:

```sh
mkdir -p .build
xcrun swiftc -swift-version 6 \
  -enable-upcoming-feature NonisolatedNonsendingByDefault \
  -warnings-as-errors -module-cache-path .build/module-cache \
  Architecture.swift Checks.swift -o .build/architecture-checks
.build/architecture-checks
```

The runner prints one result per scenario group. It uses explicit continuation releases to control completions, bounded observation waits to coordinate with the scheduler, and a 30-second watchdog to make hangs visible. It does not rely on sleep durations to order the requests under test.

## Contracts

`SessionRepository` coalesces same-account reads within its active session. Each caller has a separate continuation and can cancel independently. Producer work remains session-owned even after all callers cancel. Session replacement removes registered work, requests cancellation, and releases old callers. A late producer must match both the session and the flight identity before completing any registered waiter.

`DashboardModel` fences success, failure, and loading state with the active UI request identity. The caller owns the refresh task. During sign-out, the application must clear/invalidate presentation before replacing the repository session and must serialize session transitions.

`boundedMap` limits active child operations per invocation, preserves input order, and stops replenishing after it observes cancellation or failure. It retains the input and results in memory. The final unwrap is justified by the successful group-completion invariant: every input index receives exactly one output, including when `Output` itself is optional.

## Integration Limits

No real transport, authorization, persistent response cache, credential storage, retry service, or UI app is provided. The request key is only an account ID because the synthetic endpoint has no other response dimensions. Adapt it before use with tenant, query, locale, or other variants.

The repository cap counts currently registered flights. Noncooperative producers retired by session replacement can continue executing; physical resource limits must also exist at the transport boundary. Cancelling a waiter does not guarantee immediate wall-clock return because cancellation cleanup must be scheduled on the actor.

The owner must invoke explicit session invalidation on shutdown. A loader that never completes can otherwise retain its task indefinitely. The reference policy does not give strict FIFO fairness or a hard deadline.

Source comments marked `article:begin` and `article:end` keep manuscript listings synchronized with the tested code.
