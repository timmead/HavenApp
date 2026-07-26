import Foundation
import Testing
@testable import HavenCore

private func candidate(_ id: String, device: String? = nil, deviceClass: String? = nil) -> CameraEventCandidate {
    CameraEventCandidate(entityId: id, deviceId: device, deviceClass: deviceClass)
}

// MARK: - The strong rung: same device

@Test func sensorsOnTheCamerasOwnDeviceAreTheAnswer() {
    let related = CameraEvents.related(
        cameraId: "camera.porch", cameraDeviceId: "dev-1",
        candidates: [
            candidate("binary_sensor.porch_motion", device: "dev-1", deviceClass: "motion"),
            candidate("binary_sensor.hall_motion", device: "dev-2", deviceClass: "motion"),
        ])
    #expect(related.map(\.entityId) == ["binary_sensor.porch_motion"])
    #expect(related.first?.kind == .motion)
}

/// The failure that matters is the loose one. Two cameras sharing a name stem must not adopt each
/// other's sensors — "Events" naming another camera's motion is a false statement about the home —
/// so the stem fallback is consulted only when the device join produced nothing at all, never
/// merged with it.
@Test func stemMatchingIsNeverMergedWithADeviceMatch() {
    let related = CameraEvents.related(
        cameraId: "camera.front", cameraDeviceId: "dev-1",
        candidates: [
            candidate("binary_sensor.front_motion", device: "dev-1", deviceClass: "motion"),
            // Same stem, different device: another camera's sensor.
            candidate("binary_sensor.front_gate_person", device: "dev-9", deviceClass: "motion"),
        ])
    #expect(related.map(\.entityId) == ["binary_sensor.front_motion"])
}

// MARK: - The fallback rung: name stem

@Test func aDevicelessCameraFallsBackToItsNameStem() {
    let related = CameraEvents.related(
        cameraId: "camera.front_door", cameraDeviceId: nil,
        candidates: [
            candidate("binary_sensor.front_door_motion", deviceClass: "motion"),
            candidate("binary_sensor.front_door_doorbell", deviceClass: "occupancy"),
            candidate("binary_sensor.garage_motion", deviceClass: "motion"),
        ])
    #expect(related.map(\.entityId) == ["binary_sensor.front_door_doorbell",
                                        "binary_sensor.front_door_motion"])
}

/// A camera whose device id matched nothing still gets the fallback — the rung exists for
/// integrations that register a device but hang the sensors off a different one.
@Test func aDeviceThatMatchesNothingStillFallsBackToTheStem() {
    let related = CameraEvents.related(
        cameraId: "camera.front_door", cameraDeviceId: "dev-lonely",
        candidates: [candidate("binary_sensor.front_door_motion", device: "dev-other", deviceClass: "motion")])
    #expect(related.map(\.entityId) == ["binary_sensor.front_door_motion"])
}

/// A stem too short is not evidence. `camera.cam` must not adopt every sensor in the home whose id
/// begins with those three letters.
@Test func aStemTooShortToMeanAnythingMatchesNothing() {
    let related = CameraEvents.related(
        cameraId: "camera.cam", cameraDeviceId: nil,
        candidates: [candidate("binary_sensor.campervan_motion", deviceClass: "motion")])
    #expect(related.isEmpty)
}

@Test func noCandidatesYieldsNoChipsRatherThanAnEmptyCardOfPlaceholders() {
    #expect(CameraEvents.related(cameraId: "camera.porch", cameraDeviceId: "dev-1", candidates: []).isEmpty)
}

// MARK: - What counts as an event

