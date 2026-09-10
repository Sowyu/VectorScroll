import Foundation
import CryptoKit

@main
struct CheckInstaller {
    static func rejects(_ action: () throws -> Void) {
        do { try action(); fatalError("Expected installation to be rejected") } catch { }
    }

    static func main() async throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("VectorScroll install test's \(UUID().uuidString)")
        let sourceFolder = root.appendingPathComponent("image")
        let source = sourceFolder.appendingPathComponent("VectorScroll.app")
        let binaries = source.appendingPathComponent("Contents/MacOS")
        try files.createDirectory(at: binaries, withIntermediateDirectories: true)
        let stub = root.appendingPathComponent("Fixture.swift")
        try """
        import Foundation
        if CommandLine.arguments.count > 1 {
            try Data("launched".utf8).write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        }
        """.write(to: stub, atomically: false, encoding: .utf8)
        try UpdateInstaller.run("/usr/bin/xcrun", ["swiftc", stub.path, "-o", binaries.appendingPathComponent("VectorScroll").path])
        var info: [String: Any] = ["CFBundleIdentifier": "local.vectorscroll.app", "CFBundleExecutable": "VectorScroll",
                                  "CFBundleName": "VectorScroll", "CFBundlePackageType": "APPL", "LSUIElement": true,
                                  "CFBundleShortVersionString": "2.0.0", "CFBundleVersion": "200", "LSMinimumSystemVersion": "14.0"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: source.appendingPathComponent("Contents/Info.plist"))
        try UpdateInstaller.run("/usr/bin/codesign", ["--force", "--deep", "--sign", "-", source.path])
        let destination = root.appendingPathComponent("Installed App's Folder/VectorScroll.app")
        try files.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try files.copyItem(at: source, to: destination)
        info["CFBundleShortVersionString"] = "1.0.0"
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: destination.appendingPathComponent("Contents/Info.plist"))
        try UpdateInstaller.run("/usr/bin/codesign", ["--force", "--deep", "--sign", "-", destination.path])
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
        rejects { try UpdateInstaller.validateCandidate(source, version: "9.0.0") }
        let plan = try UpdateInstaller.prepare(update, image: image, destination: destination,
                                              helperSource: helper, parentPID: getpid())
        var moves = 0
        rejects {
            try UpdateInstaller.replace(plan, move: { from, to in
                moves += 1
                if moves == 2 { throw UpdateInstaller.Failure(message: "Simulated replacement failure") }
                try files.moveItem(at: from, to: to)
            }, launch: { _, _ in fatalError("Must not launch a failed replacement") })
        }
        let restoredAfterMove = try UpdateInstaller.appVersion(destination)
        assert(restoredAfterMove == "1.0.0")
        rejects {
            try UpdateInstaller.replace(plan, launch: { _, _ in throw UpdateInstaller.Failure(message: "Simulated launch failure") })
        }
        let restoredAfterLaunch = try UpdateInstaller.appVersion(destination)
        assert(restoredAfterLaunch == "1.0.0")
        let staged = plan.deletingLastPathComponent().appendingPathComponent("VectorScroll.app")
        info["CFBundleShortVersionString"] = "2.0.0"
        info["NSHumanReadableCopyright"] = "Modified after signing"
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: staged.appendingPathComponent("Contents/Info.plist"))
        rejects { try UpdateInstaller.validateCandidate(staged, version: "2.0.0") }
        print("PASS: checksum rejection, wrong version, signature tampering, replacement rollback, and launch rollback")

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
