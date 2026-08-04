import Foundation

/// Every kind of device Haven can render.
///
/// **A table, deliberately, and each row is an argument.** The same shape as
/// `DeviceCurationRule.defaultRules`: a handful of entries, each added on purpose with a test, rather
/// than a mechanism for generating them. If this ever becomes dozens the thing that would change is
/// how renderers are resolved — a note, not a design being built for now.
///
/// Most rows are one entity and exist so that *every* tile is a device: a light is a device of type
/// `light` whose primary is itself. That uniformity is the point — nothing in the app has to ask
/// whether it is looking at a plain entity or a composite.
///
/// The interesting rows are the ones that combine entities, which is what Haven adds over rendering
/// Home Assistant's model directly.
public enum DeviceTypes {
    /// A device whose primary is the only entity it has. One per domain that renders.
    static func simple(_ id: String, _ name: String, _ domain: Domain) -> DeviceType {
        DeviceType(id: id, name: name,
                   roles: [DeviceTypeRole(role: .primary, domains: [domain],
                                          cardinality: .one, isRequired: true)])
    }

    public static let all: [DeviceType] = [
        simple("light", "Light", .light),
        simple("switch", "Switch", .switchOutlet),
        simple("cover", "Shade", .cover),
        simple("lock", "Lock", .lock),
        simple("climate", "Thermostat", .climate),
        simple("media_player", "Media player", .mediaPlayer),
        simple("camera", "Camera", .camera),
        simple("scene", "Scene", .scene),
        simple("script", "Script", .script),
        simple("button", "Button", .button),
        simple("sensor", "Sensor", .sensor),
        simple("binary_sensor", "Binary sensor", .binarySensor),
        simple("unknown", "Device", .unknown),

        // A cover with the two sensors that let it say "Partly open" — a state the cover entity
        // itself has no word for. See `CompositeState.derivedFace`.
        DeviceType(id: "garage_door", name: "Garage door", roles: [
            DeviceTypeRole(role: .primary, domains: [.cover], cardinality: .one, isRequired: true),
            DeviceTypeRole(role: .openLimit, domains: [.binarySensor], cardinality: .one),
            DeviceTypeRole(role: .closedLimit, domains: [.binarySensor], cardinality: .one),
        ]),

        // Several shades as one tile. The primary is the **master**: its position is what the tile
        // shows, and every follower receives the same commands.
        DeviceType(id: "shade_group", name: "Shade group", roles: [
            DeviceTypeRole(role: .primary, domains: [.cover], cardinality: .one, isRequired: true),
            DeviceTypeRole(role: .follower, domains: [.cover], cardinality: .many),
        ]),
    ]

    public static func type(id: String) -> DeviceType? { all.first { $0.id == id } }

    /// The type a device gets when nobody has said otherwise: the one-entity type for its domain.
    public static func `default`(for entityId: String) -> DeviceType {
        let domain = Domain.of(entityId)
        return all.first { $0.roles.count == 1 && $0.acceptsAsPrimary(entityId) }
            ?? simple(domain.rawValue, "Device", domain)
    }

    /// Every type this entity could be the primary of — what the `+` flow offers.
    ///
    /// **The default first**, so a chooser can present it as the obvious answer, and so a caller
    /// that ignores the rest still gets today's behaviour. A single candidate means there is no
    /// choice to make and the step is skipped.
    public static func candidates(for entityId: String) -> [DeviceType] {
        let fallback = `default`(for: entityId)
        let others = all.filter { $0.acceptsAsPrimary(entityId) && $0.id != fallback.id }
        return [fallback] + others
    }
}
