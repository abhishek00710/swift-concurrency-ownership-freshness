# Swift Concurrency Ownership and Freshness

A synthetic reference implementation exploring three distinct contracts in enterprise iOS architecture: actor isolation, ownership of asynchronous work, and authority to publish a completed result.

Maintained by Abhishek Gang Deb. This repository contains no production banking code, customer data, credentials, or measured production outcomes. It is standalone Swift source, not a complete iOS app or Swift package.

## Reproduce the checks

Use macOS with an Apple Swift 6.2 or newer toolchain. The recorded validation used Apple Swift 6.3.3. Run from the repository root:

```sh
mkdir -p .build
xcrun swiftc -swift-version 6 \
  -enable-upcoming-feature NonisolatedNonsendingByDefault \
  -warnings-as-errors -module-cache-path .build/module-cache \
  Companion/Architecture.swift Companion/Checks.swift \
  -o .build/architecture-checks
.build/architecture-checks
```

The expected final line is `Passed 12 scenario groups.` See [VERIFICATION.md](VERIFICATION.md) for the recorded output, exact compiler version, iOS-target type-check command, and source checksums. To cite a reproducible version, use the full commit SHA rather than a moving branch name.

## Implementation

- [Architecture.swift](Companion/Architecture.swift): session-owned shared reads, independently cancellable waiters, session and flight validation, guarded UI publication, explicit decoding boundary, and bounded parallel mapping.
- [Checks.swift](Companion/Checks.swift): twelve scenario groups with controlled dependency completions, including deliberately late responses and obsolete UI failures.
- [Companion README](Companion/README.md): ownership contracts, execution settings, and integration limitations.

## Scope and limitations

Tests run on macOS with synthetic dependencies. Separate iOS simulator-target type-checking is not an iOS runtime test. No device benchmarks, deployment evidence, exhaustive schedule exploration, or production reliability improvements are claimed.

Production integration requires transport cancellation, authorization, serialized session transitions, and resource-lifetime policies. Shared work intentionally continues after its last waiter cancels. A registered-flight limit does not bound retired producers that ignore cancellation. The application owner must invalidate presentation and repository state appropriately.

## AI assistance

OpenAI Codex substantially generated the companion implementation and tests and ran local validation commands. The recorded checks are reproducible execution evidence, not independent peer review. Review and reproduce the implementation before adapting it.
