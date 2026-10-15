import Foundation

enum CheckFailure: Error { case failed(String), injected }

func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw CheckFailure.failed(message) }
}

func eventually(
    _ predicate: @escaping @Sendable () async -> Bool
) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !(await predicate()) {
        guard ContinuousClock.now < deadline else {
            throw CheckFailure.failed("Timed out waiting for observable state")
        }
        await Task.yield()
    }
}

actor ControlledLoader {
    struct Call: Sendable {
        let accountID: String
        let session: SessionIdentity
    }
    private var calls: [Call] = []
    private var pending: [Int: CheckedContinuation<AccountSnapshot, any Error>] = [:]

    func load(_ accountID: String, _ session: SessionIdentity) async throws -> AccountSnapshot {
        let index = calls.count
        calls.append(Call(accountID: accountID, session: session))
        // Intentionally ignores cancellation to exercise late completion.
        return try await withCheckedThrowingContinuation {
            pending[index] = $0
        }
    }
    func count() -> Int { calls.count }
    func succeed(_ index: Int, revision: Int = 1, accountID: String? = nil) {
        let value = AccountSnapshot(accountID: accountID ?? calls[index].accountID,
                                    revision: revision, items: [])
        pending.removeValue(forKey: index)!.resume(returning: value)
    }
    func fail(_ index: Int) {
        pending.removeValue(forKey: index)!.resume(throwing: CheckFailure.injected)
    }
}

actor WorkProbe {
    private var pending: [Int: CheckedContinuation<Int, Never>] = [:]
    private(set) var active = 0
    private(set) var peak = 0
    private(set) var started = 0
    func run(_ value: Int) async -> Int {
        active += 1
        peak = max(peak, active)
        started += 1
        return await withCheckedContinuation { pending[value] = $0 }
    }
    func release(_ value: Int) {
        active -= 1
        pending.removeValue(forKey: value)!.resume(returning: value * 10)
    }
}

func makeSession(_ principal: String = "synthetic-user") -> SessionIdentity {
    SessionIdentity(principal: principal, epoch: UUID())
}

func makeRepository(_ session: SessionIdentity, _ loader: ControlledLoader,
                    limit: Int = 4) -> SessionRepository {
    SessionRepository(session: session, maximumFlights: limit) {
        try await loader.load($0, $1)
    }
}

func expectCancellation(_ task: Task<AccountSnapshot, any Error>) async throws {
    do { _ = try await task.value; throw CheckFailure.failed("Expected cancellation") }
    catch is CancellationError { }
}

func expectSessionChange(_ task: Task<AccountSnapshot, any Error>) async throws {
    do { _ = try await task.value; throw CheckFailure.failed("Expected session change") }
    catch ArchitectureError.sessionChanged { }
}

func coalescingAndIndependentCancellation() async throws {
    let session = makeSession()
    let loader = ControlledLoader()
    let repository = makeRepository(session, loader)
    let first = Task { try await repository.snapshot(for: "A", in: session) }
    let second = Task { try await repository.snapshot(for: "A", in: session) }
    try await eventually { await repository.diagnostics().waiters == 2 }
    try await eventually { await loader.count() == 1 }
    first.cancel()
    try await expectCancellation(first)
    try require(await repository.diagnostics().waiters == 1, "Only one waiter removed")
    await loader.succeed(0, revision: 7)
    try require(try await second.value.revision == 7, "Other waiter receives shared result")
    try require(await loader.count() == 1, "One producer for two callers")
}

// article:begin test
func oldSessionCannotCompleteNewFlight() async throws {
    let old = makeSession()
    let new = makeSession()
    let loader = ControlledLoader()
    let repository = makeRepository(old, loader)
    let first = Task { try await repository.snapshot(for: "A", in: old) }
    try await eventually { await loader.count() == 1 }
    await repository.replaceSession(with: new)
    try await expectSessionChange(first)

    let second = Task { try await repository.snapshot(for: "A", in: new) }
    try await eventually { await loader.count() == 2 }
    await loader.succeed(0, revision: 1)
    try await eventually {
        await repository.diagnostics().discardedCompletions == 1
    }
    try require(await repository.diagnostics().waiters == 1,
                "Old completion must leave the new flight intact")
    await loader.succeed(1, revision: 2)
    try require(try await second.value.revision == 2,
                "The new session receives only its own result")
}
// article:end test

