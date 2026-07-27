import Foundation
import Testing
@testable import HavenCore

private let base = URL(string: "http://ha.local:8123")!

private func cam(_ state: String, features: Int = 2, streamType: String? = "hls") -> CameraState {
    var attributes: [String: JSONValue] = ["supported_features": .int(features)]
    if let streamType { attributes["frontend_stream_type"] = .string(streamType) }
    return CameraState(EntityState(entityId: "camera.porch", state: state,
                                   attributes: attributes, lastUpdated: Date()))
}

// MARK: - The wire command

/// The literal `camera/stream` is asserted here for the reason recorded on `WSCommand.cameraStream`:
/// Home Assistant answers an unknown command with `unknown_command`, which at the wire level is
/// indistinguishable from "this camera can't stream" — so a typo would demote every camera in every
/// home to the still-image fallback with nothing logged and nothing failing.
@Test func cameraStreamCommandMatchesHomeAssistantsOwnName() throws {
    let data = WSCommand.cameraStream(id: 7, entityId: "camera.porch")
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    #expect(json["type"] as? String == "camera/stream")
    #expect(json["entity_id"] as? String == "camera.porch")
    #expect(json["format"] as? String == "hls")
    #expect(json["id"] as? Int == 7)
}

// MARK: - Whether to ask at all

@Test func streamIsRequestedOnlyWhenTheCameraDeclaredIt() {
    #expect(CameraStream.shouldRequestStream(cam("idle", features: 2)))
    #expect(!CameraStream.shouldRequestStream(cam("idle", features: 0)))
    #expect(!CameraStream.shouldRequestStream(cam("idle", features: 1)))   // ON_OFF only
}

/// A WebRTC camera has no HLS playlist to hand out, so asking costs a round trip and returns an
/// error for a camera that is working perfectly. Skip straight to the still.
@Test func webRTCCamerasAreNotAskedForAnHLSStream() {
    #expect(!CameraStream.shouldRequestStream(cam("idle", streamType: "web_rtc")))
    #expect(!CameraStream.shouldRequestStream(cam("idle", streamType: "WEB_RTC")))
    // An integration that reports no stream type at all is still worth asking — most do not set it.
    #expect(CameraStream.shouldRequestStream(cam("idle", streamType: nil)))
}

@Test func unavailableCamerasAreNeverAskedForAStream() {
    #expect(!CameraStream.shouldRequestStream(cam("unavailable")))
}

// MARK: - Source selection

@Test func aReturnedPlaylistResolvesAgainstTheLiveBaseURL() {
    let source = CameraStream.source(hlsPath: "/api/hls/tok/master_playlist.m3u8",
                                     state: cam("idle"), baseURL: base)
    #expect(source == .hls(URL(string: "http://ha.local:8123/api/hls/tok/master_playlist.m3u8")!))
}

/// The captured-base-URL bug, in the one place it would show up as a black rectangle rather than an
/// error: the same relative playlist must resolve against whichever address the session is using
/// *now*, not the one it started on.
@Test func thePlaylistFollowsALocalToRemoteFailover() {
    let remote = URL(string: "https://abc.ui.nabu.casa")!
    let source = CameraStream.source(hlsPath: "/api/hls/tok/master_playlist.m3u8",
                                     state: cam("idle"), baseURL: remote)
    #expect(source == .hls(URL(string: "https://abc.ui.nabu.casa/api/hls/tok/master_playlist.m3u8")!))
}

@Test func anAbsolutePlaylistURLIsPassedThroughUntouched() {
    let source = CameraStream.source(hlsPath: "https://stream.example.com/x.m3u8",
                                     state: cam("idle"), baseURL: base)
    #expect(source == .hls(URL(string: "https://stream.example.com/x.m3u8")!))
}

/// Every way the stream request can fail — never asked, command errored, socket dropped — arrives
/// here as `nil`, and none of them is a reason to show nothing: the still is a working live view.
@Test func noPlaylistFallsBackToSnapshotRefreshRatherThanToAnError() {
    #expect(CameraStream.source(hlsPath: nil, state: cam("idle"), baseURL: base) == .snapshotRefresh)
    #expect(CameraStream.source(hlsPath: "", state: cam("idle"), baseURL: base) == .snapshotRefresh)
    #expect(CameraStream.source(hlsPath: "   ", state: cam("idle"), baseURL: base) == .snapshotRefresh)
}

/// A playlist reference that isn't fetchable over HTTP must not reach `AVPlayer`, which reports an
/// unplayable asset as a black rectangle and nothing else.
@Test func anUnusablePlaylistReferenceFallsBackRatherThanBeingPlayed() {
    #expect(CameraStream.source(hlsPath: "data:video/mp4;base64,AAAA", state: cam("idle"), baseURL: base)
            == .snapshotRefresh)
    #expect(CameraStream.source(hlsPath: "file:///etc/passwd", state: cam("idle"), baseURL: base)
            == .snapshotRefresh)
}

/// An unavailable camera is the one case that must *not* degrade to a still: there is no picture to
/// fetch, and a blank frame reads as a dark room rather than as a camera that stopped answering.
@Test func anUnavailableCameraIsUnavailableEvenWithAPlaylistInHand() {
    #expect(CameraStream.source(hlsPath: "/api/hls/tok/master_playlist.m3u8",
                                state: cam("unavailable"), baseURL: base) == .unavailable)
    #expect(CameraStream.source(hlsPath: nil, state: cam("unavailable"), baseURL: base) == .unavailable)
}
