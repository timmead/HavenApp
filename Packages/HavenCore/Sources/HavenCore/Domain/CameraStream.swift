import Foundation

/// What the modal should actually play for a camera.
///
/// Three cases, because the two failure directions must not be confused with each other: a camera
/// that can be watched, a camera that can only be *looked at*, and a camera that can do neither.
/// Collapsing the middle case into the last would replace a working (if choppy) live view with an
/// error, and collapsing it into the first would hand `AVPlayer` a URL nothing serves.
public enum CameraStreamSource: Sendable, Equatable {
    /// An HLS playlist from Home Assistant's `camera/stream`. Already absolute and already signed
    /// — HA mints a path containing its own access token — which is exactly why an `AVPlayer`,
    /// which has no way to carry an `Authorization` header, can play it at all.
    case hls(URL)
    /// No stream: fall back to re-fetching the still at a faster cadence than the tiles use. Not a
    /// video, and the modal says so rather than presenting it as one.
    ///
    /// **MJPEG is deliberately not implemented here.** Home Assistant does serve one at
    /// `/api/camera_proxy_stream/<entity_id>`, and the plan named it as the fallback — but
    /// consuming it means parsing a `multipart/x-mixed-replace` byte stream whose exact framing
    /// (boundary string, per-part headers, whether `Content-Length` is present) cannot be checked
    /// without opening a live feed from the user's own home, which this work is explicitly barred
    /// from doing. A parser written against invented bytes and passing tests against those same
    /// invented bytes would be the confident-blank failure this whole feature exists to prevent,
    /// with a green test suite vouching for it. Snapshot refresh reuses the authenticated,
    /// cancellable, already-tested image path instead. `/api/camera_proxy_stream/<entity_id>` is
    /// the one address to add it at, once it can be observed against a real camera.
    case snapshotRefresh
    /// Nothing to show — the camera is unavailable. The modal shows an error state, never a blank
    /// frame that looks like a dark room.
    case unavailable
}

/// Chooses between a live stream and a still, and resolves the stream URL.
///
/// Pure, and in HavenCore rather than beside the `AVPlayer` that consumes it, because every branch
/// below is a decision that fails silently when wrong: an unresolvable URL handed to `AVPlayer`
/// produces a black rectangle and no error anywhere, which is indistinguishable from a camera
/// pointed at a dark room.
public enum CameraStream {
    /// Whether it is worth *asking* Home Assistant for a stream URL at all.
    ///
    /// Both conditions are real. `supported_features` without the `stream` bit means the
    /// integration has said it cannot produce one, and `camera/stream` answers an error. A
    /// `frontend_stream_type` of `"web_rtc"` means the camera streams over WebRTC and has no HLS
    /// playlist to hand out — HA's own frontend takes an entirely different path for those. Asking
    /// anyway costs a round trip and returns an error the user would have to be shown for no
    /// reason, so we skip straight to the still.
    public static func shouldRequestStream(_ state: CameraState) -> Bool {
        guard state.isAvailable, state.supportsStream else { return false }
        return state.frontendStreamType?.lowercased() != "web_rtc"
    }

    /// The source to play.
    ///
    /// - Parameter hlsPath: whatever `camera/stream` returned — typically a root-relative
    ///   `/api/hls/<token>/master_playlist.m3u8`. `nil` covers every way that can fail to produce
    ///   one: never asked (see `shouldRequestStream`), the command errored, the socket dropped
    ///   mid-request. All of them mean the same thing to this function, and none of them is a
    ///   reason to show nothing.
    /// - Parameter baseURL: the address the app is talking to **right now**. Passed rather than
    ///   captured for the same reason `HAImageCredentialsProviding` is per-request: after a
    ///   local↔remote failover a captured base resolves the playlist against a host this session
    ///   is no longer using, and `AVPlayer` reports that as a silent black frame.
    public static func source(hlsPath: String?, state: CameraState, baseURL: URL) -> CameraStreamSource {
        guard state.isAvailable else { return .unavailable }
        guard let hlsPath, let url = resolvedStreamURL(hlsPath, baseURL: baseURL) else {
            return .snapshotRefresh
        }
        return .hls(url)
    }

    /// Resolves the playlist reference against the live base URL, refusing anything that isn't
    /// plain HTTP(S).
    ///
    /// Reuses `HAImageURL.resolve` rather than repeating relative-URL handling: it already refuses
    /// `data:`/`file:`/custom schemes and host-less URLs, and there is no reason for this feature
    /// to have a second, subtly different idea of what a resolvable Home Assistant path is. Its
    /// same-origin `authorize` answer is ignored here on purpose — nothing attaches a bearer token
    /// to a playlist, because HA has already signed it.
    private static func resolvedStreamURL(_ path: String, baseURL: URL) -> URL? {
        try? HAImageURL.resolve(path: path, baseURL: baseURL).url
    }

    /// How often the `snapshotRefresh` fallback re-fetches the still, in seconds.
    ///
    /// Faster than the tiles' ten seconds because the modal is open and being watched, and slower
    /// than a real frame rate because each tick is a full authenticated round trip to the user's
    /// own server. It stops the moment the modal is dismissed, like the stream does.
    public static let snapshotRefreshInterval: TimeInterval = 1
}
