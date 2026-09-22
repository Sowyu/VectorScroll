import Foundation
import CryptoKit
import Darwin

private final class ResponseBody: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func set(_ data: Data) {
        lock.withLock { self.data = data }
    }

    func snapshot() -> Data {
        lock.withLock { data }
    }
}

private final class FixtureURLProtocol: URLProtocol, @unchecked Sendable {
    static let response = ResponseBody()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let data = Self.response.snapshot()
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@main
struct CheckInstaller {
    static func rejects(_ action: () throws -> Void) {
        do { try action(); fatalError("Expected installation to be rejected") } catch { }
    }

    static func makeIdentity(_ name: String, at root: URL, keychain: URL) throws {
        let folder = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let configuration = folder.appendingPathComponent("openssl.cnf")
        try """
        [req]
        distinguished_name = subject
        x509_extensions = codesign
        prompt = no
        [subject]
        CN = \(name)
        [codesign]
        basicConstraints = critical,CA:TRUE
        keyUsage = critical,digitalSignature,keyCertSign
        extendedKeyUsage = critical,codeSigning
        subjectKeyIdentifier = hash
        authorityKeyIdentifier = keyid:always
        """.write(to: configuration, atomically: false, encoding: .utf8)
        let key = folder.appendingPathComponent("key.pem")
        let certificate = folder.appendingPathComponent("certificate.pem")
        let archive = folder.appendingPathComponent("identity.p12")
        try UpdateInstaller.run("/usr/bin/openssl", ["req", "-new", "-newkey", "rsa:2048", "-nodes", "-x509",
                                                       "-days", "1", "-config", configuration.path,
                                                       "-keyout", key.path, "-out", certificate.path])
        try UpdateInstaller.run("/usr/bin/openssl", ["pkcs12", "-export", "-inkey", key.path, "-in", certificate.path,
                                                       "-out", archive.path, "-passout", "pass:test"])
        try UpdateInstaller.run("/usr/bin/security", ["import", archive.path, "-k", keychain.path, "-P", "test",
                                                        "-T", "/usr/bin/codesign"])
    }

    static func sign(_ app: URL, as identity: String, keychain: URL) throws {
        try UpdateInstaller.run("/usr/bin/codesign", ["--force", "--deep", "--sign", identity,
                                                       "--keychain", keychain.path, app.path])
    }

    static func atomicSwap(_ first: URL, _ second: URL) throws {
        let result = first.path.withCString { firstPath in
            second.path.withCString { secondPath in
                renameatx_np(AT_FDCWD, firstPath, AT_FDCWD, secondPath, UInt32(RENAME_SWAP))
            }
        }
        guard result == 0 else { throw UpdateInstaller.Failure(message: "Test atomic swap failed") }
    }

    static func runReplacementBoundaryChild() throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 5 else { throw UpdateInstaller.Failure(message: "Invalid boundary test arguments") }
        let plan = URL(fileURLWithPath: arguments[2])
        let boundary = arguments[3]
        let signal = URL(fileURLWithPath: arguments[4])
        let pause: () throws -> Void = {
            try Data(boundary.utf8).write(to: signal, options: .withoutOverwriting)
            Thread.sleep(forTimeInterval: 30)
            throw UpdateInstaller.Failure(message: "Boundary test was not stopped")
        }
        if boundary == "before-swap" {
            try UpdateInstaller.replace(plan, swap: { _, _ in try pause() },
                                        launch: { _, _ in fatalError("Boundary test must not launch") })
        } else if boundary == "after-swap" {
            try UpdateInstaller.replace(plan, move: { _, _ in try pause() },
                                        launch: { _, _ in fatalError("Boundary test must not launch") })
        } else {
            throw UpdateInstaller.Failure(message: "Unknown boundary test")
        }
    }