func flightIdentityProtectsReplacement() async throws {
    let session = makeSession()
    let loader = ControlledLoader()
    let repository = makeRepository(session, loader)
    let first = Task { try await repository.snapshot(for: "A", in: session) }
    try await eventually { await loader.count() == 1 }
    // Replacing with the same identity still invalidates pending work.
    await repository.replaceSession(with: session)
    try await expectSessionChange(first)
    let second = Task { try await repository.snapshot(for: "A", in: session) }
    try await eventually { await loader.count() == 2 }
    await loader.succeed(0)
    try await eventually { await repository.diagnostics().discardedCompletions == 1 }
    try require(await repository.diagnostics().waiters == 1, "Flight ID prevents ABA cleanup")
    await loader.succeed(1, revision: 9)
    try require(try await second.value.revision == 9, "Replacement survives")
}

func failedFlightCanRetry() async throws {
    let session = makeSession()
    let loader = ControlledLoader()
    let repository = makeRepository(session, loader)
    let first = Task { try await repository.snapshot(for: "A", in: session) }
    try await eventually { await loader.count() == 1 }
    await loader.fail(0)
    do { _ = try await first.value; throw CheckFailure.failed("Expected failure") }
    catch CheckFailure.injected { }
    let retry = Task { try await repository.snapshot(for: "A", in: session) }
    try await eventually { await loader.count() == 2 }
    await loader.succeed(1)
    _ = try await retry.value
}

func admissionAndValidation() async throws {
    let session = makeSession()
    let loader = ControlledLoader()
    let repository = makeRepository(session, loader, limit: 1)
    let first = Task { try await repository.snapshot(for: "A", in: session) }
    try await eventually { await loader.count() == 1 }
    do { _ = try await repository.snapshot(for: "B", in: session)
        throw CheckFailure.failed("Expected admission rejection") }
    catch ArchitectureError.overloaded { }
    do { _ = try await repository.snapshot(for: "A", in: makeSession())
        throw CheckFailure.failed("Expected stale session rejection") }
    catch ArchitectureError.sessionChanged { }
    await loader.succeed(0, accountID: "WRONG")
    do { _ = try await first.value; throw CheckFailure.failed("Expected response rejection") }
    catch ArchitectureError.invalidResponse { }
}

func producerOutlivesLastWaiter() async throws {
    let session = makeSession()
    let loader = ControlledLoader()
    let repository = makeRepository(session, loader)
    let first = Task { try await repository.snapshot(for: "A", in: session) }
    try await eventually { await loader.count() == 1 }
    first.cancel()
    try await expectCancellation(first)
    try require(await repository.diagnostics().flights == 1, "Session owns producer")
    let second = Task { try await repository.snapshot(for: "A", in: session) }
    try await eventually { await repository.diagnostics().waiters == 1 }
    await loader.succeed(0)
    _ = try await second.value
    try require(await loader.count() == 1, "Later waiter joins existing producer")
}

@MainActor
func staleUICompletionCannotClearNewLoad() async throws {
    let session = makeSession()
    let loader = ControlledLoader()
    let repository = makeRepository(session, loader)
    let model = DashboardModel(repository: repository)
    let first = Task { await model.refresh(accountID: "A", session: session) }
    try await eventually { await loader.count() == 1 }
    let second = Task { await model.refresh(accountID: "B", session: session) }
    try await eventually { await loader.count() == 2 }
    await loader.succeed(0)
    await first.value
    try require(model.state == .loading("B"), "Stale request cannot clear loading")
    await loader.succeed(1, revision: 8)
    await second.value
    try require(model.state == .loaded(AccountSnapshot(accountID: "B", revision: 8, items: [])),
                "Latest intent commits")
    model.invalidatePresentation()
    try require(model.state == .idle, "Explicit presentation invalidation")
}

