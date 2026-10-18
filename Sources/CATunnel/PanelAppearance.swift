import Foundation

struct PanelAppearance: Codable, Equatable {
    static let widthRange: ClosedRange<Double> = 300...440
    static let fontScaleRange: ClosedRange<Double> = 0.9...1.2
    static let `default` = PanelAppearance()

    var width: Double
    var fontScale: Double

    init(width: Double = 320, fontScale: Double = 1) {
        self.width = Self.clamp(width, to: Self.widthRange, fallback: 320)
        self.fontScale = Self.clamp(fontScale, to: Self.fontScaleRange, fallback: 1)
    }

    var normalized: PanelAppearance { PanelAppearance(width: width, fontScale: fontScale) }

    private enum CodingKeys: String, CodingKey { case width, fontScale }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(width: (try? container.decode(Double.self, forKey: .width)) ?? 320,
                  fontScale: (try? container.decode(Double.self, forKey: .fontScale)) ?? 1)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        let value = normalized
        try container.encode(value.width, forKey: .width)
        try container.encode(value.fontScale, forKey: .fontScale)
    }

    private static func clamp(_ value: Double, to range: ClosedRange<Double>, fallback: Double) -> Double {
        value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : fallback
    }
}
