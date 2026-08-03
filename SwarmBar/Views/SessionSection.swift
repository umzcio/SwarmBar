import SwiftUI

/// A section renders nothing at all when it has no rows; an orange label
/// with nothing to show (or worse, a mascot line) is noise. The header's
/// count line already answers the at-a-glance question.
struct SessionSection: View {
    enum Emphasis { case normal, attention }

    let title: String
    let emphasis: Emphasis
    let sessions: [AgentSession]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("compactRows") private var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title.uppercased())
                .font(.subheadline.weight(.bold))
                .kerning(0.6)
                .foregroundStyle(emphasis == .attention ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
                .padding(.horizontal, 16)
                .padding(.top, compact ? 6 : 8)
                .padding(.bottom, compact ? 3 : 5)

            ForEach(sessions) { session in
                Group {
                    if compact {
                        CompactSessionRow(session: session)
                    } else {
                        SessionRow(session: session)
                    }
                }
                .padding(.horizontal, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: sessions.map(\.id))
    }
}
