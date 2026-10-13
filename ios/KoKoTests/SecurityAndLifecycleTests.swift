import XCTest
@testable import KoKo

final class SecurityAndLifecycleTests: XCTestCase {
    @MainActor
    func testConcurrentHostKeyPromptIsRejectedWithoutReplacingActivePrompt() async {
        let gate = HostKeyApprovalGate()
        let prompted = expectation(description: "first prompt shown")
        let first = Task { @MainActor in
            await gate.requestApproval {
                prompted.fulfill()
            }
        }

        await fulfillment(of: [prompted], timeout: 1)
        let second = await gate.requestApproval {
            XCTFail("a concurrent prompt must not replace the active prompt")
        }
        XCTAssertFalse(second)

        gate.approve()
        let firstResult = await first.value
        XCTAssertTrue(firstResult)
    }

    @MainActor
    func testDesktopSecretsAreNotPersistedInUserDefaults() throws {
        let desktop = PairedDesktop(
            id: UUID(),
            name: "Test Mac",
            deviceID: "test-\(UUID().uuidString)",
            relayURL: "wss://relay.invalid/re2",
            udpHostPort: "relay.invalid:8787",
            sessionTicket: "session-secret-\(UUID().uuidString)",
            pairingToken: "pair-secret-\(UUID().uuidString)",
            expiresAt: Int64(Date().addingTimeInterval(600).timeIntervalSince1970),
            createdAt: .now
        )
        let store = AppStore()
        let saved = store.upsertDesktop(desktop)
        defer { store.deleteDesktop(saved) }

        let raw = try XCTUnwrap(UserDefaults.standard.data(forKey: "koko.desktops"))
        let text = String(decoding: raw, as: UTF8.self)
        XCTAssertFalse(text.contains(desktop.sessionTicket))
        XCTAssertFalse(text.contains(desktop.pairingToken))
        XCTAssertTrue(store.desktops.contains(where: { $0.id == saved.id && $0.canReconnect }))
    }

    func testGUIBlockerRequiresKnownGraphicsState() {
        let legacy = HostHealthSnapshot(
            healthV: 1, action: "report", reportedAt: nil,
            agentVersion: nil, computerName: nil, phase: nil, relayConnected: true,
            processUptimeSeconds: nil, consoleUser: nil,
            screenRecording: nil, accessibility: nil, power: nil,
            thermal: nil, disk: nil, ups: nil, error: nil,
            screenLocked: nil, displayAsleep: nil, lidClosed: nil, activeDisplays: nil
        )
        XCTAssertNil(HostGUIBlocker.detect(from: legacy))

        var locked = legacy
        locked.consoleUser = "wei"
        locked.screenLocked = true
        XCTAssertEqual(HostGUIBlocker.detect(from: locked), .screenLocked)
    }

    func testTwoFingerScrollWinsOverSpacingDriftAndStaysLocked() {
        let intent = DesktopGestureMath.twoFingerIntent(
            translation: CGPoint(x: 1, y: 18),
            scale: 1.06
        )
        XCTAssertEqual(intent, .scroll)
        XCTAssertEqual(
            DesktopGestureMath.twoFingerIntent(
                translation: CGPoint(x: 2, y: 30),
                scale: 1.30,
                current: intent
            ),
            .scroll
        )
    }

    func testTwoFingerPinchWinsBeforeCentroidDriftAndStaysLocked() {
        let intent = DesktopGestureMath.twoFingerIntent(
            translation: CGPoint(x: 1, y: 2),
            scale: 1.12
        )
        XCTAssertEqual(intent, .pinch)
        XCTAssertEqual(
            DesktopGestureMath.twoFingerIntent(
                translation: CGPoint(x: 12, y: 12),
                scale: 1.20,
                current: intent
            ),
            .pinch
        )
    }

    func testTwoFingerAmbiguousJitterWaitsForIntent() {
        XCTAssertEqual(
            DesktopGestureMath.twoFingerIntent(
                translation: CGPoint(x: 2, y: 3),
                scale: 1.03
            ),
            .undecided
        )
    }

    func testPanEndingFirstDoesNotLeaveViewportPinchActive() {
        var lifecycle = DesktopGestureMath.TwoFingerLifecycle(intent: .pinch)
        XCTAssertTrue(lifecycle.beginPinchIfNeeded())

        // Pan may end first and reset intent, but Pinch must still deliver its
        // own end callback so DesktopViewerView clears `isPinching`.
        lifecycle.resetIntent()
        XCTAssertTrue(lifecycle.pinchIsActive)
        XCTAssertTrue(lifecycle.endPinchIfNeeded())
        XCTAssertFalse(lifecycle.pinchIsActive)
    }
}