func boundedWorkPreservesOrderAndLimit() async throws {
    let probe = WorkProbe()
    let task = Task { try await boundedMap([0, 1, 2, 3], limit: 2) { await probe.run($0) } }
    try await eventually { await probe.started == 2 }
    await probe.release(1)
    try await eventually { await probe.started == 3 }
    await probe.release(2)
    try await eventually { await probe.started == 4 }
    await probe.release(3)
    await probe.release(0)
    try require(try await task.value == [0, 10, 20, 30], "Input order preserved")
    try require(await probe.peak == 2, "Concurrency bound enforced")
}

func cancellationStopsReplenishment() async throws {
    let probe = WorkProbe()
    let task = Task { try await boundedMap([0, 1, 2], limit: 1) { await probe.run($0) } }
    try await eventually { await probe.started == 1 }
    task.cancel()
    await probe.release(0)
    do { _ = try await task.value; throw CheckFailure.failed("Expected cancellation") }
    catch is CancellationError { }
    try require(await probe.started == 1, "No replenishment after cancellation")
}

func boundaryCases() async throws {
    let empty: [Int] = try await boundedMap([], limit: 2) { $0 }
    try require(empty.isEmpty, "Empty input")
    do { _ = try await boundedMap([1], limit: 0) { $0 }
        throw CheckFailure.failed("Expected invalid limit") }
    catch ArchitectureError.invalidLimit { }
    do { _ = try await boundedMap([1, 2], limit: 2) { value in
        if value == 1 { throw CheckFailure.injected }; return value
    }; throw CheckFailure.failed("Expected child failure") }
    catch CheckFailure.injected { }
    let optional: [Int?] = try await boundedMap([1, 2], limit: 2) { _ in nil as Int? }
    try require(optional.count == 2 && optional.allSatisfy { $0 == nil }, "Optional results retained")
    let expected = AccountSnapshot(accountID: "A", revision: 4, items: ["synthetic"])
    let decoded = try await decodeSnapshot(JSONEncoder().encode(expected))
    try require(decoded == expected, "Explicit decode boundary")
}

func preCancelledCallerIsRejected() async throws {
    let session = makeSession()
    let loader = ControlledLoader()
    let repository = makeRepository(session, loader)
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await repository.snapshot(for: "A", in: session)
    }
    try await expectCancellation(task)
    try require(await loader.count() == 0, "Pre-cancelled caller starts no producer")
    try require(await repository.diagnostics().waiters == 0, "No leaked waiter")
}

@MainActor
func staleUIFailureCannotOverwriteSuccess() async throws {
    let session = makeSession()
    let loader = ControlledLoader()
    let repository = makeRepository(session, loader)
    let model = DashboardModel(repository: repository)
    let first = Task { await model.refresh(accountID: "A", session: session) }
    try await eventually { await loader.count() == 1 }
    let second = Task { await model.refresh(accountID: "B", session: session) }
    try await eventually { await loader.count() == 2 }
    await loader.succeed(1, revision: 3)
    await second.value
    let expected = model.state
    await loader.fail(0)
    await first.value
    try require(model.state == expected, "Obsolete failure cannot replace success")
}

@main
enum Checks {
    static func main() async throws {
        let watchdog = Task {
            try await Task.sleep(for: .seconds(30))
            fatalError("Test run exceeded 30 seconds")
        }
        defer { watchdog.cancel() }
        let tests: [(String, @Sendable () async throws -> Void)] = [
            ("coalescing and independent cancellation", coalescingAndIndependentCancellation),
            ("session epoch rejects late completion", oldSessionCannotCompleteNewFlight),
            ("flight identity protects replacement", flightIdentityProtectsReplacement),
            ("failed flight can retry", failedFlightCanRetry),
            ("admission and response validation", admissionAndValidation),
            ("producer outlives last waiter", producerOutlivesLastWaiter),
            ("UI request identity fences stale writes", staleUICompletionCannotClearNewLoad),
            ("bounded work preserves order and limit", boundedWorkPreservesOrderAndLimit),
            ("cancellation stops replenishment", cancellationStopsReplenishment),
            ("empty invalid optional failure and decode cases", boundaryCases),
            ("pre-cancelled caller starts no producer", preCancelledCallerIsRejected),
            ("stale UI failure cannot overwrite success", staleUIFailureCannotOverwriteSuccess)
        ]
        for (name, test) in tests {
            try await test()
            print("PASS: \(name)")
        }
        print("Passed \(tests.count) scenario groups.")
    }
}
