import SwiftUI

/// Available connected-account lists. Adding one makes it an ordinary section
/// in this area's layout, under its default title: renaming, reordering,
/// visibility and hero are the Sections list's, as for any section, so this
/// catalogue keeps no state of its own.
struct AuthenticatedSectionSources: View {
    let surface: SectionSurface
    @Binding var customSectionsRaw: String
    var isReordering = false

    @State private var trakt = TraktService.shared

    init(surface: SectionSurface, customSectionsRaw: Binding<String>, isReordering: Bool = false) {
        self.surface = surface
        _customSectionsRaw = customSectionsRaw
        self.isReordering = isReordering
    }

    var body: some View {
        if trakt.isConnected {
            ForEach(AuthenticatedHomeList.allCases) { source in
                sourceRow(source)
                    .disabled(isReordering)
            }
        }
    }

    private var sections: [CustomHomeSection] {
        CustomHomeSections.decode(customSectionsRaw)
    }

    private func existing(_ source: AuthenticatedHomeList) -> CustomHomeSection? {
        sections.first { $0.authenticatedList == source }
    }

    /// The section's own title once added; the default until then.
    private func title(_ source: AuthenticatedHomeList) -> String {
        existing(source)?.title ?? source.defaultTitle
    }

    private func canAdd(_ source: AuthenticatedHomeList) -> Bool {
        existing(source) == nil && sections.count < CustomHomeSections.maximumCount
    }

    @ViewBuilder
    private func sourceRow(_ source: AuthenticatedHomeList) -> some View {
        let title = title(source)
        let isAdded = existing(source) != nil
        #if os(tvOS)
            // One focus stop: the row adds the section, and once added says so.
            Button { add(source) } label: {
                HStack {
                    Label(title, systemImage: "list.bullet.rectangle")
                        .labelStyle(TVSettingsIconLabelStyle())
                    Spacer(minLength: 12)
                    Image(systemName: isAdded ? "checkmark" : "plus")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(TVSettingsRowButtonStyle())
            .disabled(!canAdd(source))
            .accessibilityLabel(isAdded ? Text(verbatim: title) : Text("Add \(title)"))
        #else
            HStack(spacing: 14) {
                Label(title, systemImage: "list.bullet.rectangle")
                Spacer(minLength: 12)
                Button { add(source) } label: {
                    Image(systemName: isAdded ? "checkmark" : "plus")
                }
                .buttonStyle(.borderless)
                .disabled(!canAdd(source))
                .accessibilityLabel(isAdded ? Text(verbatim: title) : Text("Add \(title)"))
                .fixedSize()
            }
        #endif
    }

    private func add(_ source: AuthenticatedHomeList) {
        guard trakt.isConnected, canAdd(source) else { return }
        customSectionsRaw = CustomHomeSections.encode(CustomHomeSections.upsert(
            source.section(title: source.defaultTitle, surface: surface), into: sections
        ))
    }
}
