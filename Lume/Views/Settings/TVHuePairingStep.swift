//
//  TVHuePairingStep.swift
//  Lume
//
//  The tvOS Philips Hue pane's pairing step, shown in place of the pane's top
//  level (see TVHueSettingsPane). The work is `HuePairingModel`'s.
//

#if os(tvOS)

    import SwiftUI

    struct TVHuePairingStep: View {
        let target: HuePairingTarget?
        let onPaired: () -> Void
        let onCancel: () -> Void

        @State private var model = HuePairingModel()
        @State private var pairing: Task<Void, Never>?
        @State private var identification: Task<Void, Never>?
        @FocusState private var focus: Field?

        private enum Field: Hashable {
            case address
            case pair
            case cancel
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 16) {
                TVSettingsSectionLabel("settings.hue.pairing.title")

                if target == nil, model.bridgeName == nil {
                    addressInput
                }

                if let bridgeName = model.bridgeName {
                    TVSettingsValueRow("settings.hue.bridge", value: bridgeName)
                    linkButtonStep
                } else if model.isIdentifying {
                    HStack(spacing: 16) {
                        ProgressView()
                        Text(String(localized: "settings.hue.pairing.connecting", defaultValue: "Connecting…"))
                            .foregroundStyle(.secondary)
                    }
                    .font(.system(size: TVSettingsMetrics.rowFontSize))
                    .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                }

                if let errorMessage = model.errorMessage {
                    Text(verbatim: errorMessage)
                        .font(.system(size: TVSettingsMetrics.explanatoryFontSize))
                        .foregroundStyle(.red)
                        .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                }

                Button("settings.hue.pairing.cancel", action: cancel)
                    .buttonStyle(TVSettingsActionButtonStyle())
                    .focused($focus, equals: .cancel)
                    .padding(.top, 8)
            }
            .task {
                if let target {
                    Task { @MainActor in focus = .cancel }
                    if await model.identify(target) {
                        Task { @MainActor in focus = .pair }
                    }
                } else {
                    Task { @MainActor in focus = .address }
                }
            }
            .onDisappear { cancelWork() }
        }

        private var addressInput: some View {
            VStack(alignment: .leading, spacing: 16) {
                TVSettingsField(
                    title: "settings.hue.address.title",
                    placeholder: "settings.hue.address.placeholder",
                    text: $model.address,
                    contentType: .URL
                )
                .keyboardType(.numbersAndPunctuation)
                .focused($focus, equals: .address)
                .onSubmit { connectToAddress() }
                .onChange(of: model.address) {
                    identification?.cancel()
                    model.addressDidChange()
                }

                Text(String(
                    localized: "settings.hue.address.footer",
                    defaultValue: "The bridge's IP address, shown in the Hue app under Settings › Bridges."
                ))
                .tvSettingsFooter()

                Button(action: connectToAddress) {
                    SettingsActionLabel(title: "settings.hue.address.connect", systemImage: "network", isBusy: model.isIdentifying)
                }
                .buttonStyle(TVSettingsRowButtonStyle())
                .disabled(trimmedAddress.isEmpty || model.isIdentifying)
            }
        }

        private var linkButtonStep: some View {
            VStack(alignment: .leading, spacing: 16) {
                Text(String(
                    localized: "settings.hue.pairing.instructions",
                    defaultValue: "Press the round link button on top of the Hue Bridge, then select Pair within 30 seconds."
                ))
                .tvSettingsFooter()

                Button(action: startPairing) {
                    HStack(spacing: 16) {
                        Label {
                            Text(verbatim: pairTitle)
                        } icon: {
                            Image(systemName: "link")
                        }
                        .labelStyle(TVSettingsIconLabelStyle())
                        if model.isWaitingForLinkButton { ProgressView() }
                    }
                }
                .buttonStyle(TVSettingsRowButtonStyle())
                .focused($focus, equals: .pair)
            }
        }

        private var pairTitle: String {
            if model.isWaitingForLinkButton {
                String(localized: "settings.hue.pairing.waiting", defaultValue: "Waiting for the Link Button…")
            } else if model.errorMessage != nil {
                String(localized: "settings.hue.pairing.retry", defaultValue: "Try Again")
            } else {
                String(localized: "settings.hue.pairing.pair", defaultValue: "Pair")
            }
        }

        private var trimmedAddress: String {
            model.address.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        private func connectToAddress() {
            let host = trimmedAddress
            guard !host.isEmpty, !model.isIdentifying else { return }
            identification = Task {
                if await model.identify(HuePairingTarget(host: host, bridgeID: nil)) {
                    // Let the keyboard release focus before landing on Pair.
                    do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                    guard model.bridgeName != nil else { return }
                    focus = .pair
                }
            }
        }

        private func startPairing() {
            guard !model.isBusy else { return }
            pairing = Task {
                if await model.pair() {
                    onPaired()
                }
            }
        }

        private func cancel() {
            cancelWork()
            onCancel()
        }

        private func cancelWork() {
            model.cancel()
            identification?.cancel()
            pairing?.cancel()
        }
    }

#endif
