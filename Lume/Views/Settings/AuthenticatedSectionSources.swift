import SwiftUI

/// Available connected-account lists. Adding one makes it an ordinary section
/// in this area's layout; this catalogue itself has no visibility/hero controls.
struct AuthenticatedSectionSources: View {
    let surface: SectionSurface
    @Binding var customSectionsRaw: String
    var isReordering = false

    @AppStorage private var titlesRaw: String
    @State private var trakt = TraktService.shared
    @State private var editing: AuthenticatedHomeList?
    @State private var draftTitle = ""

    init(surface: SectionSurface, customSectionsRaw: Binding<String>, isReordering: Bool = false) {
        self.surface = surface
        _customSectionsRaw = customSectionsRaw
        self.isReordering = isReordering
        _titlesRaw = AppStorage(wrappedValue: "", AuthenticatedHomeLists.titlesKey(surface))
    }

    var body: some View {
        if trakt.isConnected {
            ForEach(AuthenticatedHomeList.allCases) { source in
                VStack(alignment: .leading, spacing: 12) {
                    sourceRow(source)
                    if editing == source { titleEditor(source) }
                }
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

    private func title(_ source: AuthenticatedHomeList) -> String {
        existing(source)?.title ?? AuthenticatedHomeLists.title(for: source, raw: titlesRaw)
    }

    private func sourceRow(_ source: AuthenticatedHomeList) -> some View {
        let title = title(source)
        return HStack(spacing: 14) {
            #if os(tvOS)
                Button { beginEditing(source) } label: {
                    Label(title, systemImage: "list.bullet.rectangle")
                        .labelStyle(TVSettingsIconLabelStyle())
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(TVSettingsRowButtonStyle())
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)
            #else
                Label(title, systemImage: "list.bullet.rectangle")
                Spacer(minLength: 12)
            #endif

            Button { beginEditing(source) } label: {
                Image(systemName: "pencil")
            }
            .accessibilityLabel("Edit \(title)")
            .fixedSize()

            Button { add(source) } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel("Add \(title)")
            .disabled(existing(source) != nil || sections.count >= CustomHomeSections.maximumCount)
            .fixedSize()
        }
        #if os(tvOS)
        .buttonStyle(TVContentIconButtonStyle())
        #else
        .buttonStyle(.borderless)
        #endif
    }

    private func titleEditor(_ source: AuthenticatedHomeList) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            #if os(tvOS)
                TVSettingsField(title: "Title", placeholder: "Section title", text: $draftTitle, requestsFocusOnAppear: true)
            #else
                TextField("Title", text: $draftTitle, prompt: Text(verbatim: source.defaultTitle))
            #endif
            HStack {
                Button("Save") { saveTitle(source) }
                Button("Cancel") { editing = nil }
            }
            #if os(tvOS)
            .buttonStyle(TVSettingsRowButtonStyle())
            #else
            .buttonStyle(.borderless)
            #endif
        }
    }

    private func beginEditing(_ source: AuthenticatedHomeList) {
        draftTitle = title(source)
        editing = source
    }

    private func saveTitle(_ source: AuthenticatedHomeList) {
        guard trakt.isConnected else { return }
        titlesRaw = AuthenticatedHomeLists.settingTitle(draftTitle, for: source, raw: titlesRaw)
        if var section = existing(source) {
            section.title = AuthenticatedHomeLists.title(for: source, raw: titlesRaw)
            customSectionsRaw = CustomHomeSections.encode(CustomHomeSections.upsert(section, into: sections))
        }
        editing = nil
    }

    private func add(_ source: AuthenticatedHomeList) {
        guard trakt.isConnected, existing(source) == nil else { return }
        customSectionsRaw = CustomHomeSections.encode(CustomHomeSections.upsert(
            source.section(title: title(source), surface: surface), into: sections
        ))
    }
}
