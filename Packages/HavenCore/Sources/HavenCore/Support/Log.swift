import os

/// Package-scoped logger for HavenCore-internal diagnostics — deliberately named distinctly from
/// the App target's own `havenLog` (`App/Log.swift`), since `App` imports `HavenCore` and a
/// second top-level `havenLog` here would collide with it.
///
/// Used sparingly, and only where a wrong assumption about Home Assistant's wire format needs to
/// fail visibly instead of silently degrading into a confident-looking wrong answer — see
/// `HomeConnection.fetchInstanceConfig`'s use of this for `get_config`'s `components` field.
let havenCoreLog = Logger(subsystem: "app.haven.HavenCore", category: "onboarding")
