import AppKit
import Observation
import ServiceManagement
import SwiftUI

/// The settings window (spec 10). Every change is written straight through
/// `manager.config` to config.json.
struct SettingsView: View {
    let manager: SessionManager
    let secrets: any HotspotSecretStore
    let locationPermission: LocationPermission

    @State private var editor: SettingsEditor
    @State private var secretError: String?

    init(manager: SessionManager, secrets: any HotspotSecretStore, locationPermission: LocationPermission) {
        self.manager = manager
        self.secrets = secrets
        self.locationPermission = locationPermission
        _editor = State(initialValue: SettingsEditor(manager: manager))
    }

    @State private var newPreset = ""
    @State private var presetError: String?
    @State private var newFreezeBundle = ""
    @State private var newAgentBundle = ""
    @State private var newTmuxTarget = ""
    @State private var hotspotPassword = ""
    @State private var hotspotSaved = false
    @State private var loginItemError: String?

    var body: some View {
        Form {
            if let notice = manager.config.floorCorrectionNotice {
                Section("Battery settings corrected") {
                    Text(notice)
                    Button("Save corrected defaults") { editor.save(manager.config) }
                }
            }
            if let error = editor.error {
                Text(error).foregroundStyle(.red)
            }
            sessionSection
            lidSection
            agentSection
            powerSection
            networkSection
            appSection
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .frame(minHeight: 560, idealHeight: 720)
        .onAppear {
            do { hotspotPassword = try secrets.load() ?? ""; secretError = nil }
            catch { secretError = "Could not load hotspot password: \(error.localizedDescription)" }
        }
    }

    // MARK: Bindings

    private func bind<T: Equatable>(_ keyPath: WritableKeyPath<Config, T>) -> Binding<T> {
        Binding(
            get: { manager.config[keyPath: keyPath] },
            set: { value in
                guard manager.config[keyPath: keyPath] != value else { return }
                update { $0[keyPath: keyPath] = value }
            }
        )
    }

    private func update(_ change: (inout Config) -> Void) {
        var c = manager.config
        change(&c)
        guard c != manager.config else { return }
        editor.save(c)
    }

    // MARK: Sections

    private var sessionSection: some View {
        Section("Session") {
            ForEach(manager.config.presets, id: \.self) { p in
                HStack {
                    Text(chipLabel(for: p))
                        .monospacedDigit()
                    Spacer()
                    if p == manager.config.defaultPreset {
                        Text("default").font(.caption).foregroundStyle(.secondary)
                    }
                    removeButton {
                        update { $0.presets.removeAll { $0 == p } }
                    }
                }
            }
            HStack {
                TextField("Add preset (30m, 2h, 1h30m, 3d)", text: $newPreset)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addPreset)
                Button("Add", action: addPreset)
                    .disabled(DurationParser.seconds(from: newPreset) == nil)
            }
            if let presetError {
                Text(presetError).font(.caption).foregroundStyle(.red)
            }
            Picker("Default preset", selection: bind(\.defaultPreset)) {
                ForEach(manager.config.presets, id: \.self) { p in
                    Text(chipLabel(for: p)).tag(p)
                }
                if !manager.config.presets.contains(manager.config.defaultPreset) {
                    Text(chipLabel(for: manager.config.defaultPreset)).tag(manager.config.defaultPreset)
                }
            }
            LabeledContent("Maximum session") {
                Text(chipLabel(for: manager.config.maxDuration)).foregroundStyle(.secondary)
            }
        }
    }

    private func addPreset() {
        guard let s = DurationParser.seconds(from: newPreset) else { return }
        guard s <= manager.config.maxDuration else {
            presetError = "Presets cannot exceed \(chipLabel(for: manager.config.maxDuration))."
            return
        }
        presetError = nil
        update {
            if !$0.presets.contains(s) {
                $0.presets.append(s)
                $0.presets.sort()
            }
        }
        newPreset = ""
    }

    private var lidSection: some View {
        Section {
            bundleList(
                title: "Freeze while the lid is closed",
                items: manager.config.freezeList,
                newValue: $newFreezeBundle,
                add: { id in update { if !$0.freezeList.contains(id) { $0.freezeList.append(id) } } },
                remove: { id in update { $0.freezeList.removeAll { $0 == id } } }
            )
            Toggle("Opt in: pause idle Docker Desktop", isOn: bind(\.dockerRule))
            Toggle("Opt in: mute audio on lid close", isOn: bind(\.muteOnLidClose))
        } header: {
            Text("Lid-close actions")
        } footer: {
            Text("Frozen apps are stopped with SIGSTOP and resumed when the lid opens. The agent list protects normal freezes. Opting into the Docker rule explicitly allows Docker Desktop to be paused even when it is on the agent list. Docker and audio recovery need testing on your Mac.")
        }
    }

