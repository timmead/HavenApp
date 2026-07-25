public enum IconMap {
    public static func symbol(domain: Domain, deviceClass: String?) -> String {
        switch domain {
        case .light: return "lightbulb.fill"
        case .switchOutlet: return "poweroutlet.type.b.fill"
        case .cover: return "blinds.horizontal.closed"
        case .lock: return "lock.fill"
        case .climate: return "thermometer.medium"
        case .scene: return "sparkles"
        case .script, .button: return "play.circle.fill"
        case .sensor: return sensorSymbol(deviceClass)
        case .binarySensor: return binarySymbol(deviceClass)
        case .unknown: return "square.dashed"
        }
    }
    private static func sensorSymbol(_ dc: String?) -> String {
        switch dc {
        case "temperature": return "thermometer.medium"
        case "humidity": return "humidity.fill"
        case "power", "energy": return "bolt.fill"
        case "battery": return "battery.50"
        case "co2", "carbon_dioxide": return "carbon.dioxide.cloud.fill"
        case "illuminance": return "sun.max.fill"
        case "pressure": return "gauge.medium"
        default: return "chart.line.uptrend.xyaxis"
        }
    }
    private static func binarySymbol(_ dc: String?) -> String {
        switch dc {
        case "door", "garage_door": return "door.left.hand.open"
        case "window", "opening": return "window.vertical.open"
        case "motion", "occupancy", "presence": return "figure.walk.motion"
        case "moisture": return "drop.fill"
        case "smoke": return "smoke.fill"
        case "gas", "carbon_monoxide": return "aqi.medium"
        default: return "dot.radiowaves.left.and.right"
        }
    }
}
