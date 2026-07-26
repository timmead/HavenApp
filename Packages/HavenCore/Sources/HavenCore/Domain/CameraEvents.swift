import Foundation

/// One binary sensor offered to `CameraEvents` as a possible companion of a camera.
///
/// Deliberately not `EntityRegistryEntry`: the caller (a modal holding one entity id) reads these
/// from `ResolvedHome.registryInfo` and `states`, and passing the registry entry would mean
/// threading area/curation fields through a function that has no business consulting them.
public struct CameraEventCandidate: Sendable, Equatable {
    public let entityId: String
    /// HA's `device_id`. The strong signal — a doorbell's motion sensor and its camera are two
    /// entities of one physical device — and `nil` for the many integrations that create entities
    /// without a device at all.
    public let deviceId: String?
    /// `device_class` from the entity's live state.
    public let deviceClass: String?

    public init(entityId: String, deviceId: String?, deviceClass: String?) {
        self.entityId = entityId
        self.deviceId = deviceId
        self.deviceClass = deviceClass
    }
}

/// A binary sensor that belongs with a camera, and what kind of event it reports.
public struct CameraEventSensor: Sendable, Equatable, Identifiable {
    /// Only the kinds worth a chip beside a camera. Everything else about a camera's device —
    /// a tamper switch's battery, a firmware-update flag — is not an *event*, and the card would
    /// stop being scannable the moment it started listing them.
    public enum Kind: String, Sendable, Equatable, CaseIterable {
        case motion, person, doorbell, sound, tamper

        /// The chip's label. Carried as text and not only as an icon, because the icon is the part
        /// a VoiceOver user does not get.
        public var label: String {
            switch self {
            case .motion: return "Motion"
            case .person: return "Person"
            case .doorbell: return "Doorbell"
            case .sound: return "Sound"
            case .tamper: return "Tamper"
            }
        }

        public var symbol: String {
            switch self {
            case .motion: return "figure.walk.motion"
            case .person: return "person.fill"
            case .doorbell: return "bell.fill"
            case .sound: return "waveform"
            case .tamper: return "exclamationmark.shield.fill"
            }
        }

        /// Most-alarming first, so a doorbell press never sits behind a tamper flag in the card.
        var rank: Int {
            switch self {
            case .doorbell: return 0
            case .person: return 1
            case .motion: return 2
            case .sound: return 3
            case .tamper: return 4
            }
        }
    }

    public let entityId: String
    public let kind: Kind
    public var id: String { entityId }

    public init(entityId: String, kind: Kind) {
        self.entityId = entityId
        self.kind = kind
    }
}

/// Which binary sensors belong to a camera, for the modal's **Events** card.
///
/// A **ladder, never a cliff**, exactly as `VendorHandoff` is: the same `device_id` is the answer
/// where the integration provides one, and an object-id stem match is the fallback where it does
/// not. Getting this wrong in the *loose* direction is the failure that matters — a card headed
/// "Events" listing the neighbouring room's motion sensor is a statement about the user's home
/// that is simply untrue — so the fallback is only ever consulted when the strong signal produced
/// nothing at all, and never merged with it.
public enum CameraEvents {
    /// `binary_sensor` device classes that describe something *happening* in front of a camera.
    ///
    /// `occupancy` and `presence` are in because integrations disagree about which of the three
    /// they use for the same physical PIR — UniFi Protect's doorbell ring, in the versions that
    /// still model it as a binary sensor rather than an `event` entity, arrives as `occupancy`.
    /// `sound` and `tamper` are in because both are things a camera detected. `battery`,
    /// `connectivity`, `update` and the rest are deliberately out: they describe the device, not
    /// the scene.
    static let eventDeviceClasses: Set<String> = [
        "motion", "occupancy", "presence", "sound", "tamper",
    ]