/// Everything else on a camera's device — its battery, its connectivity flag, a firmware update —
/// shares the device id and must not turn an "Events" card into a device inventory.
@Test func deviceTelemetrySharingTheDeviceIsNotAnEvent() {
    let related = CameraEvents.related(
        cameraId: "camera.porch", cameraDeviceId: "dev-1",
        candidates: [
            candidate("binary_sensor.porch_motion", device: "dev-1", deviceClass: "motion"),
            candidate("binary_sensor.porch_battery", device: "dev-1", deviceClass: "battery"),
            candidate("binary_sensor.porch_connectivity", device: "dev-1", deviceClass: "connectivity"),
            candidate("binary_sensor.porch_update", device: "dev-1", deviceClass: "update"),
        ])
    #expect(related.map(\.entityId) == ["binary_sensor.porch_motion"])
}

/// Only `binary_sensor`s. A camera's device also carries `sensor`, `select` and `switch` entities,
/// and none of them is an event.
@Test func onlyBinarySensorsAreConsidered() {
    let related = CameraEvents.related(
        cameraId: "camera.porch", cameraDeviceId: "dev-1",
        candidates: [
            candidate("sensor.porch_motion", device: "dev-1", deviceClass: "motion"),
            candidate("switch.porch_motion_detection", device: "dev-1"),
            candidate("binary_sensor.porch_motion", device: "dev-1", deviceClass: "motion"),
        ])
    #expect(related.map(\.entityId) == ["binary_sensor.porch_motion"])
}

/// A doorbell whose device class says `occupancy` is a doorbell. Labelling it "Motion" because of
/// its device class would be the more confident of the two available wrong answers, and doorbell is
/// the single most important chip on the card.
@Test func aDoorbellIsRecognisedFromItsIdEvenWhenItsDeviceClassSaysOccupancy() {
    let related = CameraEvents.related(
        cameraId: "camera.porch", cameraDeviceId: "dev-1",
        candidates: [candidate("binary_sensor.porch_doorbell", device: "dev-1", deviceClass: "occupancy")])
    #expect(related.first?.kind == .doorbell)
}

@Test func deviceClassesMapToTheKindTheChipShows() {
    func kind(_ deviceClass: String?, id: String = "binary_sensor.porch_x") -> CameraEventSensor.Kind? {
        CameraEvents.sensor(candidate(id, deviceClass: deviceClass))?.kind
    }
    #expect(kind("motion") == .motion)
    #expect(kind("occupancy") == .motion)
    #expect(kind("presence") == .person)
    #expect(kind("sound") == .sound)
    #expect(kind("tamper") == .tamper)
    #expect(kind("battery") == nil)
    #expect(kind(nil) == nil)
    #expect(kind(nil, id: "binary_sensor.porch_person_detected") == .person)
}

/// `"ring"` is deliberately not a doorbell fragment: matched as a substring it would claim
/// `binary_sensor.spring_room_motion`.
@Test func doorbellFragmentsDoNotMatchInsideUnrelatedWords() {
    #expect(CameraEvents.sensor(candidate("binary_sensor.spring_room_motion", deviceClass: "motion"))?.kind == .motion)
}

// MARK: - Ordering

/// Stable, and most-alarming first: a doorbell press must never sit behind a tamper flag, and the
/// card must not reshuffle on every state push.
@Test func chipsAreOrderedByKindThenId() {
    let related = CameraEvents.related(
        cameraId: "camera.porch", cameraDeviceId: "dev-1",
        candidates: [
            candidate("binary_sensor.porch_tamper", device: "dev-1", deviceClass: "tamper"),
            candidate("binary_sensor.porch_sound", device: "dev-1", deviceClass: "sound"),
            candidate("binary_sensor.porch_motion", device: "dev-1", deviceClass: "motion"),
            candidate("binary_sensor.porch_person", device: "dev-1", deviceClass: "presence"),
            candidate("binary_sensor.porch_doorbell", device: "dev-1", deviceClass: "occupancy"),
        ])
    #expect(related.map(\.kind) == [.doorbell, .person, .motion, .sound, .tamper])
}

@Test func everyKindHasALabelAndASymbol() {
    for kind in CameraEventSensor.Kind.allCases {
        #expect(!kind.label.isEmpty)
        #expect(!kind.symbol.isEmpty)
    }
}
