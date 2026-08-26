import Foundation

struct AppVersionInfo {
    let appVersion: String?
    let operatingSystemVersion: OperatingSystemVersion

    init(
        appVersion: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
        operatingSystemVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) {
        self.appVersion = appVersion
        self.operatingSystemVersion = operatingSystemVersion
    }

    init(versionString: String) {
        self.appVersion = versionString
        self.operatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    }

    var appDisplayVersion: String {
        guard let appVersion, appVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return "GitWatch"
        }

        return "GitWatch \(appVersion)"
    }

    var headerDisplayVersion: String {
        guard let appVersion else { return "GitWatch" }

        let trimmedVersion = appVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedVersion.isEmpty ? "GitWatch" : trimmedVersion
    }

    var systemDisplayVersion: String {
        "macOS \(operatingSystemVersion.majorVersion).\(operatingSystemVersion.minorVersion)"
    }

    func isOlder(than otherVersion: String) -> Bool {
        let left = versionComponents(appVersion)
        let right = versionComponents(otherVersion)
        let count = max(left.count, right.count)

        for index in 0..<count {
            let leftValue = index < left.count ? left[index] : 0
            let rightValue = index < right.count ? right[index] : 0

            if leftValue != rightValue {
                return leftValue < rightValue
            }
        }

        return false
    }

    private func versionComponents(_ version: String?) -> [Int] {
        (version ?? "0")
            .split(separator: ".")
            .map { Int($0) ?? 0 }
    }
}
