import Foundation

private final class TimestampCacheBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int64: String] = [:]
    private var orderedKeys: [Int64] = []
    private let maxCount = 512

    func value(for second: Int64) -> String? {
        self.lock.withLock {
            self.values[second]
        }
    }

    func store(_ value: String, for second: Int64) {
        self.lock.withLock {
            if self.values[second] != nil {
                self.values[second] = value
                return
            }

            self.values[second] = value
            self.orderedKeys.append(second)

            if self.orderedKeys.count > self.maxCount,
               let expired = self.orderedKeys.first
            {
                self.orderedKeys.removeFirst()
                self.values.removeValue(forKey: expired)
            }
        }
    }
}

enum ValueFormatter {
    private static let timestampCache = TimestampCacheBox()

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    private nonisolated(unsafe) static let iso8601FractionalFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private nonisolated(unsafe) static let iso8601BasicFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func speed(_ value: Int64) -> String {
        let normalized = max(0, value)
        if normalized >= 1024 * 1024 {
            return String(format: "%.2f MB/s", Double(normalized) / (1024 * 1024))
        }
        return String(format: "%.2f KB/s", Double(normalized) / 1024)
    }

    static func bytesInteger(_ value: Int64) -> String {
        let normalized = max(0, value)
        let kb: Int64 = 1024
        let mb = kb * 1024
        let gb = mb * 1024
        let tb = gb * 1024

        if normalized >= tb {
            return self.roundedBytesText(normalized, divisor: Double(tb), unit: "TB")
        }
        if normalized >= gb {
            return self.roundedBytesText(normalized, divisor: Double(gb), unit: "GB")
        }
        if normalized >= mb {
            return self.roundedBytesText(normalized, divisor: Double(mb), unit: "MB")
        }
        if normalized >= kb {
            return self.roundedBytesText(normalized, divisor: Double(kb), unit: "KB")
        }

        if normalized == 0 {
            return "0 KB"
        }
        return "1 KB"
    }

    static func bytesCompact(_ value: Int64) -> String {
        let normalized = max(0, value)
        if normalized >= 1024 * 1024 * 1024 {
            return String(format: "%.1f GB", Double(normalized) / (1024 * 1024 * 1024))
        }
        if normalized >= 1024 * 1024 {
            return String(format: "%.1f MB", Double(normalized) / (1024 * 1024))
        }
        return String(format: "%.1f KB", Double(normalized) / 1024)
    }

    static func bytesCompactNoSpace(_ value: Int64) -> String {
        let normalized = max(0, value)
        if normalized >= 1024 * 1024 * 1024 * 1024 {
            return self.compactNoSpace(value: Double(normalized) / (1024 * 1024 * 1024 * 1024), unit: "TB")
        }
        if normalized >= 1024 * 1024 * 1024 {
            return self.compactNoSpace(value: Double(normalized) / (1024 * 1024 * 1024), unit: "GB")
        }
        if normalized >= 1024 * 1024 {
            return self.compactNoSpace(value: Double(normalized) / (1024 * 1024), unit: "MB")
        }
        return self.compactNoSpace(value: Double(normalized) / 1024, unit: "KB")
    }

    static func bytesGBNoSpace(_ value: Int64) -> String {
        let normalized = max(0, value)
        return self.detailedNoSpace(value: Double(normalized) / (1024 * 1024 * 1024), unit: "GB")
    }

    static func bytesOrDash(_ value: Int64?) -> String {
        guard let value else { return "--" }
        return self.bytesCompact(value)
    }

    static func speedAndTotal(rate: Int64, total: Int64?) -> String {
        "\(self.speed(rate)) · \(self.bytesOrDash(total))"
    }

    static func dateTime(_ date: Date) -> String {
        let second = Int64(date.timeIntervalSince1970.rounded(.down))
        if let cached = self.timestampCache.value(for: second) {
            return cached
        }

        let formatted = self.timestampFormatter.string(from: date)
        self.timestampCache.store(formatted, for: second)
        return formatted
    }