    static func stopAtBoundary(_ boundary: String, plan: URL, signal: URL) throws {
        let process = Process()
        let executablePath = CommandLine.arguments[0].hasPrefix("/")
            ? CommandLine.arguments[0]
            : FileManager.default.currentDirectoryPath + "/" + CommandLine.arguments[0]
        process.executableURL = URL(fileURLWithPath: executablePath).standardizedFileURL
        process.arguments = ["--replacement-boundary", plan.path, boundary, signal.path]
        try process.run()
        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: signal.path) && Date() < deadline {
            guard process.isRunning else { throw UpdateInstaller.Failure(message: "Boundary child exited early") }
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard FileManager.default.fileExists(atPath: signal.path) else {
            if process.isRunning { process.terminate() }
            throw UpdateInstaller.Failure(message: "Boundary child did not reach \(boundary)")
        }
        _ = kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
        guard process.terminationReason == .uncaughtSignal else {
            throw UpdateInstaller.Failure(message: "Boundary child was not stopped by signal")
        }
    }

    static func main() async throws {
        if CommandLine.arguments.dropFirst().first == "--replacement-boundary" {
            try runReplacementBoundaryChild()
            return
        }
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("VectorScroll install test's \(UUID().uuidString)")
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        let keychain = root.appendingPathComponent("test-signing.keychain-db")
        try UpdateInstaller.run("/usr/bin/security", ["create-keychain", "-p", "test", keychain.path])
        try UpdateInstaller.run("/usr/bin/security", ["unlock-keychain", "-p", "test", keychain.path])
        let releaseIdentity = "VectorScroll Release Test \(UUID().uuidString)"
        let foreignIdentity = "VectorScroll Foreign Test \(UUID().uuidString)"
        try makeIdentity(releaseIdentity, at: root, keychain: keychain)
        try makeIdentity(foreignIdentity, at: root, keychain: keychain)
        try UpdateInstaller.run("/usr/bin/security", ["set-key-partition-list", "-S", "apple-tool:,apple:",
                                                        "-s", "-k", "test", keychain.path])
        let sourceFolder = root.appendingPathComponent("image")
        let source = sourceFolder.appendingPathComponent("VectorScroll.app")
        let binaries = source.appendingPathComponent("Contents/MacOS")
        try files.createDirectory(at: binaries, withIntermediateDirectories: true)
        let stub = root.appendingPathComponent("Fixture.swift")
        try """
        import Foundation
        if CommandLine.arguments.count > 1, !CommandLine.arguments[1].hasPrefix("--") {
            try Data("launched".utf8).write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        }
        if let index = CommandLine.arguments.firstIndex(of: "--vector-scroll-update-health"),
           CommandLine.arguments.indices.contains(index + 2) {
            struct Plan: Decodable { let healthToken: String }
            let planURL = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            let attempt = CommandLine.arguments[index + 2]
            let plan = try JSONDecoder().decode(Plan.self, from: Data(contentsOf: planURL))
            try Data(plan.healthToken.utf8).write(to: planURL.deletingLastPathComponent().appendingPathComponent("healthy-" + attempt),
                                                  options: .withoutOverwriting)
            Thread.sleep(forTimeInterval: 5)
        }
        """.write(to: stub, atomically: false, encoding: .utf8)
        try UpdateInstaller.run("/usr/bin/xcrun", ["swiftc", stub.path, "-o", binaries.appendingPathComponent("VectorScroll").path])
        var info: [String: Any] = ["CFBundleIdentifier": "local.vectorscroll.app", "CFBundleExecutable": "VectorScroll",
                                  "CFBundleName": "VectorScroll", "CFBundlePackageType": "APPL", "LSUIElement": true,
                                  "CFBundleShortVersionString": "2.0.0", "CFBundleVersion": "200", "LSMinimumSystemVersion": "14.0"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: source.appendingPathComponent("Contents/Info.plist"))
        try sign(source, as: releaseIdentity, keychain: keychain)
        let foreign = root.appendingPathComponent("Foreign.app")
        try files.copyItem(at: source, to: foreign)
        try sign(foreign, as: foreignIdentity, keychain: keychain)
        let adHoc = root.appendingPathComponent("AdHoc.app")
        try files.copyItem(at: source, to: adHoc)
        try UpdateInstaller.run("/usr/bin/codesign", ["--force", "--deep", "--sign", "-", adHoc.path])
        let incompatible = root.appendingPathComponent("Incompatible.app")
        try files.copyItem(at: source, to: incompatible)
        var incompatibleInfo = info
        incompatibleInfo["LSMinimumSystemVersion"] = "99.0"
        try PropertyListSerialization.data(fromPropertyList: incompatibleInfo, format: .xml, options: 0)
            .write(to: incompatible.appendingPathComponent("Contents/Info.plist"))
        try sign(incompatible, as: releaseIdentity, keychain: keychain)
        let destination = root.appendingPathComponent("Installed App's Folder/VectorScroll.app")
        try files.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try files.copyItem(at: source, to: destination)
        info["CFBundleShortVersionString"] = "1.0.0"
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: destination.appendingPathComponent("Contents/Info.plist"))
        try sign(destination, as: releaseIdentity, keychain: keychain)
        let imageURL = root.appendingPathComponent("Update.dmg")
        try UpdateInstaller.run("/usr/bin/hdiutil", ["create", "-volname", "VectorScrollTest", "-srcfolder", sourceFolder.path,
                                                    "-format", "UDZO", imageURL.path])
        let image = try Data(contentsOf: imageURL)
        let digest = SHA256.hash(data: image).map { String(format: "%02x", $0) }.joined()
        let update = AppUpdate(version: "2.0.0", downloadURL: URL(string: "https://github.com/Sowyu/VectorScroll/releases/download/2.0.0/VectorScroll.dmg")!,
                               sha256: digest, downloadSize: image.count)
        let helper = URL(fileURLWithPath: "dist/VectorScroll.app/Contents/MacOS/VectorScroll")
        rejects {
            _ = try UpdateInstaller.prepare(update, image: image + Data([0]), destination: destination,
                                            helperSource: helper, parentPID: getpid())
        }
        rejects { try UpdateInstaller.validateCandidate(source, version: "9.0.0", matching: destination) }
        rejects { try UpdateInstaller.validateCandidate(foreign, version: "2.0.0", matching: destination) }
        rejects { try UpdateInstaller.validateCandidate(adHoc, version: "2.0.0", matching: destination) }
        rejects { try UpdateInstaller.validateCandidate(incompatible, version: "2.0.0", matching: destination) }

