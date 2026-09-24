import Foundation

public enum PerfFeatureFlags {
    /// Same-binary causal switch for the history-row ownership architecture.
    /// Production defaults to passive/lazy rows; `0` retains the eager legacy observer path only
    /// for controlled performance comparison.
    public static let passiveHistoryRowEnabled = bool("SCOPY_PERF_PASSIVE_ROW", defaultValue: true)

    /// Same-binary causal switch for the revision-keyed Markdown menu fast-signal cache.
    /// Production keeps the cache enabled; `0` is reserved for the fixed warm-scroll A/B axis.
    public static let markdownMenuSignalCacheEnabled = bool(
        "SCOPY_PERF_MARKDOWN_MENU_SIGNAL_CACHE",
        defaultValue: true
    )

    public static var historyIndexingEnabled: Bool {
        bool("SCOPY_PERF_HISTORY_INDEX", defaultValue: true)
    }

    public static var scrollResolverCacheEnabled: Bool {
        bool("SCOPY_PERF_SCROLL_RESOLVER_CACHE", defaultValue: true)
    }

    public static var markdownResolverCacheEnabled: Bool {
        bool("SCOPY_PERF_MARKDOWN_RESOLVER_CACHE", defaultValue: true)
    }

    public static var shortQueryDebounceEnabled: Bool {
        bool("SCOPY_PERF_SHORT_QUERY_DEBOUNCE", defaultValue: true)
    }

    private static func bool(_ key: String, defaultValue: Bool) -> Bool {
        guard let raw = ProcessInfo.processInfo.environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty else {
            return defaultValue
        }
        switch raw {
        case "1", "true", "yes", "on":
            return true
        case "0", "false", "no", "off":
            return false
        default:
            return defaultValue
        }
    }
}
