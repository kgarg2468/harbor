import AppKit
import SwiftUI

/// Menu bar app. The status item is an `NSStatusItem` hosting SwiftUI, and
/// the settings window is an `NSWindow` this app opens itself (see
/// `SettingsWindow`), so there is no SwiftUI scene with any content in it.
/// `App` still requires one, hence the empty `Settings`.
@main
enum InsomniaEntryPoint {
    @MainActor
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == "--recover-owned" {
            exit(RecoveryCommand.run(arguments: arguments))
        }
        if arguments == ["--maintenance-protocol"] {
            print(RecoveryCommand.protocolVersion)
            exit(0)
        }
        if arguments.first == "--validate-recovery-state", arguments.count == 2, arguments[1].hasPrefix("/") {
            exit(RecoveryCommand.validate(stateFile: URL(fileURLWithPath: arguments[1])) ? 0 : 1)
        }
        if arguments.first == "--maintenance-uninstall" {
            exit(MaintenanceCommand.run(arguments: arguments))
        }
        guard arguments.isEmpty || arguments.allSatisfy({ $0.hasPrefix("-psn_") }) else {
            FileHandle.standardError.write(Data("Unknown Insomnia command; no GUI or maintenance action started.\n".utf8))
            exit(2)
        }
        InsomniaApp.main()
    }
}

struct InsomniaApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let manager: SessionManager
    let status: any StatusSource
    let secrets: any HotspotSecretStore
    let locationPermission: LocationPermission
    private var statusItem: StatusItemController?
    private var settingsWindow: SettingsWindow?
    private var terminating = false

    override init() {
        let paths = Paths.fromEnvironment()
        do {
            try AppInstanceLease.acquireForProcess(paths: paths)
        } catch {
            let message = "Insomnia could not launch: \(error.localizedDescription)"
            Log.error(message)
            FileHandle.standardError.write(Data((message + "\n").utf8))
            // Do not keep a refused launch alive in a modal alert: an installer
            // may already be waiting for every Insomnia PID to disappear.
            exit(EXIT_FAILURE)
        }
        let manager = SessionManager.live(paths: paths)
        self.manager = manager
        secrets = KeychainHotspotSecretStore(keychain: KeychainStore()) {
            manager.config.hotspotSSID
        }
        if let services = manager.services {
            status = LiveStatusSource(services: services)
            locationPermission = services.locationPermission
        } else {
            Log.error("live SessionManager has no AppServices; using placeholder status")
            status = PlaceholderStatus()
            locationPermission = LocationPermission()
        }
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // No Dock icon even when run from `swift run` (the bundle has LSUIElement).
        NSApp.setActivationPolicy(.accessory)
        Log.info("launched")
        let settings = SettingsWindow { [manager, secrets, locationPermission] in
            AnyView(
                SettingsView(
                    manager: manager,
                    secrets: secrets,
                    locationPermission: locationPermission
                )
            )
        }
        settingsWindow = settings
        statusItem = StatusItemController(manager: manager, status: status) { [weak settings] in
            settings?.show()
        }
        Task { await manager.reconcile() }
    }

    /// Quitting always ends the session (spec 1). Terminate is deferred until
    /// sleep has been restored.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateCancel }
        terminating = true
        Task {
            let restored = await manager.prepareToQuit()
            if !restored { terminating = false }
            sender.reply(toApplicationShouldTerminate: restored)
        }
        return .terminateLater
    }
}
