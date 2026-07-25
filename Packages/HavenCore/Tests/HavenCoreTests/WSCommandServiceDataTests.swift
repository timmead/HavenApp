import Testing
import Foundation
@testable import HavenCore

private func obj(_ d: Data) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:]
}

@Test func callServiceWithData() {
    let o = obj(WSCommand.callService(id: 3, domain: "light", service: "turn_on", entityId: "light.k",
                                      serviceData: ["brightness_pct": .int(60)]))
    #expect(o["type"] as? String == "call_service")
    #expect(((o["target"] as? [String:Any])?["entity_id"]) as? String == "light.k")
    #expect(((o["service_data"] as? [String:Any])?["brightness_pct"]) as? Int == 60)
}

@Test func statisticsCommand() {
    let o = obj(WSCommand.statisticsDuringPeriod(id: 5, statisticId: "sensor.p", startISO: "2026-07-01T00:00:00Z", endISO: "2026-07-02T00:00:00Z", period: "hour"))
    #expect(o["type"] as? String == "recorder/statistics_during_period")
    #expect((o["statistic_ids"] as? [String])?.first == "sensor.p")
    #expect(o["period"] as? String == "hour")
}
