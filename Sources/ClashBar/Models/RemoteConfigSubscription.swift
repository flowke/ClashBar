import Foundation

struct SubscriptionUsage: Codable, Equatable {
    var upload: Int64?
    var download: Int64?
    var total: Int64?
    var expiresAt: Date?

    static func parse(_ header: String?) -> SubscriptionUsage? {
        guard let header else { return nil }
        var values: [String: Int64] = [:]
        for part in header.split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1)
            guard pair.count == 2, let number = Int64(pair[1].trimmingCharacters(in: .whitespaces)), number >= 0 else { continue }
            values[pair[0].trimmingCharacters(in: .whitespaces).lowercased()] = number
        }
        guard !values.isEmpty else { return nil }
        return SubscriptionUsage(upload: values["upload"], download: values["download"], total: values["total"],
                                 expiresAt: values["expire"].flatMap { $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil })
    }

    var used: Int64? {
        guard let upload, let download else { return nil }
        let (value, overflow) = upload.addingReportingOverflow(download)
        return overflow ? nil : value
    }
}

struct RemoteConfigSubscription: Codable, Equatable {
    let urlString: String
    var autoUpdateEnabled: Bool
    var autoUpdateIntervalHours: Int
    var lastUpdateCheckAt: Date?
    var usage: SubscriptionUsage?
    var enabled: Bool?
    var isEnabled: Bool { enabled ?? true }

    static let defaultAutoUpdateIntervalHours = 6
    static let minimumAutoUpdateIntervalHours = 1

    init(
        urlString: String,
        autoUpdateEnabled: Bool = false,
        autoUpdateIntervalHours: Int = defaultAutoUpdateIntervalHours,
        lastUpdateCheckAt: Date? = nil,
        usage: SubscriptionUsage? = nil,
        enabled: Bool? = nil)
    {
        self.urlString = urlString
        self.autoUpdateEnabled = autoUpdateEnabled
        self.autoUpdateIntervalHours = max(Self.minimumAutoUpdateIntervalHours, autoUpdateIntervalHours)
        self.lastUpdateCheckAt = lastUpdateCheckAt
        self.usage = usage
        self.enabled = enabled
    }

    func nextUpdateAt() -> Date? {
        guard self.isEnabled, self.autoUpdateEnabled, let lastCheck = lastUpdateCheckAt else { return nil }
        return self.nextUpdateDate(from: lastCheck)
    }

    func isDue(now: Date = Date()) -> Bool {
        guard self.isEnabled, self.autoUpdateEnabled else { return false }
        guard let nextUpdateAt = self.nextUpdateAt() else { return true }
        return now >= nextUpdateAt
    }

    func markChecked(at date: Date = Date()) -> RemoteConfigSubscription {
        RemoteConfigSubscription(
            urlString: self.urlString,
            autoUpdateEnabled: self.autoUpdateEnabled,
            autoUpdateIntervalHours: self.autoUpdateIntervalHours,
            lastUpdateCheckAt: date,
            usage: usage,
            enabled: enabled)
    }

    private func nextUpdateDate(from lastCheck: Date) -> Date {
        lastCheck.addingTimeInterval(TimeInterval(self.autoUpdateIntervalHours) * 3600)
    }
}
