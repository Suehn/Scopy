import Foundation

enum FullIndexDiskCacheLoadReason: String, Sendable {
    case metadataMissing = "metadata_missing"
    case fingerprintMismatch = "fingerprint_mismatch"
    case tombstoneStale = "tombstone_stale"
    case checksumMismatch = "checksum_mismatch"
    case decodeFailed = "decode_failed"
    case payloadInvalid = "payload_invalid"
    case diskCacheHit = "disk_cache_hit"
    case databaseRebuild = "database_rebuild"
}

struct FullIndexDiskCacheMetadataV2: Codable, Sendable {
    let version: Int
    let mutationSeq: Int64
    let itemCount: Int
    let tombstoneCount: Int
    let tombstoneRatio: Double
    let payloadByteSize: UInt64
}

struct FullIndexDiskCacheLoadCandidate: Sendable {
    let stamp: DBContentStamp
    let metadata: FullIndexDiskCacheMetadataV2?
    let cachePath: String
    let checksumPath: String
    let metadataPath: String
    let preflightReason: FullIndexDiskCacheLoadReason?
}

enum FullIndexDiskCachePreflightResult: Sendable {
    case candidate(FullIndexDiskCacheLoadCandidate)
    case skip(reason: FullIndexDiskCacheLoadReason, metadata: FullIndexDiskCacheMetadataV2?)
}

struct FullIndexDiskCacheLoadOutcome: Sendable {
    let snapshot: FullIndexSnapshot?
    let reason: FullIndexDiskCacheLoadReason
    let metadata: FullIndexDiskCacheMetadataV2?
}
