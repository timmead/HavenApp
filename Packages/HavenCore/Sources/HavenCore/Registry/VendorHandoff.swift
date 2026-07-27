import Foundation

/// Ordered candidate deep links for handing a camera or speaker off to its vendor's own app,
/// derived from an entity's registry `platform` (the owning integration's domain) and
/// `unique_id`. Pure and data-only — this produces `URL`s and nothing more. `App/`'s camera and
/// media player modals try each candidate in turn with `canOpenURL`/`open` and hide the hand-off
/// button entirely when none opens: a ladder, never a cliff. The point of Haven staying out of
/// camera scrubbing/timeline/history and Sonos grouping/browsing is to route straight to the
/// vendor's own app for that, not to almost do it.
///
/// **What is verified and what is not.** `platform` values (`"unifiprotect"`, `"sonos"`) are
/// confirmed present on every row of `config/entity_registry/list` against Home Assistant's
/// source. Everything below that line is a hypothesis, not a confirmed fact, and each is a
/// separate thing that could turn out to be wrong:
///
/// - **UniFi Protect's per-device path** (`unifi-protect://protect/devices/<id>`) is a guess at
///   the scheme's shape. Ubiquiti's own community threads describing custom URL schemes are
///   JavaScript-rendered and returned no readable content to check against, so this has not been
///   confirmed to open the app, let alone a specific device.
/// - **Whether HA's `unique_id` for a Protect entity is even the id Protect's own URL scheme
///   expects is a second, independent assumption on top of the URL shape.** Integrations
///   routinely compose `unique_id` from other things (a `"{mac}_{sensor_key}"`-style suffix is a
///   common pattern), so it may be a bare device id, a device id with something appended, or
///   unrelated to Protect's own addressing entirely. If the per-device link doesn't work, there
///   are two independent places to check, not one.
/// - **The bare `unifi-protect://` app-launch scheme is also unconfirmed** — nothing consulted
///   while building this states it, it is simply the conventional guess for "the app's own
///   scheme with no path."
/// - **Sonos has no documented inbound deep link at all.** Sonos's official documentation covers
///   only the *outbound* direction — its app linking out to a third-party app — and says nothing
///   about a third-party app linking into Sonos. `sonos://` is a guess at the bare app-launch
///   scheme, not a confirmed one, and there is no per-device form to even guess at, which is why
///   Sonos has only ever the one candidate.
///
/// Each guessed string is written so it can be corrected in exactly one place the moment it is
/// checked against a real device, without touching the ladder logic around it.
public enum VendorHandoff {
    /// Ordered candidates for `platform`/`uniqueId`, most useful first: a per-device deep link
    /// where one is hypothesized at all, then a bare app-launch scheme, then nothing. An
    /// unrecognised platform returns an empty list — the caller hides its hand-off button
    /// entirely in that case, never offering a tap that does nothing.
    ///
    /// A nil, empty, or otherwise unencodable `uniqueId` never drops the whole ladder down to
    /// nothing: if the per-device URL can't be built, the plain app-launch candidate is still
    /// returned. Losing every candidate because one failed to construct would be exactly the
    /// cliff this type exists to avoid.
    public static func candidates(platform: String?, uniqueId: String?) -> [URL] {
        switch platform {
        case "unifiprotect":
            var urls: [URL] = []
            if let deviceURL = perDeviceUniFiProtectURL(uniqueId: uniqueId) { urls.append(deviceURL) }
            if let appURL = URL(string: "unifi-protect://") { urls.append(appURL) }
            return urls
        case "sonos":
            return [URL(string: "sonos://")].compactMap { $0 }
        default:
            return []
        }
    }

    /// One string to change once the `unifi-protect://protect/devices/<id>` guess (see the type's
    /// doc comment) is tested against a real device.
    ///
    /// `uniqueId` is percent-encoded against a conservative allowed set — alphanumerics plus
    /// `-._~` — rather than a path-safe one. HA unique ids derived from MAC addresses commonly
    /// contain `:`, and some integrations use composite ids containing `/`; both must be escaped
    /// into the path segment, not read as path structure, or the resulting URL would silently
    /// point somewhere else entirely.
    private static func perDeviceUniFiProtectURL(uniqueId: String?) -> URL? {
        guard let uniqueId, !uniqueId.isEmpty else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        guard let encoded = uniqueId.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "unifi-protect://protect/devices/\(encoded)")
    }
}
