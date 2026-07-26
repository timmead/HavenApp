import Foundation
import Testing
@testable import HavenCore

private func cam(_ state: String, _ attributes: [String: JSONValue] = [:]) -> CameraState {
    CameraState(EntityState(entityId: "camera.porch", state: state,
                            attributes: attributes, lastUpdated: Date()))
}

// MARK: - Status

@Test func cameraStatusParsesHomeAssistantsOwnStrings() {
    #expect(cam("recording").status == .recording)
    #expect(cam("streaming").status == .streaming)
    #expect(cam("idle").status == .idle)
    #expect(cam("unavailable").status == .unavailable)
}

/// An unrecognised state must not be coerced into a plausible neighbour — a camera reporting
/// something we've never seen is not the same as an idle one, and rendering it as idle would put a
/// stale frame on screen with no indication anything was wrong.
@Test func unrecognisedCameraStateIsUnknownRatherThanGuessedAt() {
    #expect(cam("wobbling").status == .unknown)
    #expect(!cam("wobbling").isAvailable)
}

/// `idle` is the resting state of a perfectly healthy camera, not a failure. If this ever flips,
/// every non-recording camera in the home renders as an error.
@Test func idleCameraIsAvailable() {
    #expect(cam("idle").isAvailable)
    #expect(cam("recording").isAvailable)
    #expect(cam("streaming").isAvailable)
    #expect(!cam("unavailable").isAvailable)
}

@Test func cameraStatusLabelsCarryStateAsText() {
    #expect(cam("idle").status.label == "Idle")
    #expect(cam("recording").status.label == "Recording")
    #expect(cam("unavailable").status.label == "Unavailable")
}

// MARK: - Attributes

@Test func cameraDecodesTheAttributesTheRendererReads() {
    let s = cam("idle", [
        "entity_picture": .string("/api/camera_proxy/camera.porch?token=abc"),
        "access_token": .string("abc"),
        "supported_features": .int(3),
        "frontend_stream_type": .string("hls"),
        "brand": .string("Ubiquiti"),
        "model": .string("G4 Doorbell"),
        "motion_detection": .bool(true),
    ])
    #expect(s.entityPicture == "/api/camera_proxy/camera.porch?token=abc")
    #expect(s.accessToken == "abc")
    #expect(s.features.contains(.stream))
    #expect(s.features.contains(.onOff))
    #expect(s.frontendStreamType == "hls")
    #expect(s.brand == "Ubiquiti")
    #expect(s.model == "G4 Doorbell")
    #expect(s.motionDetection)
}

/// A missing bitfield must mean "nothing declared", never "everything supported" — the modal would
/// otherwise ask a camera that cannot stream for a stream on every open.
@Test func absentOrNonsenseSupportedFeaturesMeansNothingSupported() {
    #expect(!cam("idle").supportsStream)
    #expect(!cam("idle", ["supported_features": .string("two")]).supportsStream)
    #expect(!cam("idle", ["supported_features": .int(-4)]).supportsStream)
    #expect(cam("idle", ["supported_features": .int(2)]).supportsStream)
}

@Test func blankStringAttributesReadAsAbsent() {
    let s = cam("idle", ["brand": .string("   "), "access_token": .string("")])
    #expect(s.brand == nil)
    #expect(s.accessToken == nil)
}

// MARK: - Snapshot path

/// The tiles fetch the *unsigned* path, not `entity_picture`. Two things depend on that and both
/// are silent when broken: the rotating `?token=` in `entity_picture` is part of
/// `HAImageURL.cacheKey`, so every rotation would leak a fresh cache entry, and the token is a
/// credential we'd be circulating for no gain over the bearer the loader already attaches.
@Test func snapshotPathIsTheStableUnsignedProxyPath() {
    #expect(CameraState.snapshotPath(for: "camera.porch") == "/api/camera_proxy/camera.porch")
    #expect(CameraState.snapshotPath(for: "camera.front_door") == "/api/camera_proxy/camera.front_door")
}

@Test func snapshotPathResolvesAndIsAuthorizedAgainstTheInstance() throws {
    let base = URL(string: "http://ha.local:8123")!
    let resolved = try HAImageURL.resolve(path: CameraState.snapshotPath(for: "camera.porch"), baseURL: base)
    #expect(resolved.url.absoluteString == "http://ha.local:8123/api/camera_proxy/camera.porch")
    #expect(resolved.authorize)
}

// MARK: - Accessibility

@Test func cameraAccessibilityLabelCarriesStateAndAgeAsText() {
    let now = Date()
    let s = cam("recording")
    #expect(AccessibilitySummary.camera("Porch", s, capturedAt: now.addingTimeInterval(-12), now: now)
            == "Porch, recording, updated 12 seconds ago")
    // No frame yet: no age at all, rather than "just now" over a placeholder.
    #expect(AccessibilitySummary.camera("Porch", s, capturedAt: nil, now: now) == "Porch, recording")
    // Unavailable: the age would describe a picture that is no longer being updated.
    #expect(AccessibilitySummary.camera("Porch", cam("unavailable"),
                                        capturedAt: now.addingTimeInterval(-12), now: now)
            == "Porch, unavailable")
}
