import AppKit
import SwiftUI
import Testing
@testable import SwarmBar

/// The ramp exists to make one scale knob possible without changing how
/// the popover renders today. These lock the table, because a wrong point
/// size or weight here is invisible in code review and only shows up as a
/// row that no longer matches the HTML prototype.
@MainActor
struct TypographyTests {
    /// The two that were actually wrong on the first pass, both found by
    /// measuring rendered text rather than by reading the code. `.headline`
    /// resolves to 13 BOLD on macOS, not the semibold it is usually assumed
    /// to be, and a bare `.caption2` resolves to MEDIUM, not regular.
    @Test func theWeightsThatAreEasyToGetWrong() {
        #expect(SwarmText.rowTitleStrong.size == 13)
        #expect(SwarmText.rowTitleStrong.weight == .bold)
        #expect(SwarmText.captionMedium.size == 10)
        #expect(SwarmText.captionMedium.weight == .medium)
    }

    /// `rowTitle` and `rowTitleStrong` are the same size and differ only in
    /// weight. Collapsing them would quietly lighten every project name on
    /// a comfortable row.
    @Test func theTwoRowTitlesAreDistinct() {
        #expect(SwarmText.rowTitle.size == SwarmText.rowTitleStrong.size)
        #expect(SwarmText.rowTitle.weight != SwarmText.rowTitleStrong.weight)
    }

    @Test func onlyTheCommandRolesAreMonospaced() {
        for role in SwarmText.allCases {
            let expected: Font.Design = (role == .mono || role == .monoCompact)
                ? .monospaced : .default
            #expect(role.design == expected, "\(role) has the wrong design")
        }
    }

    /// Guards the whole table at once. Update deliberately, with a
    /// screenshot check, never to make a build pass.
    @Test func theRampIsUnchanged() {
        let expected: [SwarmText: CGFloat] = [
            .title: 14, .rowTitleStrong: 13, .rowTitle: 13, .rowTitleCompact: 12.5,
            .body: 12, .bodyEmphasis: 12, .editor: 12.5, .detail: 11.5,
            .meta: 11, .metaEmphasis: 11, .sectionHeader: 11, .mono: 11,
            .monoCompact: 10.5, .caption: 10, .captionEmphasis: 10,
            .captionMedium: 10, .icon: 12, .iconSmall: 10,
        ]
        #expect(expected.count == SwarmText.allCases.count)
        for role in SwarmText.allCases {
            #expect(role.size == expected[role], "\(role) changed size")
        }
    }

    /// Scale is a multiplier on the ramp, so the ratios between roles have
    /// to survive it. If this ever fails, larger text is not just larger,
    /// it is a different design.
    @Test func scalingPreservesProportions() {
        for scale in [0.9, 1.0, 1.15] as [CGFloat] {
            let title = SwarmText.title.size * scale
            let caption = SwarmText.caption.size * scale
            #expect(abs(title / caption - 1.4) < 0.0001)
        }
    }

    // MARK: - Popover scale

    @Test func mediumIsExactlyTheDesignedSize() {
        // Medium must be 1.0, or the ramp above no longer describes what
        // ships by default and the prototype comparison is meaningless.
        #expect(PopoverScale.medium.factor == 1.0)
    }

    @Test func theStepsAreOrderedAndDistinct() {
        #expect(PopoverScale.small.factor < PopoverScale.medium.factor)
        #expect(PopoverScale.medium.factor < PopoverScale.large.factor)
    }

    /// A garbage or absent stored value must fall back, never trap: this
    /// reads straight out of user defaults.
    @Test func storedValuesDegradeToMedium() {
        #expect(PopoverScale.stored("large") == .large)
        #expect(PopoverScale.stored("") == .medium)
        #expect(PopoverScale.stored("enormous") == .medium)
    }

    /// Renders a real row and measures its HEIGHT at each scale.
    ///
    /// Height, not width: a compact row's height is set by its tallest
    /// fixed element (the 20pt approve/deny buttons, the 18pt tool chip),
    /// so it moves only if those frames actually multiply by the scale.
    /// Width was tried first and proved worthless as a check, because the
    /// type scales on its own and the row got wider even with every frame
    /// multiplication deleted. The negative control is the point: this
    /// test is only worth having if removing a `* scale` makes it fail.
    @Test func theScaleReachesTheRowsFixedDimensions() {
        let session = AgentSession(
            tool: .claudeCode, projectName: "swarmbar",
            status: .waitingApproval(command: "rm -rf /tmp/x"))
        let store = SessionStore()
        store.upsert(session)

        func height(_ scale: PopoverScale) -> CGFloat {
            let view = CompactSessionRow(session: session)
                .environment(store)
                .environment(\.swarmScale, scale.factor)
            return NSHostingView(rootView: view).fittingSize.height
        }

        let medium = height(.medium), large = height(.large)
        // 20pt buttons at 1.15 are 23pt, so the row has to grow by about
        // 3pt. Font growth alone moves it by less than one point.
        #expect(large - medium >= 2, "fixed dimensions are not scaling (grew \(large - medium)pt)")
    }
}
