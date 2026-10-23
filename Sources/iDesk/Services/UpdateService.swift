import AppKit
import Combine

@MainActor
final class UpdateService: ObservableObject {
    struct Release: Decodable {
        let tag_name: String
        let html_url: URL
        let body: String?
        let draft: Bool
        let prerelease: Bool
    }
    @Published private(set) var checking = false
    @Published private(set) var message = ""
    @Published private(set) var release: Release?
    @Published private(set) var hasUpdate = false
    let currentVersion: String
    init(currentVersion: String? = nil) {
        self.currentVersion = currentVersion ?? (Bundle.main.bundleIdentifier == "dev.idesk.app" ? Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String : nil) ?? "1.3.0"
    }
    /// Only stable numeric releases are comparable; unknown tags are not treated as upgrades.
    static func isNewer(_ tag: String, than current: String) -> Bool {
        func parts(_ raw: String) -> [Int]? {
            let text = raw.hasPrefix("v") ? String(raw.dropFirst()) : raw
            let pieces = text.split(separator: ".", omittingEmptySubsequences: false)
            guard (1...4).contains(pieces.count), pieces.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return nil }
            let values = pieces.compactMap { Int($0) }
            return values.count == pieces.count ? values : nil
        }
        guard let a = parts(tag), let b = parts(current) else { return false }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
    static func trustedReleaseURL(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "github.com" && url.user == nil && url.password == nil &&
        url.path.hasPrefix("/Vhaooforjob/idesk/releases/")
    }
    func check() async {
        guard !checking else { return }
        checking = true; message = ""; release = nil; hasUpdate = false
        defer { checking = false }
        do {
            var request = URLRequest(url: URL(string: "https://api.github.com/repos/Vhaooforjob/idesk/releases/latest")!)
            request.timeoutInterval = 20
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("iDesk", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count < 2_000_000 else {
                throw WorkspaceFeatureError(message: String(localized: "Could not check GitHub releases. Try again later."))
            }
            let result = try JSONDecoder().decode(Release.self, from: data)
            guard !result.draft, !result.prerelease, Self.trustedReleaseURL(result.html_url) else {
                throw WorkspaceFeatureError(message: String(localized: "Invalid release information."))
            }
            release = result
            hasUpdate = Self.isNewer(result.tag_name, than: currentVersion)
            message = hasUpdate ? String(localized: "A new version is available.") : String(localized: "No newer stable version was found.")
        } catch { message = error.localizedDescription }
    }
    func openRelease() {
        guard let url = release?.html_url, Self.trustedReleaseURL(url) else { return }
        NSWorkspace.shared.open(url)
    }
}

/// Release configuration boundary for a future Sparkle dependency. A signed
/// updater must not start with a placeholder feed or key. Nothing self-installs.
struct SignedUpdateConfiguration {
    let feedURL: URL
    let publicKey: String
    init?(info: [String: Any]) {
        guard let address = info["SUFeedURL"] as? String, let url = URL(string: address), url.scheme == "https", url.host != nil,
              let key = info["SUPublicEDKey"] as? String, Data(base64Encoded: key)?.count == 32 else { return nil }
        feedURL = url; publicKey = key
    }
}
