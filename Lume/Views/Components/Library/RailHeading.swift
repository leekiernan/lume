import SwiftUI

/// A rail's existing collection destination belongs to its leading title, not
/// a second focus target at the trailing edge. No destination means plain text.
struct RailHeading<Destination: Hashable>: View {
    let title: Text
    let destination: Destination?
    var onLeadingLeft: (() -> Void)?

    var body: some View {
        Group {
            if let destination {
                NavigationLink(value: destination) {
                    HStack(spacing: iconSpacing) {
                        title
                        ReadMoreIcon()
                            .frame(width: iconSize, height: iconSize)
                            .accessibilityHidden(true)
                    }
                    .railHeadingStyle()
                    .contentShape(Rectangle())
                }
                .buttonStyle(RailHeadingLinkStyle())
                .accessibilityLabel(title)
                .accessibilityHint(Text("Show All"))
                .onLeadingEdgeLeft(onLeadingLeft)
            } else {
                title.railHeadingStyle()
            }
        }
        .accessibilityAddTraits(.isHeader)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var iconSize: CGFloat {
        #if os(tvOS)
            48
        #else
            32
        #endif
    }

    private var iconSpacing: CGFloat {
        #if os(tvOS)
            16
        #else
            12
        #endif
    }
}

/// A focus fill without scale or padding changes keeps vertical navigation on
/// the title's leading edge and leaves the rail's scroll geometry unchanged.
private struct RailHeadingLinkStyle: ButtonStyle {
    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isFocused ? Color.primary.opacity(0.18) : .clear)
                    .padding(.horizontal, -8)
                    .padding(.vertical, -4)
            }
    }
}
