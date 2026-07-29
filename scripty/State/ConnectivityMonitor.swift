//
//  ConnectivityMonitor.swift
//  scripty
//
//  Answers one question — does this device currently have a route to the
//  network? — so the rest of the app can fail fast while offline instead of
//  spending a round trip to learn the same thing, and can push held work the
//  moment the route returns. The web client probes a /health endpoint on a
//  timer for the same answer; a native app gets it straight from the system.
//
//  A satisfied path is not a reachable server — the API can be down while the
//  Wi-Fi is fine. That case still travels the existing slow route (a request
//  fails, the backoff retries); this monitor only covers the common one, no
//  route at all, where waiting on the network is guaranteed lost time.
//

import Foundation
import Network
import Observation

@Observable @MainActor
final class ConnectivityMonitor {
    /// Assumed online until the system says otherwise: a request racing the
    /// first path update should try the network, not fail on a guess.
    private(set) var isOnline = true

    /// Fired on the offline → online transition — the moment held work can be
    /// pushed. Set once by AppModel; views watch `isOnline` themselves.
    @ObservationIgnored var onOnline: (() -> Void)?

    @ObservationIgnored private let monitor = NWPathMonitor()
    @ObservationIgnored private var waiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var hasFirstVerdict = false

    /// `startMonitoring: false` leaves the system monitor off so tests can
    /// drive transitions by hand through `adopt(_:)`.
    init(startMonitoring: Bool = true) {
        guard startMonitoring else {
            hasFirstVerdict = true
            return
        }
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor [weak self] in self?.adopt(online) }
        }
        monitor.start(queue: DispatchQueue(label: "scripty.connectivity"))
    }

    /// Adopt a connectivity verdict. Internal rather than private so tests
    /// can stand in for the system monitor.
    func adopt(_ online: Bool) {
        settleFirstVerdict()
        guard online != isOnline else { return }
        isOnline = online
        if online { onOnline?() }
    }

    /// Wait until the system has reported the path once, so an offline cold
    /// launch goes straight to the cached copy instead of spending its first
    /// request on a route that isn't there. The timeout keeps an odd interface
    /// from stalling launch: past it, "assume online" stands and the request
    /// takes the ordinary failure it would always have taken.
    func waitForFirstVerdict(timeout: Duration = .milliseconds(500)) async {
        guard !hasFirstVerdict else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // Ask again in here. `settleFirstVerdict` drains the list exactly
            // once and then never looks at it again, so a continuation parked
            // after the verdict has already settled is parked forever — and
            // the timeout below can't save it, since it settles through the
            // same one-shot gate. Cheap insurance against that window ever
            // opening, whatever the isolation rules do with the `await` above.
            guard !hasFirstVerdict else { return continuation.resume() }
            waiters.append(continuation)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: timeout)
                self?.settleFirstVerdict()
            }
        }
    }

    private func settleFirstVerdict() {
        guard !hasFirstVerdict else { return }
        hasFirstVerdict = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}
