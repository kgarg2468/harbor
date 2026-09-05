import Foundation

/// User settings, persisted as `config.json` (spec section 10).
/// Decoding tolerates missing keys so configs written by older builds load
/// with defaults filled in.
struct Config: Codable, Equatable, Sendable {
    // Session
    /// Preset durations in seconds, shown in the right-click menu and Settings.
    var presets: [TimeInterval] = Config.defaultPresets
    var defaultPreset: TimeInterval = 4 * 3600
    /// Hard ceiling on a session, including extensions. 30 days.
    var maxDuration: TimeInterval = 30 * 24 * 3600

    // Lid-close actions
    /// Bundle ids to SIGSTOP while the lid is closed.
    var freezeList: [String] = Config.defaultFreezeList
    var dockerRule: Bool = false
    var browserThrottleEnabled: Bool = false
    var muteOnLidClose: Bool = false

    // Apps protected from normal freezing. The opt-in Docker rule is an exception.
    var agentList: [String] = Config.defaultAgentList

    // Battery / thermal floors
    /// Battery percentage below which Low Power Mode is switched on.
    var lowPowerFloor: Int = 40
    /// Battery percentage below which the session is ended.
    var endFloor: Int = 10
    var thermalRules: Bool = true

    // Network failover
    var hotspotSSID: String = ""
    /// Seconds of outage after which tmux panes are nudged.
    var nudgeThreshold: TimeInterval = 90
    /// tmux targets as `session:window.pane`.
    var tmuxTargets: [String] = []

    // App
    var launchAtLogin: Bool = false

    static let defaultPresets: [TimeInterval] = [
        30 * 60,
        1 * 3600,
        2 * 3600,
        4 * 3600,
        8 * 3600,
        12 * 3600,
        24 * 3600,
        3 * 24 * 3600,
    ]

    /// Default freeze list: chat apps that burn battery in the background.
    static let defaultFreezeList: [String] = [
        "com.tinyspeck.slackmacgap",      // Slack
        "net.whatsapp.WhatsApp",          // WhatsApp
        "com.hnc.Discord",                // Discord
    ]

    /// Default agent list (spec section 5). Bundle ids confirmed against
    /// installed apps where possible; see README for how to edit.
    static let defaultAgentList: [String] = [
        "com.t3tools.t3code",             // T3 Code (Nightly)
        "com.t3tools.t3code.reasoning",   // T3 Code (Reasoning)
        "com.conductor.app",              // Conductor
        "com.apple.Terminal",             // Terminal
        "com.googlecode.iterm2",          // iTerm2
        "com.mitchellh.ghostty",          // Ghostty
        "dev.warp.Warp-Stable",           // Warp
        "com.google.Chrome",              // Google Chrome
        "org.chromium.Chromium",          // Chromium
        "company.thebrowser.Browser",     // Arc
        "com.docker.docker",              // Docker Desktop
    ]

    /// Transient explanation; never written into the user's configuration.
    var floorCorrectionNotice: String?

    private enum CodingKeys: String, CodingKey {
        case presets, defaultPreset, maxDuration, freezeList, dockerRule, browserThrottleEnabled
        case muteOnLidClose, agentList, lowPowerFloor, endFloor, thermalRules
        case hotspotSSID, nudgeThreshold, tmuxTargets, launchAtLogin
    }

    enum ValidationError: Error, LocalizedError {
        case batteryFloors
        var errorDescription: String? {
            "Battery thresholds must be 1–99%, with the end threshold at or below the Low Power Mode threshold."
        }
    }

    func validateFloors() throws {
        guard (1...99).contains(lowPowerFloor), (1...99).contains(endFloor), endFloor <= lowPowerFloor else {
            throw ValidationError.batteryFloors
        }
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        presets = try c.decodeIfPresent([TimeInterval].self, forKey: .presets) ?? d.presets
        defaultPreset = try c.decodeIfPresent(TimeInterval.self, forKey: .defaultPreset) ?? d.defaultPreset
        maxDuration = try c.decodeIfPresent(TimeInterval.self, forKey: .maxDuration) ?? d.maxDuration
        freezeList = try c.decodeIfPresent([String].self, forKey: .freezeList) ?? d.freezeList
        dockerRule = try c.decodeIfPresent(Bool.self, forKey: .dockerRule) ?? d.dockerRule
        browserThrottleEnabled = try c.decodeIfPresent(Bool.self, forKey: .browserThrottleEnabled) ?? d.browserThrottleEnabled
        muteOnLidClose = try c.decodeIfPresent(Bool.self, forKey: .muteOnLidClose) ?? d.muteOnLidClose
        agentList = try c.decodeIfPresent([String].self, forKey: .agentList) ?? d.agentList
        do {
            lowPowerFloor = try c.decodeIfPresent(Int.self, forKey: .lowPowerFloor) ?? d.lowPowerFloor
            endFloor = try c.decodeIfPresent(Int.self, forKey: .endFloor) ?? d.endFloor
            try validateFloors()
        } catch {
            lowPowerFloor = d.lowPowerFloor
            endFloor = d.endFloor
            floorCorrectionNotice = "Saved battery thresholds were invalid. Using 40% for Low Power Mode and 10% to end sessions. Save these defaults or choose valid thresholds below."
        }
        thermalRules = try c.decodeIfPresent(Bool.self, forKey: .thermalRules) ?? d.thermalRules
        hotspotSSID = try c.decodeIfPresent(String.self, forKey: .hotspotSSID) ?? d.hotspotSSID
        nudgeThreshold = try c.decodeIfPresent(TimeInterval.self, forKey: .nudgeThreshold) ?? d.nudgeThreshold
        tmuxTargets = try c.decodeIfPresent([String].self, forKey: .tmuxTargets) ?? d.tmuxTargets
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? d.launchAtLogin
    }
}
