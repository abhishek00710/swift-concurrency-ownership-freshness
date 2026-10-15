import Foundation

struct SessionIdentity: Hashable, Sendable {
    let principal: String
    let epoch: UUID
}

struct AccountSnapshot: Codable, Equatable, Sendable {
    let accountID: String
    let revision: Int
    let items: [String]
}

enum ArchitectureError: Error, Equatable {
    case sessionChanged
    case overloaded
    case invalidLimit
    case invalidResponse
}

// article:begin decode
@concurrent
func decodeSnapshot(_ data: Data) async throws -> AccountSnapshot {
    try Task.checkCancellation()
    let snapshot = try JSONDecoder().decode(
        AccountSnapshot.self, from: data
    )
    try Task.checkCancellation()
    return snapshot
}
// article:end decode

actor SessionRepository {
    typealias Loader = @Sendable (
        String, SessionIdentity
    ) async throws -> AccountSnapshot
    typealias Waiter = CheckedContinuation<AccountSnapshot, any Error>

    private struct Flight {
        let id: UUID
        let task: Task<Void, Never>
        var waiters: [UUID: Waiter]
    }

    struct Diagnostics: Sendable {
        let flights: Int
        let waiters: Int
        let discardedCompletions: Int
    }

    private var session: SessionIdentity
    private let loader: Loader
    private let maximumFlights: Int
    private var flights: [String: Flight] = [:]
    private var discardedCompletions = 0

    init(session: SessionIdentity, maximumFlights: Int = 4,
         loader: @escaping Loader) {
        precondition(maximumFlights > 0)
        self.session = session
        self.maximumFlights = maximumFlights
        self.loader = loader
    }

    // article:begin wait
    func snapshot(
        for accountID: String, in expectedSession: SessionIdentity
    ) async throws -> AccountSnapshot {
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            let value = try await withCheckedThrowingContinuation {
                (continuation: Waiter) in
                register(continuation, waiterID: waiterID,
                         accountID: accountID,
                         expectedSession: expectedSession)
            }
            try Task.checkCancellation()
            guard session == expectedSession else {
                throw ArchitectureError.sessionChanged
            }
            return value
        } onCancel: {
            Task {
                await self.cancelWaiter(
                    waiterID, accountID: accountID
                )
            }
        }
    }
    // article:end wait

    private func register(
        _ continuation: Waiter, waiterID: UUID,
        accountID: String, expectedSession: SessionIdentity
    ) {
        if Task.isCancelled {
            continuation.resume(throwing: CancellationError())
            return
        }
        guard session == expectedSession else {
            continuation.resume(throwing: ArchitectureError.sessionChanged)
            return
        }
        if flights[accountID] != nil {
            flights[accountID]?.waiters[waiterID] = continuation
            return
        }
        guard flights.count < maximumFlights else {
            continuation.resume(throwing: ArchitectureError.overloaded)
            return
        }

        let flightID = UUID()
        let task = Task { [loader, weak self] in
            let result: Result<AccountSnapshot, any Error>
            do {
                let value = try await loader(accountID, expectedSession)
                guard value.accountID == accountID else {
                    throw ArchitectureError.invalidResponse
                }
                result = .success(value)
            } catch {
                result = .failure(error)
            }
            await self?.finish(result, accountID: accountID,
                               expectedSession: expectedSession,
                               flightID: flightID)
        }
        flights[accountID] = Flight(
            id: flightID, task: task, waiters: [waiterID: continuation]
        )
    }

    // article:begin finish
    private func finish(
        _ result: Result<AccountSnapshot, any Error>,
        accountID: String, expectedSession: SessionIdentity,
        flightID: UUID
    ) {
        guard session == expectedSession,
              let flight = flights[accountID],
              flight.id == flightID else {
            discardedCompletions += 1
            return
        }
        flights.removeValue(forKey: accountID)
        for waiter in flight.waiters.values {
            waiter.resume(with: result)
        }
    }

    private func cancelWaiter(_ id: UUID, accountID: String) {
        guard let waiter = flights[accountID]?.waiters
            .removeValue(forKey: id) else { return }
        waiter.resume(throwing: CancellationError())
    }
    // article:end finish

    // article:begin session
    func replaceSession(with replacement: SessionIdentity) {
        session = replacement
        let retired = flights
        flights.removeAll()
        for flight in retired.values {
            flight.task.cancel()
            for waiter in flight.waiters.values {
                waiter.resume(throwing: ArchitectureError.sessionChanged)
            }
        }
    }
    // article:end session

    func diagnostics() -> Diagnostics {
        Diagnostics(flights: flights.count,
                    waiters: flights.values.reduce(0) { $0 + $1.waiters.count },
                    discardedCompletions: discardedCompletions)
    }
}

@MainActor
final class DashboardModel {
    enum State: Equatable {
        case idle
        case loading(String)
        case loaded(AccountSnapshot)
        case failed(String)
    }

    private let repository: SessionRepository
    private var currentRequest = UUID()
    private(set) var state: State = .idle

    init(repository: SessionRepository) {
        self.repository = repository
    }

    func invalidatePresentation() {
        currentRequest = UUID()
        state = .idle
    }

    // article:begin ui
    func refresh(accountID: String, session: SessionIdentity) async {
        let request = UUID()
        currentRequest = request
        state = .loading(accountID)
        do {
            let value = try await repository.snapshot(
                for: accountID, in: session
            )
            guard request == currentRequest else { return }
            try Task.checkCancellation()
            state = .loaded(value)
        } catch {
            guard request == currentRequest else { return }
            if Task.isCancelled || error is CancellationError
                || error as? ArchitectureError == .sessionChanged {
                state = .idle
            } else {
                state = .failed("Account data is unavailable.")
            }
        }
    }
    // article:end ui
}

// article:begin bounded
@concurrent
func boundedMap<Input: Sendable, Output: Sendable>(
    _ input: [Input], limit: Int,
    operation: @escaping @Sendable (Input) async throws -> Output
) async throws -> [Output] {
    guard limit > 0 else { throw ArchitectureError.invalidLimit }
    try Task.checkCancellation()
    return try await withThrowingTaskGroup(of: (Int, Output).self) { group in
        var next = 0
        var values = [Output?](repeating: nil, count: input.count)
        for _ in 0..<min(limit, input.count) {
            let index = next
            let item = input[index]
            next += 1
            group.addTask {
                try Task.checkCancellation()
                return (index, try await operation(item))
            }
        }
        while let (index, value) = try await group.next() {
            values[index] = value
            try Task.checkCancellation()
            if next < input.count {
                let index = next
                let item = input[index]
                next += 1
                group.addTask {
                    try Task.checkCancellation()
                    return (index, try await operation(item))
                }
            }
        }
        try Task.checkCancellation()
        return values.map { $0! }
    }
}
// article:end bounded
