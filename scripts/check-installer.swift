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
    static func expect(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String = "Fixture assertion failed") throws {
        guard condition() else { throw UpdateInstaller.Failure(message: message()) }
    }

    static func rejects(_ action: () throws -> Void) throws {
        do { try action() } catch { return }
        throw UpdateInstaller.Failure(message: "Expected installation to be rejected")
    }

    static func phase(_ message: String) {
        FileHandle.standardOutput.write(Data("FIXTURE: \(message)\n".utf8))
    }

    static func runFixture(_ label: String, _ executable: String, _ arguments: [String],
                           timeout: TimeInterval = 20, output: Any = FileHandle.nullDevice) throws {
        phase(label)
        let process = Process()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning {
            process.terminate()
            let stopDeadline = Date().addingTimeInterval(1)
            while process.isRunning && Date() < stopDeadline { Thread.sleep(forTimeInterval: 0.05) }
            if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            throw UpdateInstaller.Failure(message: "Fixture command timed out during \(label)")
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let details = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "unknown error"
            throw UpdateInstaller.Failure(message: "Fixture command failed during \(label): \(details)")
        }
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
        try runFixture("generate \(name)", "/usr/bin/openssl",
                       ["req", "-new", "-newkey", "rsa:2048", "-nodes", "-x509", "-days", "1",
                        "-config", configuration.path, "-keyout", key.path, "-out", certificate.path])
        try runFixture("package \(name)", "/usr/bin/openssl",
                       ["pkcs12", "-export", "-inkey", key.path, "-in", certificate.path,
                        "-out", archive.path, "-passout", "pass:test"])
        try runFixture("import \(name)", "/usr/bin/security",
                       ["import", archive.path, "-k", keychain.path, "-P", "test",
                        "-T", "/usr/bin/codesign", "-T", "/usr/bin/security"])
        try runFixture("export \(name) certificate", "/usr/bin/openssl",
                       ["x509", "-in", certificate.path, "-outform", "DER",
                        "-out", folder.appendingPathComponent("certificate.der").path])
        try runFixture("trust \(name)", "/usr/bin/sudo",
                       ["-n", "/usr/bin/security", "add-trusted-cert", "-d", "-r", "trustRoot",
                        "-p", "codeSign", "-k", "/Library/Keychains/System.keychain", certificate.path])
    }

    static func sign(_ app: URL, as identity: String, keychain: URL) throws {
        try runFixture("sign \(app.lastPathComponent) as \(identity)", "/usr/bin/codesign",
                       ["--force", "--deep", "--sign", identity, "--keychain", keychain.path, app.path])
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
                                        launch: { _, _ in throw UpdateInstaller.Failure(message: "Boundary test must not launch") })
        } else if boundary == "after-swap" {
            try UpdateInstaller.replace(plan, move: { _, _ in try pause() },
                                        launch: { _, _ in throw UpdateInstaller.Failure(message: "Boundary test must not launch") })
        } else if boundary == "after-backup" || boundary == "after-health" {
            try UpdateInstaller.replace(plan, launch: { _, arguments in
                if boundary == "after-health" {
                    _ = try UpdateInstaller.acknowledgeLaunch(arguments: arguments,
                        bundleURL: URL(fileURLWithPath: try UpdateInstaller.readPlan(plan).destination))
                }
                try pause()
                throw UpdateInstaller.Failure(message: "Boundary test must be stopped")
            })
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

    static func checkStaleUpdateFolders() throws {
        let files = FileManager.default
        let fixtureRoot = files.temporaryDirectory.appendingPathComponent("VectorScroll cleanup test \(UUID().uuidString)")
        let root = fixtureRoot.appendingPathComponent(".VectorScroll-updates")
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: fixtureRoot) }

        func folder(_ name: String, plan: Bool = true) throws -> URL {
            let url = root.appendingPathComponent(name)
            try files.createDirectory(at: url, withIntermediateDirectories: false)
            if plan { try Data("{}".utf8).write(to: url.appendingPathComponent("plan.json")) }
            try Data().write(to: url.appendingPathComponent("transaction.lock"))
            try files.setAttributes([.modificationDate: Date().addingTimeInterval(-172800)], ofItemAtPath: url.path)
            return url
        }

        var stale = try (0..<3).map { _ in try folder(".VectorScroll-update-\(UUID().uuidString)") }
        let current = try folder(".VectorScroll-update-\(UUID().uuidString)")
        stale.append(try folder(".VectorScroll-update-\(UUID().uuidString)", plan: false))
        let recent = try folder(".VectorScroll-update-\(UUID().uuidString)", plan: false)
        try files.setAttributes([.modificationDate: Date()], ofItemAtPath: recent.path)
        let pending = try folder(".VectorScroll-update-\(UUID().uuidString)")
        try Data("{}".utf8).write(to: pending.appendingPathComponent("transaction.json"))
        try files.setAttributes([.modificationDate: Date().addingTimeInterval(-172800)], ofItemAtPath: pending.path)
        _ = try folder(".VectorScroll-update-not-a-uuid")
        try files.createSymbolicLink(at: root.appendingPathComponent(".VectorScroll-update-\(UUID().uuidString)"),
                                     withDestinationURL: stale[0])
        try Data().write(to: root.appendingPathComponent(".VectorScroll-update-\(UUID().uuidString)"))
        _ = try folder("Foo.app")

        let expected = Set(stale.map { $0.standardizedFileURL })
        var selected: [URL] = []
        let count = UpdateInstaller.trashStaleUpdateFolders(keeping: current.appendingPathComponent("."), in: root) {
            selected.append($0.standardizedFileURL)
        }
        try expect(count == 4 && selected.count == 4 && Set(selected) == expected)

        var attempted: [URL] = []
        let partialCount = UpdateInstaller.trashStaleUpdateFolders(keeping: current, in: root) {
            attempted.append($0.standardizedFileURL)
            if attempted.count == 1 { throw UpdateInstaller.Failure(message: "Simulated Trash failure") }
        }
        try expect(partialCount == 3 && attempted.count == 4 && Set(attempted) == expected)
        let missingCount = UpdateInstaller.trashStaleUpdateFolders(keeping: current, in: root.appendingPathComponent("missing")) {
            _ in throw UpdateInstaller.Failure(message: "Must not trash anything when the directory cannot be listed")
        }
        try expect(missingCount == 0)
        print("PASS: stale cleanup includes old incomplete folders, keeps current/recent/pending folders, skips symlinks, and continues after Trash errors")
    }

    static func main() async throws {
        if CommandLine.arguments.dropFirst().first == "--replacement-boundary" {
            try runReplacementBoundaryChild()
            return
        }
        try checkStaleUpdateFolders()
        if CommandLine.arguments.dropFirst().first == "--cleanup-only" { return }
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("VectorScroll install test's \(UUID().uuidString)")
        let keychain = root.appendingPathComponent("test-signing.keychain-db")
        let releaseIdentity = "VectorScroll Release Test \(UUID().uuidString)"
        let foreignIdentity = "VectorScroll Foreign Test \(UUID().uuidString)"
        var previousKeychains: [String]?
        // Register before creating keys, changing search lists, or trusting certificates.
        defer {
            for identity in [releaseIdentity, foreignIdentity] {
                let folder = root.appendingPathComponent(identity)
                let certificate = folder.appendingPathComponent("certificate.pem")
                guard let der = try? Data(contentsOf: folder.appendingPathComponent("certificate.der")) else { continue }
                do {
                    try runFixture("remove \(identity) trust", "/usr/bin/sudo",
                                   ["-n", "/usr/bin/security", "remove-trusted-cert", "-d", certificate.path])
                } catch { FileHandle.standardError.write(Data("Cleanup: \(error)\n".utf8)) }
                let fingerprint = Insecure.SHA1.hash(data: der).map { String(format: "%02x", $0) }.joined()
                do {
                    try runFixture("delete \(identity) System certificate", "/usr/bin/sudo",
                                   ["-n", "/usr/bin/security", "delete-certificate", "-Z", fingerprint,
                                    "/Library/Keychains/System.keychain"])
                } catch { FileHandle.standardError.write(Data("Cleanup: \(error)\n".utf8)) }
            }
            if let previousKeychains {
                do {
                    try runFixture("restore keychain search list", "/usr/bin/security",
                                   ["list-keychains", "-d", "user", "-s"] + previousKeychains)
                } catch { FileHandle.standardError.write(Data("Cleanup: \(error)\n".utf8)) }
            }
            if files.fileExists(atPath: keychain.path) {
                do {
                    try runFixture("delete fixture keychain", "/usr/bin/security", ["delete-keychain", keychain.path])
                } catch { FileHandle.standardError.write(Data("Cleanup: \(error)\n".utf8)) }
            }
            do { try files.removeItem(at: root) }
            catch { FileHandle.standardError.write(Data("Cleanup: \(error)\n".utf8)) }
        }
        try files.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let searchList = Pipe()
        try runFixture("read keychain search list", "/usr/bin/security", ["list-keychains", "-d", "user"], output: searchList)
        let savedKeychains = String(data: searchList.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)!
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
        previousKeychains = savedKeychains
        try runFixture("create fixture keychain", "/usr/bin/security",
                       ["create-keychain", "-p", "test", keychain.path])
        try runFixture("unlock fixture keychain", "/usr/bin/security",
                       ["unlock-keychain", "-p", "test", keychain.path])
        try runFixture("add fixture keychain to search list", "/usr/bin/security",
                       ["list-keychains", "-d", "user", "-s", keychain.path] + savedKeychains)
        try makeIdentity(releaseIdentity, at: root, keychain: keychain)
        try makeIdentity(foreignIdentity, at: root, keychain: keychain)
        try runFixture("allow codesign key access", "/usr/bin/security",
                       ["set-key-partition-list", "-S", "apple-tool:,apple:", "-s", "-k", "test", keychain.path])
        try runFixture("list fixture signing identities", "/usr/bin/security",
                       ["find-identity", "-v", "-p", "codesigning", keychain.path], output: FileHandle.standardOutput)
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
        try runFixture("compile fixture app", "/usr/bin/xcrun",
                       ["swiftc", stub.path, "-o", binaries.appendingPathComponent("VectorScroll").path])
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
        try runFixture("ad-hoc sign rejection fixture", "/usr/bin/codesign",
                       ["--force", "--deep", "--sign", "-", adHoc.path])
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
        try runFixture("create fixture disk image", "/usr/bin/hdiutil",
                       ["create", "-volname", "VectorScrollTest", "-srcfolder", sourceFolder.path,
                        "-format", "UDZO", imageURL.path])
        let imageData = try Data(contentsOf: imageURL)
        let image = UpdateInstaller.Image(url: imageURL)
        let digest = SHA256.hash(data: imageData).map { String(format: "%02x", $0) }.joined()
        let update = AppUpdate(version: "2.0.0", downloadURL: URL(string: "https://github.com/Sowyu/VectorScroll/releases/download/2.0.0/VectorScroll.dmg")!,
                               sha256: digest, downloadSize: imageData.count)
        let helper = URL(fileURLWithPath: "dist/VectorScroll.app/Contents/MacOS/VectorScroll")
        let oversizedImageURL = root.appendingPathComponent("Oversized.dmg")
        try (imageData + Data([0])).write(to: oversizedImageURL)
        let oversizedImage = UpdateInstaller.Image(url: oversizedImageURL)
        try rejects {
            _ = try UpdateInstaller.prepare(update, image: oversizedImage, destination: destination,
                                            helperSource: helper, parentPID: getpid())
        }
        let wrongChecksum = AppUpdate(version: update.version, downloadURL: update.downloadURL,
                                      sha256: String(repeating: "0", count: 64), downloadSize: update.downloadSize)
        try rejects {
            _ = try UpdateInstaller.prepare(wrongChecksum, image: image, destination: destination,
                                            helperSource: helper, parentPID: getpid())
        }
        let failedPreparations = try files.contentsOfDirectory(
            atPath: destination.deletingLastPathComponent().appendingPathComponent(".VectorScroll-updates").path)
        try expect(failedPreparations.isEmpty, "Failed preparations must remove their work folders")
        try rejects { try UpdateInstaller.validateCandidate(source, version: "9.0.0", matching: destination) }
        try rejects { try UpdateInstaller.validateCandidate(foreign, version: "2.0.0", matching: destination) }
        try rejects { try UpdateInstaller.validateCandidate(adHoc, version: "2.0.0", matching: destination) }
        try rejects { try UpdateInstaller.validateCandidate(incompatible, version: "2.0.0", matching: destination) }

        let oversizedConfiguration = URLSessionConfiguration.ephemeral
        oversizedConfiguration.protocolClasses = [FixtureURLProtocol.self]
        FixtureURLProtocol.response.set(Data([1, 2, 3, 4]))
        let oversizedUpdate = AppUpdate(version: "2.0.0", downloadURL: URL(string: "https://example.test/update")!,
                                        sha256: String(repeating: "0", count: 64), downloadSize: 3)
        var rejectedOversizedDownload = false
        do {
            _ = try await UpdateInstaller.download(oversizedUpdate, session: URLSession(configuration: oversizedConfiguration))
        } catch { rejectedOversizedDownload = true }
        try expect(rejectedOversizedDownload, "Expected oversized download to be rejected")

        phase("exercise installer rejection and rollback paths")
        let plan = try UpdateInstaller.prepare(update, image: image, destination: destination,
                                              helperSource: helper, parentPID: getpid())
        try rejects {
            try UpdateInstaller.replace(plan, swap: { _, _ in
                throw UpdateInstaller.Failure(message: "Simulated atomic swap failure")
            }, launch: { _, _ in throw UpdateInstaller.Failure(message: "Must not launch a failed replacement") })
        }
        let versionAfterSwapFailure = try UpdateInstaller.appVersion(destination)
        try expect(versionAfterSwapFailure == "1.0.0")
        try rejects {
            try UpdateInstaller.replace(plan, launch: { _, _ in throw UpdateInstaller.Failure(message: "Simulated launch failure") })
        }
        let versionAfterLaunchFailure = try UpdateInstaller.appVersion(destination)
        try expect(versionAfterLaunchFailure == "1.0.0")

        var stalled: Process?
        try rejects {
            try UpdateInstaller.replace(plan, launch: { _, _ in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/sleep")
                process.arguments = ["30"]
                try process.run()
                stalled = process
                return process
            }, healthTimeout: 0.2)
        }
        guard let stalled else { throw UpdateInstaller.Failure(message: "Health timeout must launch the fixture process") }
        stalled.waitUntilExit()
        try expect(stalled.terminationStatus != 0)
        let versionAfterHealthFailure = try UpdateInstaller.appVersion(destination)
        try expect(versionAfterHealthFailure == "1.0.0")

        phase("exercise abrupt termination at replacement boundaries")
        let staged = plan.deletingLastPathComponent().appendingPathComponent("VectorScroll.app")
        let beforeSwapSignal = root.appendingPathComponent("before swap reached")
        try stopAtBoundary("before-swap", plan: plan, signal: beforeSwapSignal)
        let oldBeforeSwap = try UpdateInstaller.appVersion(destination)
        let updateBeforeSwap = try UpdateInstaller.appVersion(staged)
        try expect(oldBeforeSwap == "1.0.0" && updateBeforeSwap == "2.0.0")

        let recoveredBeforeSwap = try UpdateInstaller.recoverPendingUpdates(for: destination)
        try expect(!recoveredBeforeSwap)

        let afterSwapSignal = root.appendingPathComponent("after swap reached")
        try stopAtBoundary("after-swap", plan: plan, signal: afterSwapSignal)
        let updateAfterSwap = try UpdateInstaller.appVersion(destination)
        let oldAfterSwap = try UpdateInstaller.appVersion(staged)
        try expect(updateAfterSwap == "2.0.0" && oldAfterSwap == "1.0.0")
        let recovered = try UpdateInstaller.recoverPendingUpdates(for: destination)
        try expect(recovered)
        let restoredAfterKill = try UpdateInstaller.appVersion(destination)
        try expect(restoredAfterKill == "1.0.0")
        let recoveredAgain = try UpdateInstaller.recoverPendingUpdates(for: destination)
        try expect(!recoveredAgain)

        let afterBackupSignal = root.appendingPathComponent("after backup reached")
        try stopAtBoundary("after-backup", plan: plan, signal: afterBackupSignal)
        let recoveredBackup = try UpdateInstaller.recoverPendingUpdates(for: destination)
        try expect(recoveredBackup)
        let restoredBackup = try UpdateInstaller.appVersion(destination)
        try expect(restoredBackup == "1.0.0")

        let healthPlan = try UpdateInstaller.prepare(update, image: image, destination: destination,
                                                    helperSource: helper, parentPID: getpid())
        let afterHealthSignal = root.appendingPathComponent("after health reached")
        try stopAtBoundary("after-health", plan: healthPlan, signal: afterHealthSignal)
        let recoveredHealthy = try UpdateInstaller.recoverPendingUpdates(for: destination)
        try expect(!recoveredHealthy)
        let healthyVersion = try UpdateInstaller.appVersion(destination)
        let healthyBackup = healthPlan.deletingLastPathComponent().appendingPathComponent("Previous.app")
        try expect(healthyVersion == "2.0.0" && files.fileExists(atPath: healthyBackup.path))
        // Reset only this confirmed test fixture for the remaining helper checks.
        try files.removeItem(at: destination)
        try files.copyItem(at: healthyBackup, to: destination)

        info["CFBundleShortVersionString"] = "2.0.0"
        info["NSHumanReadableCopyright"] = "Modified after signing"
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: staged.appendingPathComponent("Contents/Info.plist"))
        try rejects { try UpdateInstaller.validateCandidate(staged, version: "2.0.0", matching: destination) }
        print("PASS: size cap, checksum, signer, OS, tampering, atomic swap, abrupt-stop, launch, and health rollback checks")

        // Run the shipped executable's helper against an inert signed fixture app.
        // The fixture writes a marker on launch instead of requesting input access.
        phase("exercise production helper")
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
        try expect(beforeExit == "1.0.0" && parent.isRunning)
        parent.terminate()
        parent.waitUntilExit()
        let result = helperPlan.deletingLastPathComponent().appendingPathComponent("result")
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline && (!files.fileExists(atPath: marker.path) || !files.fileExists(atPath: result.path)) {
            try await Task.sleep(for: .milliseconds(100))
        }
        try expect(files.fileExists(atPath: marker.path), "New app must relaunch: \(UserDefaults(suiteName: "local.vectorscroll.app")!.string(forKey: "updateInstallError") ?? "no helper error")")
        let status = try String(contentsOf: result, encoding: .utf8)
        let installed = try UpdateInstaller.appVersion(destination)
        let backup = try UpdateInstaller.appVersion(helperPlan.deletingLastPathComponent().appendingPathComponent("Previous.app"))
        try expect(status == "success" && installed == "2.0.0" && backup == "1.0.0")
        print("PASS: production helper waits for exit, installs, relaunches, preserves backup, and handles spaces/apostrophes in paths")

        phase("exercise live release download")
        let configuration = URLSessionConfiguration.ephemeral
        if let token = ProcessInfo.processInfo.environment["GH_UPDATE_TEST_TOKEN"] {
            configuration.httpAdditionalHeaders = ["Authorization": "Bearer \(token)"]
        }
        let session = URLSession(configuration: configuration)
        guard let live = try await AppUpdate.check(installedVersion: "0.0.0", session: session) else { throw UpdateInstaller.Failure(message: "Missing live release") }
        let downloaded = try await UpdateInstaller.download(live)
        let actualHash = SHA256.hash(data: try Data(contentsOf: downloaded.url)).map { String(format: "%02x", $0) }.joined()
        try expect(actualHash == live.sha256)
        print("PASS: live GitHub DMG download matches the release checksum")
    }
}