        let oversizedConfiguration = URLSessionConfiguration.ephemeral
        oversizedConfiguration.protocolClasses = [FixtureURLProtocol.self]
        FixtureURLProtocol.response.set(Data([1, 2, 3, 4]))
        let oversizedUpdate = AppUpdate(version: "2.0.0", downloadURL: URL(string: "https://example.test/update")!,
                                        sha256: String(repeating: "0", count: 64), downloadSize: 3)
        do {
            _ = try await UpdateInstaller.download(oversizedUpdate, session: URLSession(configuration: oversizedConfiguration))
            fatalError("Expected oversized download to be rejected")
        } catch { }

        let plan = try UpdateInstaller.prepare(update, image: image, destination: destination,
                                              helperSource: helper, parentPID: getpid())
        rejects {
            try UpdateInstaller.replace(plan, swap: { _, _ in
                throw UpdateInstaller.Failure(message: "Simulated atomic swap failure")
            }, launch: { _, _ in fatalError("Must not launch a failed replacement") })
        }
        let versionAfterSwapFailure = try UpdateInstaller.appVersion(destination)
        assert(versionAfterSwapFailure == "1.0.0")
        rejects {
            try UpdateInstaller.replace(plan, launch: { _, _ in throw UpdateInstaller.Failure(message: "Simulated launch failure") })
        }
        let versionAfterLaunchFailure = try UpdateInstaller.appVersion(destination)
        assert(versionAfterLaunchFailure == "1.0.0")

        var stalled: Process?
        rejects {
            try UpdateInstaller.replace(plan, launch: { _, _ in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/sleep")
                process.arguments = ["30"]
                try process.run()
                stalled = process
                return process
            }, healthTimeout: 0.2)
        }
        guard let stalled else { fatalError("Health timeout must launch the fixture process") }
        stalled.waitUntilExit()
        assert(stalled.terminationStatus != 0)
        let versionAfterHealthFailure = try UpdateInstaller.appVersion(destination)
        assert(versionAfterHealthFailure == "1.0.0")

