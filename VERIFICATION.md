# Swift concurrency companion verification

Validation date: October 14, 2026. These checks were executed by Codex on the author's local machine. This is a reproducibility record, not independent peer review or author attestation. No source changes were made during this verification.

## Package contents

- Companion/Architecture.swift: synthetic repository, UI model, decoding boundary, and bounded map.
- Companion/Checks.swift: executable test runner with twelve scenario groups.
- Companion/README.md: requirements, execution instructions, contracts, and integration limitations.

This is standalone Swift source, not an Xcode application or Swift package. The SHA-256 values below identify the exact companion files tested. This public copy omits internal manuscript-preparation notes; source files and recorded results are unchanged.

## Environment and reproduction

Apple Swift 6.3.3 (swiftlang-6.3.3.1.3 clang-2100.1.1.101), swift-driver 1.148.6. Host compiler target: arm64-apple-macosx26.0. Swift 6 language mode, nonisolated default isolation, NonisolatedNonsendingByDefault enabled, warnings treated as errors.

From the repository or extracted archive root:

```sh
mkdir -p .build
xcrun swiftc -swift-version 6 \
  -enable-upcoming-feature NonisolatedNonsendingByDefault \
  -warnings-as-errors -module-cache-path .build/module-cache \
  Companion/Architecture.swift Companion/Checks.swift \
  -o .build/architecture-checks
.build/architecture-checks
```

Compilation completed successfully with exit code 0. The executable completed with exit code 0 and the following output:

```text
PASS: coalescing and independent cancellation
PASS: session epoch rejects late completion
PASS: flight identity protects replacement
PASS: failed flight can retry
PASS: admission and response validation
PASS: producer outlives last waiter
PASS: UI request identity fences stale writes
PASS: bounded work preserves order and limit
PASS: cancellation stops replenishment
PASS: empty invalid optional failure and decode cases
PASS: pre-cancelled caller starts no producer
PASS: stale UI failure cannot overwrite success
Passed 12 scenario groups.
```

Separate architecture-only type-checking completed with exit code 0 for arm64-apple-ios17.0-simulator using the installed iPhoneSimulator26.5.sdk:

```sh
xcrun swiftc -typecheck -swift-version 6 \
  -enable-upcoming-feature NonisolatedNonsendingByDefault \
  -warnings-as-errors \
  -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
  -target arm64-apple-ios17.0-simulator \
  -module-cache-path .build/ios-module-cache \
  Companion/Architecture.swift
```

These are controlled synthetic tests executed on macOS. They are not iOS simulator runtime tests, device benchmarks, production deployment evidence, or exhaustive concurrency verification. The author and reviewers should reproduce the checks and review the implementation independently. Real transport, authorization, session coordination, and resource-lifetime integration remain outside this companion.

## Source identity

```text
a171e712299e44e1f270288192ec767b864a0d1901523eacaf0249c2aff82d71  Companion/Architecture.swift
3db6bdc956fea59576acce2667efc55656a62e76cce75c3e382dca02759c1d11  Companion/Checks.swift
193c989838fd9c09cf35d1f6c689568018a37119476a82e876ab454e1d7d780d  Companion/README.md
```

## AI assistance

The companion implementation and tests were substantially generated with OpenAI Codex. Codex also executed the compiler and test commands on the author's local machine. These checks do not constitute independent human review. Readers should inspect the implementation and reproduce the checks before adapting it.