    static func relativeTime(from input: String?, language: AppLanguage, now: Date = Date()) -> String {
        guard let input = input?.trimmingCharacters(in: .whitespacesAndNewlines), !input.isEmpty else {
            return L10n.t("fmt.common.unknown", language: language)
        }

        let parsedDate = self.parseISO8601Date(input)
        guard let date = parsedDate else { return L10n.t("fmt.common.unknown", language: language) }

        let interval = max(0, now.timeIntervalSince(date))
        let minutes = Int(interval / 60)
        if minutes < 60 {
            return L10n.t("fmt.relative.minutes", language: language, minutes)
        }

        let hours = Int(interval / 3600)
        if hours < 24 {
            return L10n.t("fmt.relative.hours", language: language, hours)
        }

        let days = Int(interval / 86400)
        return L10n.t("fmt.relative.days", language: language, days)
    }

    static func dateTimeFromISO(_ input: String?) -> String {
        guard let input = input?.trimmingCharacters(in: .whitespacesAndNewlines), !input.isEmpty else {
            return "--"
        }
        guard let date = parseISO8601Date(input) else { return "--" }
        return self.dateTime(date)
    }

    static func daysUntilExpiryShort(from unixSeconds: Int64?, language: AppLanguage, now: Date = Date()) -> String {
        guard let unixSeconds else { return L10n.t("fmt.common.unknown", language: language) }
        if unixSeconds == 0 {
            return L10n.t("fmt.expiry_short.long_term", language: language)
        }
        guard unixSeconds > 0 else { return L10n.t("fmt.common.unknown", language: language) }

        let expiryDate = Date(timeIntervalSince1970: TimeInterval(unixSeconds))
        let seconds = expiryDate.timeIntervalSince(now)
        let day = 86400.0

        if seconds < 0 {
            return L10n.t("fmt.expiry_short.expired", language: language)
        }

        let days = Int(floor(seconds / day))
        if days <= 0 {
            return L10n.t("fmt.expiry_short.today", language: language)
        }
        return L10n.t("fmt.expiry_short.days", language: language, days)
    }

    private static func compactNoSpace(value: Double, unit: String) -> String {
        if abs(value.rounded() - value) < 0.05 {
            return "\(Int(value.rounded()))\(unit)"
        }
        return String(format: "%.1f%@", value, unit)
    }

    private static func detailedNoSpace(value: Double, unit: String) -> String {
        var text = String(format: "%.2f", value)
        while text.last == "0" {
            text.removeLast()
        }
        if text.last == "." {
            text.removeLast()
        }
        return "\(text)\(unit)"
    }

    private static func roundedBytesText(_ value: Int64, divisor: Double, unit: String) -> String {
        let scaled = Double(value) / divisor
        let rounded = Int(scaled.rounded())
        return "\(rounded) \(unit)"
    }

    static func parseISO8601Date(_ input: String) -> Date? {
        if let date = self.iso8601FractionalFormatter.date(from: input) {
            return date
        }
        return self.iso8601BasicFormatter.date(from: input)
    }

    static func remoteConfigMenuStatusLine(
        autoUpdateEnabled: Bool,
        nextUpdateAt: Date?,
        lastUpdateAt: Date?,
        language: AppLanguage,
        now: Date = Date()) -> String?
    {
        var parts: [String] = []

        if autoUpdateEnabled, let next = nextUpdateAt {
            let remaining = max(0, Int(next.timeIntervalSince(now)))
            let minutes = (remaining / 60) % 60
            let hours = remaining / 3600
            if hours > 0 {
                parts.append(L10n.t("fmt.remote_config.next_update_hours_minutes", language: language, hours, minutes))
            } else {
                parts.append(L10n.t("fmt.remote_config.next_update_minutes", language: language, max(1, minutes)))
            }
        }

        if let last = lastUpdateAt {
            let calendar = Calendar.current
            if calendar.isDate(last, inSameDayAs: now) {
                parts.append(L10n.t(
                    "fmt.remote_config.last_update",
                    language: language,
                    self.shortTimeFormatter.string(from: last)))
            } else {
                parts.append(L10n.t(
                    "fmt.remote_config.last_update",
                    language: language,
                    self.shortDateTimeFormatter.string(from: last)))
            }
        }

        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static let shortTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let shortDateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()
}
