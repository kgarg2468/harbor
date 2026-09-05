import XCTest
@testable import Insomnia

final class DockerRuleTests: XCTestCase {
    func testProbePinsDesktopSocketAndDiscardsInheritedDockerEnvironment() async throws {
        let arguments = Locked<[String]>([])
        let executable = Locked("")
        let idle = try await DockerRule.probeDesktop(docker: "/fixture/docker", home: "/Users/Fixture User",
            socketAvailable: { true }, run: { exe, args in
                executable.value = exe
                arguments.value = args
                return ShellResult(status: 0, stdout: "", stderr: "")
            })
        XCTAssertTrue(idle)
        XCTAssertEqual(executable.value, "/usr/bin/env")
        XCTAssertEqual(arguments.value, ["-i", "HOME=/Users/Fixture User", "/fixture/docker",
            "--host", "unix:///Users/Fixture User/.docker/run/docker.sock", "ps", "-q"])
    }

    func testMissingDesktopSocketNeverRunsProbe() async {
        let calls = Locked(0)
        do {
            _ = try await DockerRule.probeDesktop(docker: "/fixture/docker", home: "/fixture",
                socketAvailable: { false }, run: { _, _ in
                    calls.value += 1
                    return ShellResult(status: 0, stdout: "", stderr: "")
                })
            XCTFail("missing Desktop socket must fail closed")
        } catch {}
        XCTAssertEqual(calls.value, 0)
    }

    func testBusyOrFailedDesktopIsNotIdle() async throws {
        let idle = try await DockerRule.probeDesktop(docker: "/fixture/docker", home: "/fixture",
            socketAvailable: { true }, run: { _, _ in ShellResult(status: 0, stdout: "container-id\n", stderr: "") })
        XCTAssertFalse(idle)
        do {
            _ = try await DockerRule.probeDesktop(docker: "/fixture/docker", home: "/fixture",
                socketAvailable: { true }, run: { _, _ in ShellResult(status: 1, stdout: "", stderr: "unavailable") })
            XCTFail("failed probe must fail closed")
        } catch {}
    }
}

extension DockerRuleTests {
    func testEnvironmentOverridesCannotReachProbeProcess() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("docker-fixture")
        try """
        #!/bin/sh
        if [ -n "${DOCKER_HOST-}${DOCKER_CONTEXT-}${DOCKER_CONFIG-}${DOCKER_TLS-}${DOCKER_TLS_VERIFY-}" ]; then
            exit 9
        fi
        [ "$1" = --host ] && [ "$2" = "unix://$HOME/.docker/run/docker.sock" ] || exit 8
        printf 'local-busy-container\\n'
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let idle = try await DockerRule.probeDesktop(docker: executable.path, home: root.path,
            socketAvailable: { true }, run: { exe, args in
                try await Shell.run("/usr/bin/env", ["DOCKER_HOST=tcp://remote.invalid:2375",
                    "DOCKER_CONTEXT=alternate", "DOCKER_CONFIG=/alternate", "DOCKER_TLS=1",
                    "DOCKER_TLS_VERIFY=1", exe] + args, timeout: 5)
            })
        XCTAssertFalse(idle)
    }
}