        let staged = plan.deletingLastPathComponent().appendingPathComponent("VectorScroll.app")
        let beforeSwapSignal = root.appendingPathComponent("before swap reached")
        try stopAtBoundary("before-swap", plan: plan, signal: beforeSwapSignal)
        let oldBeforeSwap = try UpdateInstaller.appVersion(destination)
        let updateBeforeSwap = try UpdateInstaller.appVersion(staged)
        assert(oldBeforeSwap == "1.0.0" && updateBeforeSwap == "2.0.0")

        let afterSwapSignal = root.appendingPathComponent("after swap reached")
        try stopAtBoundary("after-swap", plan: plan, signal: afterSwapSignal)
        let updateAfterSwap = try UpdateInstaller.appVersion(destination)
        let oldAfterSwap = try UpdateInstaller.appVersion(staged)
        assert(updateAfterSwap == "2.0.0" && oldAfterSwap == "1.0.0")
        try atomicSwap(destination, staged)
        let restoredAfterKill = try UpdateInstaller.appVersion(destination)
        assert(restoredAfterKill == "1.0.0")

        info["CFBundleShortVersionString"] = "2.0.0"
        info["NSHumanReadableCopyright"] = "Modified after signing"
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: staged.appendingPathComponent("Contents/Info.plist"))
        rejects { try UpdateInstaller.validateCandidate(staged, version: "2.0.0", matching: destination) }
        print("PASS: size cap, checksum, signer, OS, tampering, atomic swap, abrupt-stop, launch, and health rollback checks")

        // Run the shipped executable's helper against an inert signed fixture app.
        // The fixture writes a marker on launch instead of requesting input access.
        let parent = Process()
        parent.executableURL = URL(fileURLWithPath: "/bin/sleep")
        parent.arguments = ["30"]
        try parent.run()
        let helperPlan = try UpdateInstaller.prepare(update, image: image, destination: destination,
                                                    helperSource: helper, parentPID: parent.processIdentifier)
        let marker = root.appendingPathComponent("relaunch marker")
        var launchPlan = try UpdateInstaller.readPlan(helperPlan)
        launchPlan.relaunchArguments = [marker.path]
        try JSONEncoder().encode(launchPlan).write(to: helperPlan)
        try UpdateInstaller.launchHelper(helperPlan)
        let beforeExit = try UpdateInstaller.appVersion(destination)
        assert(beforeExit == "1.0.0" && parent.isRunning)
        parent.terminate()
        parent.waitUntilExit()
        let result = helperPlan.deletingLastPathComponent().appendingPathComponent("result")
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline && (!files.fileExists(atPath: marker.path) || !files.fileExists(atPath: result.path)) {
            try await Task.sleep(for: .milliseconds(100))
        }
        assert(files.fileExists(atPath: marker.path), "New app must relaunch: \(UserDefaults(suiteName: "local.vectorscroll.app")!.string(forKey: "updateInstallError") ?? "no helper error")")
        let status = try String(contentsOf: result, encoding: .utf8)
        let installed = try UpdateInstaller.appVersion(destination)
        let backup = try UpdateInstaller.appVersion(helperPlan.deletingLastPathComponent().appendingPathComponent("Previous.app"))
        assert(status == "success" && installed == "2.0.0" && backup == "1.0.0")
        print("PASS: production helper waits for exit, installs, relaunches, preserves backup, and handles spaces/apostrophes in paths")

        let configuration = URLSessionConfiguration.ephemeral
        if let token = ProcessInfo.processInfo.environment["GH_UPDATE_TEST_TOKEN"] {
            configuration.httpAdditionalHeaders = ["Authorization": "Bearer \(token)"]
        }
        let session = URLSession(configuration: configuration)
        guard let live = try await AppUpdate.check(installedVersion: "0.0.0", session: session) else { fatalError("Missing live release") }
        let downloaded = try await UpdateInstaller.download(live)
        let actualHash = SHA256.hash(data: downloaded).map { String(format: "%02x", $0) }.joined()
        assert(actualHash == live.sha256)
        print("PASS: live GitHub DMG download matches the release checksum")
    }
}