    /// Object-id fragments that name an event no `device_class` covers. A Protect doorbell is
    /// commonly `binary_sensor.<name>_doorbell` with a device class that says `occupancy` at best.
    ///
    /// Matched as plain substrings, which is why the obvious member is missing: `"ring"` would
    /// claim `binary_sensor.spring_room_motion` as a doorbell. A fragment here has to be a word
    /// that cannot appear inside an unrelated one.
    static let doorbellFragments: Set<String> = ["doorbell", "chime"]
    static let personFragments: Set<String> = ["person", "human"]

    /// The event sensors for `cameraId`, ordered by kind then id so the card doesn't reshuffle on
    /// every state push.
    ///
    /// - Parameter cameraDeviceId: the camera's own `device_id`, or `nil`. `nil` skips the strong
    ///   rung entirely rather than matching every other device-less entity in the home against it,
    ///   which is what a naive `==` on two optionals would do.
    public static func related(cameraId: String,
                               cameraDeviceId: String?,
                               candidates: [CameraEventCandidate]) -> [CameraEventSensor] {
        let eligible = candidates.filter { Domain.serviceDomain(of: $0.entityId) == "binary_sensor" }

        if let cameraDeviceId, !cameraDeviceId.isEmpty {
            let sameDevice = eligible.filter { $0.deviceId == cameraDeviceId }
            if !sameDevice.isEmpty { return sorted(sameDevice.compactMap(sensor)) }
        }
        // Only now, and only from the camera's own name. `objectStem` returns `nil` for a stem too
        // short to mean anything, which is what stops a camera called `camera.cam` from adopting
        // every sensor whose id happens to start with those three letters.
        guard let stem = objectStem(cameraId) else { return [] }
        let sameStem = eligible.filter { objectId($0.entityId).hasPrefix(stem) }
        return sorted(sameStem.compactMap(sensor))
    }

    /// The kind a candidate reports, or `nil` if it reports nothing a camera cares about.
    ///
    /// The id is consulted *before* the device class for doorbell and person, because those two
    /// are the ones integrations have no accurate device class for — `binary_sensor.porch_doorbell`
    /// labelled `occupancy` is a doorbell, and calling it "Motion" because of its device class
    /// would be the more confident of the two available wrong answers.
    static func sensor(_ candidate: CameraEventCandidate) -> CameraEventSensor? {
        let object = objectId(candidate.entityId)
        let deviceClass = candidate.deviceClass?.lowercased()
        let kind: CameraEventSensor.Kind?
        if doorbellFragments.contains(where: object.contains) {
            kind = .doorbell
        } else if personFragments.contains(where: object.contains) {
            kind = .person
        } else {
            switch deviceClass {
            case "motion", "occupancy": kind = .motion
            case "presence": kind = .person
            case "sound": kind = .sound
            case "tamper": kind = .tamper
            default: kind = nil
            }
        }
        // A device-class-less sensor whose id said nothing either is dropped rather than guessed
        // at. An "Events" card is only worth having if everything on it is really an event — a
        // battery or connectivity flag sharing the camera's device would otherwise land here and
        // quietly turn the card into a device inventory.
        guard let kind else { return nil }
        return CameraEventSensor(entityId: candidate.entityId, kind: kind)
    }

    private static func sorted(_ sensors: [CameraEventSensor]) -> [CameraEventSensor] {
        sensors.sorted {
            $0.kind.rank == $1.kind.rank ? $0.entityId < $1.entityId : $0.kind.rank < $1.kind.rank
        }
    }

    private static func objectId(_ entityId: String) -> String {
        guard let dot = entityId.firstIndex(of: ".") else { return entityId.lowercased() }
        return String(entityId[entityId.index(after: dot)...]).lowercased()
    }

    /// The camera's object id as a prefix to match companions against, or `nil` when it is too
    /// short to be evidence of anything. Four characters is the shortest stem that isn't a
    /// coincidence waiting to happen (`cam`, `hall` — the latter passes, deliberately).
    private static func objectStem(_ cameraId: String) -> String? {
        let object = objectId(cameraId)
        return object.count >= 4 ? object : nil
    }
}
