import Foundation

// MARK: - TranscriptWord

public struct TranscriptWord: Identifiable, Sendable, Codable {
    public let id: UUID
    public let text: String
    public let startTime: Double   // seconds into the original file
    public let endTime: Double

    public init(text: String, startTime: Double, endTime: Double) {
        self.id = UUID()
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
    }

    private enum CodingKeys: String, CodingKey { case text, startTime, endTime }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(text: try c.decode(String.self, forKey: .text),
                  startTime: try c.decode(Double.self, forKey: .startTime),
                  endTime: try c.decode(Double.self, forKey: .endTime))
    }
}
