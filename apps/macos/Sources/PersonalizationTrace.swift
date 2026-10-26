import Foundation

struct PersonalizationReference: Codable, Equatable, Identifiable {
    var kind: String
    var source: String
    var sourceId: String
    var word: String?
    var heard: String?
    var label: String?
    var id: String { kind + source + sourceId + (word ?? "") + (heard ?? "") }
}
struct PersonalizationReplacement: Codable, Equatable, Identifiable {
    var id: String
    var heard: String?
    var word: String?
    var reason: String?
}
struct PersonalizationTrace: Codable, Equatable {
    var disabled: Bool
    var references: [PersonalizationReference]
    var replacements: [PersonalizationReplacement]
    var blocked: [PersonalizationReplacement]
    var restored: Bool?
    var beforeReplacements: String?
}
