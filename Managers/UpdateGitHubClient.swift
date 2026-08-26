import Foundation

struct LiveUpdateClient: UpdateClient {
    let repoOwner: String
    let repoName: String

    func fetchLatestRelease() async throws -> AppRelease {
        let url = URL(string: "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest")!
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("GitWatch/\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown")", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw UpdateManager.UpdateError.httpError(statusCode: code)
        }
        return try UpdateGitHubClient.parseLatestReleaseResponse(data)
    }
}

enum UpdateGitHubClient {
    private struct ReleaseResponse: Decodable {
        struct Asset: Decodable {
            let name: String
            let browserDownloadURL: URL

            private enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
            }
        }

        let tagName: String
        let htmlURL: URL
        let body: String
        let assets: [Asset]

        private enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case body
            case assets
        }
    }

    static func parseLatestReleaseResponse(_ data: Data) throws -> AppRelease {
        let response = try JSONDecoder().decode(ReleaseResponse.self, from: data)
        let version = response.tagName.replacingOccurrences(of: "v", with: "")
        let expectedAssetName = "GitWatch-\(version)-updater.zip"

        guard let zipAsset = response.assets.first(where: { $0.name == expectedAssetName }) else {
            throw NSError(domain: "UpdateGitHubClient", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing updater zip asset"])
        }

        let checksum = response.body
            .split(separator: "\n")
            .compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.lowercased().hasPrefix("sha256:") else { return nil }
                return trimmed.replacingOccurrences(of: "sha256:", with: "", options: .caseInsensitive).trimmingCharacters(in: .whitespaces)
            }
            .first

        return AppRelease(version: version, notesURL: response.htmlURL, zipAssetURL: zipAsset.browserDownloadURL, checksum: checksum)
    }
}
