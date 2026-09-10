import Foundation
import CryptoKit

enum UpdateInstaller {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    struct Plan: Codable, Sendable {
        let destination: String
        let originalVersion: String
        let version: String
        let parentPID: Int32
        var relaunchArguments: [String] = []
    }

    static func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure(message: "Update verification or installation failed at \(URL(fileURLWithPath: executable).lastPathComponent). Your previous app has been kept.")
        }
    }

    static func appVersion(_ app: URL) throws -> String {
        guard app.pathExtension == "app",
              try app.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true,
              let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")), format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == "local.vectorscroll.app",
              info["CFBundleExecutable"] as? String == "VectorScroll",
              let version = info["CFBundleShortVersionString"] as? String,
              AppUpdate.versionNumbers(version) != nil else {
            throw Failure(message: "The update does not contain a valid VectorScroll app.")
        }
        return version
    }

    static func validateDestination(_ destination: URL) throws -> String {
        let version = try appVersion(destination)
        guard FileManager.default.isWritableFile(atPath: destination.deletingLastPathComponent().path) else {
            throw Failure(message: "This copy cannot update in its current location. Move VectorScroll from the DMG into a writable Applications folder, then try again.")
        }
        return version
    }

    static func download(_ update: AppUpdate) async throws -> Data {
        var request = URLRequest(url: update.downloadURL, timeoutInterval: 120)
        request.setValue("VectorScroll/\(AppUpdate.installedVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count == update.downloadSize else {
            throw Failure(message: "The update download was incomplete. Please try again.")
        }
        return data
    }

    static func prepare(_ update: AppUpdate, image: Data, destination: URL,
                        helperSource: URL, parentPID: Int32) throws -> URL {
        let original = try validateDestination(destination)
        guard let old = AppUpdate.versionNumbers(original), let new = AppUpdate.versionNumbers(update.version),
              old.lexicographicallyPrecedes(new) else {
            throw Failure(message: "This update is not newer than the installed app.")
        }
        let hash = SHA256.hash(data: image).map { String(format: "%02x", $0) }.joined()
        guard image.count == update.downloadSize, hash == update.sha256 else {
            throw Failure(message: "The update did not match GitHub's SHA-256 checksum. Nothing was installed.")
        }
        let files = FileManager.default
        let work = destination.deletingLastPathComponent().appendingPathComponent(".VectorScroll-update-\(UUID().uuidString)")
        try files.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let imageURL = work.appendingPathComponent("Update.dmg")
        try image.write(to: imageURL, options: .withoutOverwriting)
        let mount = work.appendingPathComponent("mount")
        try files.createDirectory(at: mount, withIntermediateDirectories: false)
        try run("/usr/bin/hdiutil", ["attach", "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", mount.path, imageURL.path])
        defer { try? run("/usr/bin/hdiutil", ["detach", mount.path]) }
        let candidate = mount.appendingPathComponent("VectorScroll.app")
        let stage = work.appendingPathComponent("VectorScroll.app")
        try files.copyItem(at: candidate, to: stage)
        try validateCandidate(stage, version: update.version)
        try files.copyItem(at: helperSource, to: work.appendingPathComponent("update-helper"))
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: work.appendingPathComponent("update-helper").path)
        let plan = Plan(destination: destination.path, originalVersion: original, version: update.version, parentPID: parentPID)
        let planURL = work.appendingPathComponent("plan.json")
        try JSONEncoder().encode(plan).write(to: planURL, options: .withoutOverwriting)
        return planURL
    }

    static func validateCandidate(_ app: URL, version: String) throws {
        guard try AppUpdate.versionNumbers(appVersion(app)) == AppUpdate.versionNumbers(version) else {
            throw Failure(message: "The downloaded app has the wrong version.")
        }
        let binary = app.appendingPathComponent("Contents/MacOS/VectorScroll")
        let attributes = try binary.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard attributes.isRegularFile == true, attributes.isSymbolicLink != true else {
            throw Failure(message: "The downloaded app has an invalid executable.")
        }
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        #if arch(arm64)
        let architecture = 0x0100000c
        #else
        let architecture = 0x01000007
        #endif
        guard Bundle(url: app)?.executableArchitectures?.contains(where: { $0.intValue == architecture }) == true else {
            throw Failure(message: "This update does not support this Mac's processor.")
        }
    }

    static func launchHelper(_ planURL: URL) throws {
        let work = planURL.deletingLastPathComponent()
        let process = Process()
        process.executableURL = work.appendingPathComponent("update-helper")
        process.arguments = ["--install-update", planURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(10)
        while process.isRunning && Date() < deadline {
            if FileManager.default.fileExists(atPath: work.appendingPathComponent("ready").path) { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning { process.terminate() }
        throw Failure(message: "The update helper could not start. The current app is still installed.")
    }

    static func readPlan(_ planURL: URL) throws -> Plan {
        let plan = try JSONDecoder().decode(Plan.self, from: Data(contentsOf: planURL))
        let work = planURL.deletingLastPathComponent().standardizedFileURL
        let destination = URL(fileURLWithPath: plan.destination).standardizedFileURL
        guard work.lastPathComponent.hasPrefix(".VectorScroll-update-"),
              destination.deletingLastPathComponent() == work.deletingLastPathComponent(),
              plan.parentPID > 1 else { throw Failure(message: "Invalid update plan.") }
        return plan
    }

    // Renames stay on the same volume. Keep both the old app and update files;
    // never delete them, including when rolling back a failed installation.
    static func replace(_ planURL: URL,
                        move: (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) },
                        launch: (URL, [String]) throws -> Void = { try run("/usr/bin/open", ["-n", $0.path, "--args"] + $1) }) throws {
        let plan = try readPlan(planURL)
        let work = planURL.deletingLastPathComponent()
        let destination = URL(fileURLWithPath: plan.destination)
        let staged = work.appendingPathComponent("VectorScroll.app")
        let backup = work.appendingPathComponent("Previous.app")
        guard try appVersion(destination) == plan.originalVersion else {
            throw Failure(message: "The installed app changed while updating. Please check for updates again.")
        }
        try validateCandidate(staged, version: plan.version)
        try move(destination, backup)
        do {
            try move(staged, destination)
            try launch(destination, plan.relaunchArguments)
        } catch {
            if FileManager.default.fileExists(atPath: destination.path) { try move(destination, staged) }
            try move(backup, destination)
            throw error
        }
    }

    static func runHelper(_ planURL: URL) -> Int32 {
        do {
            let plan = try readPlan(planURL)
            let work = planURL.deletingLastPathComponent()
            try validateCandidate(work.appendingPathComponent("VectorScroll.app"), version: plan.version)
            try Data().write(to: work.appendingPathComponent("ready"), options: .withoutOverwriting)
            let deadline = Date().addingTimeInterval(30)
            while kill(plan.parentPID, 0) == 0 && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
            guard kill(plan.parentPID, 0) != 0 else { throw Failure(message: "VectorScroll did not quit in time. Please try again.") }
            try replace(planURL)
            try Data("success".utf8).write(to: work.appendingPathComponent("result"), options: .withoutOverwriting)
            return 0
        } catch {
            let preferences = UserDefaults(suiteName: "local.vectorscroll.app")!
            preferences.set("Automatic update failed. Your previous copy was kept. \(error.localizedDescription)", forKey: "updateInstallError")
            preferences.synchronize()
            if let plan = try? readPlan(planURL), kill(plan.parentPID, 0) != 0 {
                try? run("/usr/bin/open", ["-n", plan.destination])
            }
            return 1
        }
    }
}
