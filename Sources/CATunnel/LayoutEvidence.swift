import SwiftUI

private struct CapturesLayoutEvidenceKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var capturesLayoutEvidence: Bool {
        get { self[CapturesLayoutEvidenceKey.self] }
        set { self[CapturesLayoutEvidenceKey.self] = newValue }
    }
}

struct LayoutEvidenceKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, next in next }
    }
}

private struct LayoutEvidenceModifier: ViewModifier {
    let identifier: String
    @Environment(\.capturesLayoutEvidence) private var enabled

    func body(content: Content) -> some View {
        content.background {
            if enabled {
                GeometryReader { geometry in
                    Color.clear.preference(key: LayoutEvidenceKey.self, value: [
                        identifier: geometry.frame(in: .named("catunnel-offline-fixture"))
                    ])
                }
            }
        }
    }
}

extension View {
    /// Inert during normal use; offline fixtures record the actual rendered layout.
    func captureLayoutEvidence(_ identifier: String) -> some View {
        modifier(LayoutEvidenceModifier(identifier: identifier))
    }
}
