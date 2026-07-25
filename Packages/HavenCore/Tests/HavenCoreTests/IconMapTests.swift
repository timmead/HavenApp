import Testing
@testable import HavenCore

@Test func iconMap() {
    #expect(IconMap.symbol(domain: .light, deviceClass: nil) == "lightbulb.fill")
    #expect(IconMap.symbol(domain: .cover, deviceClass: nil) == "blinds.horizontal.closed")
    #expect(IconMap.symbol(domain: .lock, deviceClass: nil) == "lock.fill")
    #expect(IconMap.symbol(domain: .climate, deviceClass: nil) == "thermometer.medium")
    #expect(IconMap.symbol(domain: .scene, deviceClass: nil) == "sparkles")
    #expect(IconMap.symbol(domain: .sensor, deviceClass: "temperature") == "thermometer.medium")
    #expect(IconMap.symbol(domain: .sensor, deviceClass: "humidity") == "humidity.fill")
    #expect(IconMap.symbol(domain: .sensor, deviceClass: "power") == "bolt.fill")
    #expect(IconMap.symbol(domain: .binarySensor, deviceClass: "door") == "door.left.hand.open")
    #expect(IconMap.symbol(domain: .binarySensor, deviceClass: "motion") == "figure.walk.motion")
    #expect(IconMap.symbol(domain: .unknown, deviceClass: nil) == "square.dashed")
}
