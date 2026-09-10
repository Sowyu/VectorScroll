import Foundation

struct AppUpdate: Sendable {
    let version: String
    let downloadURL: URL
    static let installedVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.2.0"
    static let endpoint = URL(string: "https://api.github.com/repos/Sowyu/VectorScroll/releases/latest")!

    enum CheckError: LocalizedError {
        case unavailable, invalidRelease, unknownVersion
        var errorDescription: String? {
            switch self {
            case .unavailable: "GitHub could not provide the latest release. Try again later."
            case .invalidRelease: "The latest release has no supported installer. Try again later."
            case .unknownVersion: "The app version could not be compared with the latest release."
            }
        }
    }

    private struct Release: Decodable {
        let tag_name: String
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
            let size: Int
        }
    }

    static func versionNumbers(_ version: String) -> [Int]? {
        let text = version.hasPrefix("v") ? String(version.dropFirst()) : version
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy({ $0 >= "0" && $0 <= "9" }),
                  let value = Int(part) else { return nil }
            numbers.append(value)
        }
        if numbers.count == 2 { numbers.append(0) }
        return numbers
    }

    static func parse(_ data: Data, statusCode: Int, installedVersion: String) throws -> AppUpdate? {
        guard statusCode == 200 else { throw CheckError.unavailable }
        let release = try JSONDecoder().decode(Release.self, from: data)
        guard !release.draft, !release.prerelease else { throw CheckError.invalidRelease }
        guard let installed = versionNumbers(installedVersion),
              let latest = versionNumbers(release.tag_name) else { throw CheckError.unknownVersion }
        guard installed.lexicographicallyPrecedes(latest) else { return nil }
        let expectedURL = "https://github.com/Sowyu/VectorScroll/releases/download/\(release.tag_name)/VectorScroll.dmg"
        guard let asset = release.assets.first(where: {
            $0.name == "VectorScroll.dmg" && $0.size > 0 && $0.browser_download_url.absoluteString == expectedURL
        }) else { throw CheckError.invalidRelease }
        return AppUpdate(version: release.tag_name, downloadURL: asset.browser_download_url)
    }

    static func check(installedVersion: String = AppUpdate.installedVersion) async throws -> AppUpdate? {
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("VectorScroll/\(installedVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        return try parse(data, statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0,
                         installedVersion: installedVersion)
    }
}
