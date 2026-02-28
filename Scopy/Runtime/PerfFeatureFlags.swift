import Foundation

enum PerfFeatureFlags {
    static var historyIndexingEnabled: Bool {
        bool("SCOPY_PERF_HISTORY_INDEX", defaultValue: true)
    }

    static var scrollResolverCacheEnabled: Bool {
        bool("SCOPY_PERF_SCROLL_RESOLVER_CACHE", defaultValue: true)
    }

    static var markdownResolverCacheEnabled: Bool {
        bool("SCOPY_PERF_MARKDOWN_RESOLVER_CACHE", defaultValue: true)
    }

    static var previewTaskBudgetEnabled: Bool {
        bool("SCOPY_PERF_PREVIEW_TASK_BUDGET", defaultValue: true)
    }

    static var shortQueryDebounceEnabled: Bool {
        bool("SCOPY_PERF_SHORT_QUERY_DEBOUNCE", defaultValue: true)
    }

    static var cleanupCompositePlanEnabled: Bool {
        bool("SCOPY_PERF_CLEANUP_COMPOSITE_PLAN", defaultValue: true)
    }

    static var cleanupShadowCompareEnabled: Bool {
        bool("SCOPY_CLEANUP_SHADOW_COMPARE", defaultValue: false)
    }

    static var externalSizeMetaFastPathEnabled: Bool {
        bool("SCOPY_PERF_EXTERNAL_SIZE_META", defaultValue: true)
    }

    static var searchAdaptiveTuningEnabled: Bool {
        bool("SCOPY_PERF_SEARCH_ADAPTIVE_TUNING", defaultValue: true)
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
