import SwiftUI

/// The popover's type ramp, in one place.
///
/// Before this existed the popover mixed two font systems: semantic styles
/// (.callout, .headline, .subheadline, .caption2) that track the macOS
/// system text size, and hardcoded points (12.5, 11.5, 10.5) that do not.
/// A row built from one kind grew when the system setting changed while a
/// row built from the other stayed put, so the two densities drifted apart
/// on any Mac that was not at the default text size.
///
/// Every case below records the size the popover renders TODAY, semantic
/// styles resolved to their macOS point values, so adopting the ramp is a
/// refactor with no visual change. `swarmScale` then gives one knob that
/// moves all of it together.
///
/// Deliberately out of scope: SettingsView, which is an ordinary macOS
/// settings window and should keep using system semantic styles, and
/// MenuBarLabel, whose size is dictated by the menu bar's height rather
/// than by preference.
///
/// Eighteen roles looks like a lot for a 380pt popover, and an earlier
/// version of this comment called it inherited duplication. That was
/// wrong, so before consolidating anything, know what was checked:
/// no two roles share a (size, weight, design) triple, so there is
/// nothing mechanically redundant to merge; the eight distinct sizes come
/// straight from swarmbar-prototype.html, half points included (it uses
/// 10, 10.5, 11, 11.5, 12, 12.5, 13, 14, 15). The prototype is the design
/// spec, so collapsing the ramp would be a deliberate divergence FROM the
/// spec, not a cleanup toward it. Change the prototype first.
enum SwarmText: CaseIterable {
    /// "SwarmBar" in the popover header.
    case title
    /// Project name on a comfortable row. Was `.headline`, which measures
    /// as 13 BOLD on macOS rather than the semibold it is often assumed to
    /// be, so this is deliberately heavier than `rowTitle`.
    case rowTitleStrong
    /// The reply composer's session name.
    case rowTitle
    /// Project name on a compact row.
    case rowTitleCompact
    /// Status text, summary line, activity, footer actions.
    case body
    /// Approve / Deny / Reply pill labels.
    case bodyEmphasis
    /// The reply composer's text editor.
    case editor
    /// Status and activity text on a compact row.
    case detail
    /// Elapsed timers.
    case meta
    /// "Working · Claude Code" on a comfortable row.
    case metaEmphasis
    /// "Needs you" / "Active" / "Recent".
    case sectionHeader
    /// The command in an approval card.
    case mono
    /// The command on a compact approval row.
    case monoCompact
    /// Secondary explanatory text in the composer.
    case caption
    /// Account label chip.
    case captionEmphasis
    /// Bare `.caption2`, which measures as 10 MEDIUM on macOS.
    case captionMedium
    /// Header icon buttons (compact toggle, pause).
    case icon
    /// The 20pt approve/deny/reply buttons on a compact row.
    case iconSmall

    var size: CGFloat {
        switch self {
        case .title:            14
        case .rowTitleStrong:   13
        case .rowTitle:         13
        case .rowTitleCompact:  12.5
        case .body:             12
        case .bodyEmphasis:     12
        case .editor:           12.5
        case .detail:           11.5
        case .meta:             11
        case .metaEmphasis:     11
        case .sectionHeader:    11
        case .mono:             11
        case .monoCompact:      10.5
        case .caption:          10
        case .captionEmphasis:  10
        case .captionMedium:    10
        case .icon:             12
        case .iconSmall:        10
        }
    }

    var weight: Font.Weight {
        switch self {
        case .title:            .bold
        case .rowTitleStrong:   .bold
        case .sectionHeader:    .bold
        case .iconSmall:        .bold
        case .rowTitle:         .semibold
        case .rowTitleCompact:  .semibold
        case .bodyEmphasis:     .semibold
        case .metaEmphasis:     .semibold
        case .captionEmphasis:  .semibold
        case .icon:             .medium
        case .captionMedium:    .medium
        default:                .regular
        }
    }

    var design: Font.Design {
        switch self {
        case .mono, .monoCompact: .monospaced
        default:                  .default
        }
    }

    var font: Font {
        .system(size: size, weight: weight, design: design)
    }
}

/// The popover's overall size, exposed in Settings as Text size.
///
/// This deliberately scales the whole surface, not just the type. The
/// popover is a fixed 380pt frame, so growing the text alone would spend
/// the extra size on truncation: the first casualty is the monospaced
/// command in an approval row, which is the one thing that must never be
/// abbreviated. Width, icon chips, and the project-name column all move by
/// the same factor, so the layout keeps its proportions and only the
/// physical size changes.
///
/// Independent of Compact rows, which controls density (how much vertical
/// room a session takes) rather than legibility. Compact plus large is a
/// deliberately supported combination: many sessions, still readable.
///
/// What scales and what does not: content dimensions move (width, type,
/// icon chips, the project-name column, the composer's editor, the scroll
/// cap), while padding and inter-element spacing stay fixed. That keeps
/// the two settings cleanly separated, since gutters are exactly what
/// Compact rows is for, and it stops the popover from ballooning at large.
enum PopoverScale: String, CaseIterable, Identifiable {
    case small, medium, large

    var id: String { rawValue }

    /// Medium is 1.0 by definition: it is the size the HTML prototype
    /// specifies, and the size every `SwarmText` case records.
    var factor: CGFloat {
        switch self {
        case .small:  0.9
        case .medium: 1.0
        case .large:  1.15
        }
    }

    var label: String {
        switch self {
        case .small:  "Small"
        case .medium: "Medium"
        case .large:  "Large"
        }
    }

    /// Tolerates a missing or garbage stored value rather than trapping,
    /// since this comes straight from user defaults.
    static func stored(_ raw: String) -> PopoverScale {
        PopoverScale(rawValue: raw) ?? .medium
    }
}

extension EnvironmentValues {
    /// Multiplies every `SwarmText` size and every fixed dimension in the
    /// popover. See `PopoverScale` for why both move together.
    @Entry var swarmScale: CGFloat = 1.0
}

extension View {
    func swarmFont(_ role: SwarmText) -> some View {
        modifier(SwarmFontModifier(role: role))
    }
}

private struct SwarmFontModifier: ViewModifier {
    @Environment(\.swarmScale) private var scale
    let role: SwarmText

    func body(content: Content) -> some View {
        content.font(
            .system(size: role.size * scale, weight: role.weight, design: role.design)
        )
    }
}
