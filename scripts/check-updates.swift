import Foundation

@main
struct CheckUpdates {
    static func payload(tag: String = "v1.10.0", draft: Bool = false, prerelease: Bool = false,
                        url: String? = nil, assets: Bool = true) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "tag_name": tag, "draft": draft, "prerelease": prerelease,
            "assets": assets ? [["name": "VectorScroll.dmg", "size": 123,
                                  "browser_download_url": url ?? "https://github.com/Sowyu/VectorScroll/releases/download/\(tag)/VectorScroll.dmg"]] : []
        ])
    }

    static func rejects(_ body: Data, status: Int = 200) {
        do {
            _ = try AppUpdate.parse(body, statusCode: status, installedVersion: "1.2.0")
            fatalError("Expected invalid response to be rejected")
        } catch { }
    }

    static func main() async throws {
        let newer = try payload()
        let update = try AppUpdate.parse(newer, statusCode: 200, installedVersion: "1.2.0")
        assert(update?.version == "v1.10.0")
        assert(update?.downloadURL.absoluteString == "https://github.com/Sowyu/VectorScroll/releases/download/v1.10.0/VectorScroll.dmg")
        let same = try AppUpdate.parse(newer, statusCode: 200, installedVersion: "1.10.0")
        let older = try AppUpdate.parse(newer, statusCode: 200, installedVersion: "2.0.0")
        assert(same == nil && older == nil)
        assert(AppUpdate.versionNumbers("1.0") == [1, 0, 0])
        for invalid in ["", "1..0", "1.2.0-beta", "1.2.0.1", "1.-2.0", "1.2/evil", "1.2.999999999999999999999999"] {
            assert(AppUpdate.versionNumbers(invalid) == nil)
        }
        rejects(newer, status: 403)
        rejects(newer, status: 429)
        rejects(newer, status: 500)
        rejects(Data("not JSON".utf8))
        rejects(try payload(draft: true))
        rejects(try payload(prerelease: true))
        rejects(try payload(assets: false))
        rejects(try payload(url: "https://example.com/VectorScroll.dmg"))
        rejects(try payload(url: "http://github.com/Sowyu/VectorScroll/releases/download/v1.10.0/VectorScroll.dmg"))
        rejects(try payload(url: "https://github.com/other/repo/releases/download/v1.10.0/VectorScroll.dmg"))
        print("PASS: version ordering, equal/older releases, invalid versions, HTTP errors, malformed releases, and download URL validation")

        // Use the same anonymous URLSession request as the app against real GitHub.
        guard let live = try await AppUpdate.check(installedVersion: "0.0.0") else {
            fatalError("Expected a published release newer than 0.0.0")
        }
        var request = URLRequest(url: live.downloadURL, timeoutInterval: 30)
        request.httpMethod = "HEAD"
        let (_, response) = try await URLSession.shared.data(for: request)
        assert((response as? HTTPURLResponse)?.statusCode == 200)
        print("PASS: live GitHub check found \(live.version); its installer URL returns HTTP 200")
    }
}
