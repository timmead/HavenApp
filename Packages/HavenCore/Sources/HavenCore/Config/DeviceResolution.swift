import Foundation

/// Resolving "what is this device" from what the household stored.
///
/// These three reads used to live on `App/HomeStore`, where nothing could reach them directly:
/// each is a pure function of the document, so the app-layer tests that covered them had to stand
/// up a live store and a fake connection to exercise a dictionary lookup. They are the same
/// answers, in the layer that owns the storage they read, with `DeviceResolutionTests` on them.
///
/// Kept as an extension on the document rather than a type of their own because they hold no state
/// and answer about *one* document — a `DeviceDirectory` object would need a copy of it, and a copy
/// is a thing that can go stale.
extension DashboardDocument {
    /// The device behind an id — a stored composite, or the entity itself.
    ///
    /// **The fallback is the whole model**: a light's device is implied by the light existing,
    /// which is why no stored record had to move when devices arrived and why every caller can ask
    /// without first checking whether one was ever configured.
    public func deviceRef(for id: String) -> DeviceRef {
        guard let stored = devices[id] else { return .entity(id) }
        return .composite(id: id, type: stored.type, inputs: stored.inputs)
    }

    /// What kind of thing a device is. A stored composite says so; anything else is the one-entity
    /// type for its domain.
    ///
    /// A stored type this build does not recognise also falls back to the domain default, rather
    /// than failing to resolve: a document written by a newer build must still render something.
    /// That is the read-side half of `isWritable`'s stance — never *write* a schema you don't
    /// understand, but always show what you can of one.
    public func deviceType(for id: String) -> DeviceType {
        if let stored = devices[id], let type = DeviceTypes.type(id: stored.type) {
            return type
        }
        return DeviceTypes.default(for: id)
    }

    /// Which entity plays which role for this device.
    ///
    /// **Read from the device's own inputs**, which is the one place roles live. An earlier
    /// revision stored them under `entities.<id>.bindings` — a second home for the same idea, from
    /// before choosing a type *was* creating a device.
    ///
    /// One entity per role, taken from the front of each stored list: the storage holds arrays
    /// because a shade group's followers are many, but every role a picker binds is single-valued.
    /// A role whose list is empty drops out rather than reading as bound-to-nothing.
    public func roleBindings(for id: String) -> [DeviceRole: String] {
        guard let stored = devices[id] else { return [:] }
        return stored.inputs.compactMapValues(\.first)
    }
}