    private var agentSection: some View {
        Section {
            Toggle("Opt in: browser flag checks and relaunch", isOn: bind(\.browserThrottleEnabled))
            Text("Browser relaunch closes and reopens selected Chromium browsers. Verify it preserves your profiles and work before relying on it.")
                .font(.caption).foregroundStyle(.secondary)
            bundleList(
                title: "Protected from normal freezing",
                items: manager.config.agentList,
                newValue: $newAgentBundle,
                add: { id in update { if !$0.agentList.contains(id) { $0.agentList.append(id) } } },
                remove: { id in update { $0.agentList.removeAll { $0 == id } } }
            )
        } header: {
            Text("Agent apps")
        }
    }

    private var powerSection: some View {
        Section("Battery and thermal") {
            Text("Thresholds must be 1–99%. The end threshold cannot exceed the Low Power Mode threshold. Changes apply to the current session immediately.")
                .font(.caption).foregroundStyle(.secondary)
            Stepper(value: bind(\.lowPowerFloor), in: manager.config.endFloor...99, step: 1) {
                LabeledContent("Low Power Mode below", value: "\(manager.config.lowPowerFloor)%")
            }
            Stepper(value: bind(\.endFloor), in: 1...manager.config.lowPowerFloor, step: 1) {
                LabeledContent("End session below", value: "\(manager.config.endFloor)%")
            }
            Toggle("Thermal rules (Low Power Mode when hot, end when critical)", isOn: bind(\.thermalRules))
        }
    }

    private var networkSection: some View {
        Section {
            TextField("Hotspot SSID (optional opt-in)", text: bind(\.hotspotSSID))
            HStack {
                SecureField("Hotspot password", text: $hotspotPassword)
                    .onSubmit(savePassword)
                Button(hotspotSaved ? "Saved" : "Save", action: savePassword)
                    .disabled(hotspotPassword.isEmpty)
            }
            if let secretError { Text(secretError).font(.caption).foregroundStyle(.red) }
            HStack {
                Text("Location: \(locationPermission.statusDescription)")
                    .foregroundStyle(.secondary)
                Spacer()
                if locationPermission.isDenied {
                    Button("Open Location Services") {
                        locationPermission.openLocationServicesSettings()
                    }
                }
            }
            Stepper(value: nudgeSeconds, in: 10...900, step: 10) {
                LabeledContent("Nudge tmux after", value: "\(Int(manager.config.nudgeThreshold)) s offline")
            }
            ForEach(manager.config.tmuxTargets, id: \.self) { t in
                HStack {
                    Text(t).font(.system(.body, design: .monospaced))
                    Spacer()
                    removeButton {
                        update { $0.tmuxTargets.removeAll { $0 == t } }
                    }
                }
            }
            HStack {
                TextField("tmux target (session:window.pane)", text: $newTmuxTarget)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addTmuxTarget)
                Button("Add", action: addTmuxTarget)
                    .disabled(newTmuxTarget.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            Text("Network failover")
        } footer: {
            Text("Hotspot failover is off until you enter an SSID. Adding a tmux target opts into sending “continue” and Enter to that pane after an outage. Test both integrations before relying on them. The password stays in the login keychain; Location permission allows Wi-Fi names and hotspot discovery.")
        }
    }

    private var nudgeSeconds: Binding<Int> {
        Binding(
            get: { Int(manager.config.nudgeThreshold) },
            set: { seconds in update { $0.nudgeThreshold = TimeInterval(seconds) } }
        )
    }

    private func savePassword() {
        if !manager.config.hotspotSSID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            locationPermission.requestWhenInUse()
        }
        do {
            if hotspotPassword.isEmpty {
                try secrets.delete()
            } else {
                try secrets.save(hotspotPassword)
            }
            hotspotSaved = true
            secretError = nil
        } catch {
            hotspotSaved = false
            secretError = "Could not save hotspot password: \(error.localizedDescription)"
        }
    }

    private func addTmuxTarget() {
        let t = newTmuxTarget.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        update { if !$0.tmuxTargets.contains(t) { $0.tmuxTargets.append(t) } }
        newTmuxTarget = ""
    }

