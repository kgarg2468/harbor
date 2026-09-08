import Foundation

/// Spec section 4, Docker rule: if Docker Desktop is running and has no
/// running containers, it is frozen like any other app (bypassing its
/// denylist entry). Any error means Docker is left alone.
///
/// The rule only *decides*; `LidActions` journals `dockerFrozen` and the
/// pids before the group is actually stopped.
struct DockerRule: Sendable {
    static let bundleId = FreezePlanner.dockerBundleId
    static let timeout: TimeInterval = 5

    static let dockerCandidates: [String] = [
        "/usr/local/bin/docker",
        "/opt/homebrew/bin/docker",
        "\(NSHomeDirectory())/.docker/bin/docker",
        "/Applications/Docker.app/Contents/Resources/bin/docker",
    ]

    /// Runs `docker ps -q` and returns true only on a clean, empty answer.
    typealias ContainerProbe = @Sendable () async throws -> Bool

    let freezer: any Freezing
    let probe: ContainerProbe

    init(freezer: any Freezing, probe: ContainerProbe? = nil) {
        self.freezer = freezer
        self.probe = probe ?? DockerRule.liveProbe
    }

    /// The Docker Desktop process tree if it is running *and* idle, else nil.
    func idleDockerGroup(config: Config) async -> FreezeGroup? {
        guard config.dockerRule else { return nil }
        let groups = freezer.plan(bundleIds: [Self.bundleId], config: config, applyDenylist: false)
        guard let docker = groups.first else { return nil }
        do {
            let idle = try await probe()
            guard idle else {
                Log.info("docker rule: containers running, Docker left alone")
                return nil
            }
            return docker
        } catch {
            Log.error("docker rule: probe failed, Docker left alone: \(error.localizedDescription)")
            return nil
        }
    }

    typealias Runner = @Sendable (String, [String]) async throws -> ShellResult

    static func probeDesktop(docker: String, home: String,
                             socketAvailable: @Sendable () -> Bool,
                             run: Runner) async throws -> Bool {
        guard socketAvailable() else {
            throw ShellError.launchFailed(exe: docker, underlying: "local Docker Desktop socket unavailable")
        }
        // Ignore DOCKER_CONTEXT, DOCKER_HOST, TLS and config environment overrides.
        // An explicit host also overrides the active context in ~/.docker/config.json.
        let socket = "unix://" + home + "/.docker/run/docker.sock"
        let r = try await run("/usr/bin/env", ["-i", "HOME=" + home, docker, "--host", socket, "ps", "-q"])
        guard r.succeeded else {
            throw SleepGuardError(command: "docker ps -q", status: r.status, stderr: r.stderr)
        }
        return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Only the per-user Docker Desktop socket is eligible; no context fallback.
    static let liveProbe: ContainerProbe = {
        guard let docker = Shell.locate(dockerCandidates) else {
            throw ShellError.launchFailed(exe: "docker", underlying: "not found in \(dockerCandidates.joined(separator: ", "))")
        }
        let home = NSHomeDirectory()
        return try await probeDesktop(docker: docker, home: home, socketAvailable: {
            let attributes = try? FileManager.default.attributesOfItem(atPath: home + "/.docker/run/docker.sock")
            return attributes?[.type] as? FileAttributeType == .typeSocket
        }, run: { try await Shell.run($0, $1, timeout: timeout) })
    }
}
