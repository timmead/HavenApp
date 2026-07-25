import os

/// App-wide logger for connection diagnostics. Visible in Console/Xcode, quiet in
/// release builds, and never carries token material.
let havenLog = Logger(subsystem: "app.haven.HavenApp", category: "connection")
