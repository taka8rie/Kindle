import Foundation

struct BookCandidate: Identifiable, Hashable {
    let url: URL

    var id: String { url.path }
    var fileName: String { url.lastPathComponent }
}

struct DeviceSnapshot {
    let title: String
    let rawOutput: String
}

struct TransferBatchResult {
    let successes: [URL]
    let failures: [(url: URL, reason: String)]
}
