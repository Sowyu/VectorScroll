import Foundation
import CryptoKit
import Security
import Darwin

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
        let healthToken: String
        var relaunchArguments: [String] = []
    }

    private static let healthArgument = "--vector-scroll-update-health"
    private static let healthFilePrefix = "healthy-"

    private struct SigningTrust {
        let requirement: SecRequirement
        let leafCertificate: Data
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

    static func download(_ update: AppUpdate, session: URLSession = .shared) async throws -> Data {
        guard (1...(100 * 1024 * 1024)).contains(update.downloadSize) else {
            throw Failure(message: "GitHub reported an invalid update size.")
        }
        var request = URLRequest(url: update.downloadURL, timeoutInterval: 120)
        request.setValue("VectorScroll/\(AppUpdate.installedVersion)", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await session.bytes(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            bytes.task.cancel()
            throw Failure(message: "The update download was incomplete. Please try again.")
        }
        var data = Data()
        data.reserveCapacity(update.downloadSize)
        for try await byte in bytes {
            guard data.count < update.downloadSize else {
                bytes.task.cancel()
                throw Failure(message: "The update download was larger than GitHub reported. Nothing was installed.")
            }
            data.append(byte)
        }
        guard data.count == update.downloadSize else {
            throw Failure(message: "The update download was incomplete. Please try again.")
        }
        return data
    }

    static func prepare(_ update: AppUpdate, image: Data, destination: URL,
                        helperSource: URL, parentPID: Int32) throws -> URL {
        let original = try validateDestination(destination)
        let trust = try signingTrust(for: destination)
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
        try validateCandidate(stage, version: update.version, trust: trust)
        try files.copyItem(at: helperSource, to: work.appendingPathComponent("update-helper"))
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: work.appendingPathComponent("update-helper").path)
        let plan = Plan(destination: destination.path, originalVersion: original, version: update.version,
                        parentPID: parentPID, healthToken: UUID().uuidString)
        let planURL = work.appendingPathComponent("plan.json")
        try JSONEncoder().encode(plan).write(to: planURL, options: .withoutOverwriting)
        return planURL
    }

    private static func staticCode(at app: URL) throws -> SecStaticCode {
        var code: SecStaticCode?
        let status = SecStaticCodeCreateWithPath(app as CFURL, [], &code)
        guard status == errSecSuccess, let code else {
            throw Failure(message: "The update has an unreadable code signature.")
        }
        return code
    }

    private static func signingTrust(for trustedApp: URL) throws -> SigningTrust {
        let code = try staticCode(at: trustedApp)
        let flags = SecCSFlags(rawValue: kSecCSCheckNestedCode | kSecCSCheckAllArchitectures | kSecCSStrictValidate)
        guard SecStaticCodeCheckValidity(code, flags, nil) == errSecSuccess else {
            throw Failure(message: "The installed app's code signature is invalid. Reinstall VectorScroll manually before updating.")
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let details = information as? [String: Any],
              let certificates = details[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certificates.first else {
            throw Failure(message: "The installed app is not signed by the VectorScroll release identity. Reinstall it manually before updating.")
        }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess,
              let requirement else {
            throw Failure(message: "The installed app's signing identity could not be read.")
        }
        return SigningTrust(requirement: requirement, leafCertificate: SecCertificateCopyData(leaf) as Data)
    }

    static func validateCandidate(_ app: URL, version: String, matching trustedApp: URL) throws {
        let trust = try signingTrust(for: trustedApp)
        try validateCandidate(app, version: version, trust: trust)
    }

    private static func validateCandidate(_ app: URL, version: String, trust: SigningTrust) throws {
        guard try AppUpdate.versionNumbers(appVersion(app)) == AppUpdate.versionNumbers(version) else {
            throw Failure(message: "The downloaded app has the wrong version.")
        }
        let binary = app.appendingPathComponent("Contents/MacOS/VectorScroll")
        let attributes = try binary.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard attributes.isRegularFile == true, attributes.isSymbolicLink != true else {
            throw Failure(message: "The downloaded app has an invalid executable.")
        }
        let code = try staticCode(at: app)
        let flags = SecCSFlags(rawValue: kSecCSCheckNestedCode | kSecCSCheckAllArchitectures | kSecCSStrictValidate)
        var information: CFDictionary?
        guard SecStaticCodeCheckValidity(code, flags, trust.requirement) == errSecSuccess,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let details = information as? [String: Any],
              let certificates = details[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certificates.first,
              (SecCertificateCopyData(leaf) as Data) == trust.leafCertificate else {
            throw Failure(message: "The update was not signed by the same identity as the installed app.")
        }
        try validateMinimumSystemVersion(app)
        #if arch(arm64)
        let architecture = 0x0100000c
        #else
        let architecture = 0x01000007
        #endif
        guard Bundle(url: app)?.executableArchitectures?.contains(where: { $0.intValue == architecture }) == true else {
            throw Failure(message: "This update does not support this Mac's processor.")
        }
    }

    private static func validateMinimumSystemVersion(_ app: URL) throws {
        guard let info = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")), format: nil
        ) as? [String: Any] else {
            throw Failure(message: "The update has an invalid Info.plist.")
        }
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        var versions: [String] = []
        if let general = info["LSMinimumSystemVersion"] as? String { versions.append(general) }
        if let byArchitecture = info["LSMinimumSystemVersionByArchitecture"] as? [String: String],
           let specific = byArchitecture[architecture] { versions.append(specific) }
        let current = ProcessInfo.processInfo.operatingSystemVersion
        let currentNumbers = [current.majorVersion, current.minorVersion, current.patchVersion]
        for text in versions {
            let parts = text.split(separator: ".", omittingEmptySubsequences: false)
            var minimum = parts.compactMap { part -> Int? in
                guard !part.isEmpty, part.allSatisfy({ $0.isNumber }) else { return nil }
                return Int(part)
            }
            guard (1...3).contains(parts.count), minimum.count == parts.count else {
                throw Failure(message: "The update has an invalid minimum macOS version.")
            }
            while minimum.count < 3 { minimum.append(0) }
            guard !currentNumbers.lexicographicallyPrecedes(minimum) else {
                throw Failure(message: "This update requires a newer version of macOS.")
            }
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
              plan.parentPID > 1, UUID(uuidString: plan.healthToken) != nil else {
            throw Failure(message: "Invalid update plan.")
        }
        return plan
    }

    @discardableResult
    static func acknowledgeLaunch(arguments: [String] = CommandLine.arguments,
                                  bundleURL: URL = Bundle.main.bundleURL) throws -> Bool {
        guard let index = arguments.firstIndex(of: healthArgument) else { return false }
        guard arguments.count == index + 3,
              UUID(uuidString: arguments[index + 2]) != nil else {
            throw Failure(message: "Invalid update health check.")
        }
        let planURL = URL(fileURLWithPath: arguments[index + 1]).standardizedFileURL
        let attempt = arguments[index + 2]
        let plan = try readPlan(planURL)
        let destination = URL(fileURLWithPath: plan.destination).resolvingSymlinksInPath().standardizedFileURL
        guard bundleURL.resolvingSymlinksInPath().standardizedFileURL == destination else {
            throw Failure(message: "Invalid update health check destination.")
        }
        try Data(plan.healthToken.utf8).write(
            to: planURL.deletingLastPathComponent().appendingPathComponent(healthFilePrefix + attempt),
            options: .withoutOverwriting
        )
        return true
    }

    private static func atomicSwap(_ first: URL, _ second: URL) throws {
        let result = first.path.withCString { firstPath in
            second.path.withCString { secondPath in
                renameatx_np(AT_FDCWD, firstPath, AT_FDCWD, secondPath, UInt32(RENAME_SWAP))
            }
        }
        guard result == 0 else {
            throw Failure(message: "The update could not atomically replace the installed app. Your previous app has been kept.")
        }
    }

    private static func launchApplication(_ app: URL, arguments: [String]) throws -> Process {
        let process = Process()
        process.executableURL = app.appendingPathComponent("Contents/MacOS/VectorScroll")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }

    private static func waitForHealth(_ planURL: URL, token: String, attempt: String, process: Process,
                                      timeout: TimeInterval) throws {
        let marker = planURL.deletingLastPathComponent().appendingPathComponent(healthFilePrefix + attempt)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = try? Data(contentsOf: marker), data == Data(token.utf8), process.isRunning { return }
            if !process.isRunning { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw Failure(message: "The updated app did not finish starting. The previous version was restored.")
    }

    private static func stopProcess(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
    }

    // The swap is atomic and stays on one volume. Keep both app copies, including
    // after rollback, so a stopped helper cannot leave the destination empty.
    static func replace(_ planURL: URL,
                        move: (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) },
                        swap: (URL, URL) throws -> Void = { try atomicSwap($0, $1) },
                        launch: (URL, [String]) throws -> Process = { try launchApplication($0, arguments: $1) },
                        healthTimeout: TimeInterval = 10) throws {
        let plan = try readPlan(planURL)
        let work = planURL.deletingLastPathComponent()
        let destination = URL(fileURLWithPath: plan.destination)
        let staged = work.appendingPathComponent("VectorScroll.app")
        let backup = work.appendingPathComponent("Previous.app")
        let trust = try signingTrust(for: destination)
        guard try appVersion(destination) == plan.originalVersion else {
            throw Failure(message: "The installed app changed while updating. Please check for updates again.")
        }
        try validateCandidate(staged, version: plan.version, trust: trust)
        try swap(destination, staged)
        var previous = staged
        var launchedProcess: Process?
        do {
            try move(staged, backup)
            previous = backup
            let attempt = UUID().uuidString
            let arguments = plan.relaunchArguments + [healthArgument, planURL.path, attempt]
            launchedProcess = try launch(destination, arguments)
            try waitForHealth(planURL, token: plan.healthToken, attempt: attempt,
                              process: launchedProcess!, timeout: healthTimeout)
        } catch {
            if let launchedProcess { stopProcess(launchedProcess) }
            try swap(destination, previous)
            if previous == backup {
                try? move(backup, staged)
            }
            throw error
        }
    }

    static func runHelper(_ planURL: URL) -> Int32 {
        do {
            let plan = try readPlan(planURL)
            let work = planURL.deletingLastPathComponent()
            let destination = URL(fileURLWithPath: plan.destination)
            let trust = try signingTrust(for: destination)
            try validateCandidate(work.appendingPathComponent("VectorScroll.app"),
                                  version: plan.version, trust: trust)
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
