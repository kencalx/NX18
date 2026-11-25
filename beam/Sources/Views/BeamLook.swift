// Beam's use of NX 18's two colours (the logo's cyan and coral, NX18Palette): cyan for state (ready, tested, the sidebar), coral for action and what is chosen, and the
// cyan-to-coral line where something moves or is in focus (the phone's rails). Errors stay coral with a warning symbol beside them, so colour is never the only signal
import SwiftUI

extension NX18Palette {
    /// The rails' gradient, cyan into coral, left to right
    static var brand: LinearGradient { LinearGradient(colors: [cyan, coral], startPoint: .leading, endPoint: .trailing) }
    /// One of the two colours for a name, the same every time (placeholders, lists of like items): about half the names get each
    static func accent(for key: String) -> Color { key.unicodeScalars.reduce(0) { $0 &+ Int($1.value) } % 2 == 0 ? cyan : coral }
    static func accent(at index: Int) -> Color { index % 2 == 0 ? cyan : coral }
}

/// A progress bar in the rails' gradient: a share when known, else a short gradient band sweeping across (still under Reduce Motion)
struct NX18Bar: View {
    var value: Double?
    var height: CGFloat = 6
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sweep = false

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.12))
                if let value {
                    Capsule().fill(NX18Palette.brand).frame(width: max(height, g.size.width * min(max(value, 0), 1)))
                        .animation(.snappy, value: value)
                } else {
                    Capsule().fill(NX18Palette.brand).frame(width: g.size.width * 0.3)
                        .offset(x: reduceMotion ? g.size.width * 0.35 : (sweep ? g.size.width * 0.7 : 0))
                        .onAppear { if !reduceMotion { withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { sweep = true } } }
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue(value.map { "\(Int(($0 * 100).rounded())) percent" } ?? "In progress")
    }
}
