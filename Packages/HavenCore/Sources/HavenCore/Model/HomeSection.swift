public enum SectionKind: Sendable, Equatable { case room }

public struct UpliftedSensor: Sendable, Equatable {
    public enum Role: Sendable, Equatable { case temperature, humidity }
    public let role: Role
    public let entityId: String
}

public struct RoomSection: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let kind: SectionKind = .room
    public let areaId: String
    public let headerSensors: [UpliftedSensor]
    public let deviceRefs: [DeviceRef]
}

public enum SectionBuilder {
    public static func rooms(from home: ResolvedHome) -> [RoomSection] {
        home.floors.flatMap(\.areas).map { area in
            var header: [UpliftedSensor] = []
            if let t = area.temperatureEntityId { header.append(.init(role: .temperature, entityId: t)) }
            if let h = area.humidityEntityId { header.append(.init(role: .humidity, entityId: h)) }
            let uplifted = Set(header.map(\.entityId))
            let devices = area.entityIds.filter { !uplifted.contains($0) }.map { DeviceRef.entity($0) }
            return RoomSection(id: area.id, name: area.name, areaId: area.id, headerSensors: header, deviceRefs: devices)
        }
    }
}