    private var appSection: some View {
        Section("App") {
            Toggle("Launch at login", isOn: launchAtLogin)
            if let loginItemError {
                Text(loginItemError).font(.caption).foregroundStyle(.red)
            }
            LabeledContent("Config") {
                Text(manager.paths.configFile.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private var launchAtLogin: Binding<Bool> {
        Binding(
            get: { manager.config.launchAtLogin },
            set: { on in
                do {
                    if on {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                    loginItemError = nil
                    // Persist only what macOS actually applied.
                    update { $0.launchAtLogin = on }
                } catch {
                    loginItemError = "Login item: \(error.localizedDescription)"
                    Log.error("launch at login \(on ? "register" : "unregister") failed: \(error.localizedDescription)")
                }
            }
        )
    }

    // MARK: Bundle id lists

    private func bundleList(
        title: String,
        items: [String],
        newValue: Binding<String>,
        add: @escaping (String) -> Void,
        remove: @escaping (String) -> Void
    ) -> some View {
        Group {
            Text(title).font(.headline)
            ForEach(items, id: \.self) { id in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(RunningApps.displayName(for: id))
                        Text(id).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    removeButton { remove(id) }
                }
            }
            HStack {
                TextField("Bundle identifier", text: newValue)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        let v = newValue.wrappedValue.trimmingCharacters(in: .whitespaces)
                        guard !v.isEmpty else { return }
                        add(v)
                        newValue.wrappedValue = ""
                    }
                Button("Add") {
                    let v = newValue.wrappedValue.trimmingCharacters(in: .whitespaces)
                    guard !v.isEmpty else { return }
                    add(v)
                    newValue.wrappedValue = ""
                }
                .disabled(newValue.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
                Menu("Add running app…") {
                    let apps = RunningApps.candidates(excluding: items)
                    if apps.isEmpty {
                        Text("No other apps running")
                    }
                    ForEach(apps, id: \.bundleID) { app in
                        Button(app.name) { add(app.bundleID) }
                    }
                }
                .fixedSize()
            }
        }
    }

    private func removeButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "minus.circle.fill")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Remove")
    }
}

/// Running apps offered by "Add running app…": everything with a bundle id
/// that is not Apple's own.
@MainActor
enum RunningApps {
    struct Entry: Hashable {
        let bundleID: String
        let name: String
    }

    static func candidates(excluding: [String]) -> [Entry] {
        let me = Bundle.main.bundleIdentifier
        var seen = Set<String>()
        var out: [Entry] = []
        for app in NSWorkspace.shared.runningApplications {
            guard let id = app.bundleIdentifier, !id.hasPrefix("com.apple."), id != me,
                  app.activationPolicy != .prohibited,
                  !excluding.contains(id), !seen.contains(id) else { continue }
            seen.insert(id)
            out.append(Entry(bundleID: id, name: app.localizedName ?? id))
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Name of a running app for a bundle id, or the last path component.
    static func displayName(for bundleID: String) -> String {
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }),
           let name = app.localizedName {
            return name
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return url.deletingPathExtension().lastPathComponent
        }
        return bundleID.split(separator: ".").last.map(String.init) ?? bundleID
    }
}

/// Persist before publishing settings so failed writes never change live behavior.
@MainActor
@Observable
final class SettingsEditor {
    private let manager: SessionManager
    @ObservationIgnored private let reevaluateFloors: () -> Void
    private(set) var error: String?

    init(manager: SessionManager, reevaluateFloors: (() -> Void)? = nil) {
        self.manager = manager
        self.reevaluateFloors = reevaluateFloors ?? { manager.services?.reevaluateFloors() }
    }

    @discardableResult
    func save(_ proposed: Config) -> Bool {
        let previous = manager.config
        var next = proposed
        next.floorCorrectionNotice = nil
        do {
            try manager.store.saveConfig(next)
            manager.config = next
            error = nil
            if previous.lowPowerFloor != next.lowPowerFloor || previous.endFloor != next.endFloor || previous.thermalRules != next.thermalRules {
                reevaluateFloors()
            }
            if previous.browserThrottleEnabled != next.browserThrottleEnabled {
                manager.services?.refreshBrowserConfiguration()
            }
            return true
        } catch {
            self.error = "Settings were not saved: \(error.localizedDescription)"
            return false
        }
    }
}
