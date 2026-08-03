import SwiftUI

struct SessionSection: View {
    enum Emphasis { case normal, attention }

    let title: String
    let emphasis: Emphasis
    let sessions: [AgentSession]
    var emptyText: String? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title.uppercased())
                .font(.subheadline.weight(.bold))
                .kerning(0.6)
                .foregroundStyle(emphasis == .attention ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 5)

            if sessions.isEmpty, let emptyText {
                Text(emptyText)
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 4)
            }

            ForEach(sessions) { session in
                SessionRow(session: session)
                    .padding(.horizontal, 8)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: sessions.map(\.id))
    }
}
