//
//  SettingsView+Premium.swift
//  Lume
//
//  The Lume Pro surfaces in Settings: the shared paywall helpers, the
//  status / upgrade row that sits first in the iOS/macOS list, the DEBUG-only
//  developer override, and the tvOS Premium pane. Split out of SettingsView to
//  keep that file within the project's line-count cap.
//

import SwiftUI

extension SettingsView {
    /// Sets the highlighted feature and presents the paywall.
    func presentPaywall(_ feature: PremiumFeature? = nil) {
        paywallHighlight = feature
        showPaywall = true
    }

    /// Whether a new playlist can be added for free (first playlist always free).
    var canAddPlaylist: Bool {
        premium.isPremium || playlists.isEmpty
    }

    /// Which plan is unlocking Premium — the headline of the status row.
    var premiumPlanTitle: String {
        #if !SIDE_LOAD
            // A lifetime unlock outranks a subscription: it can't lapse, so that's the
            // more useful thing to show if someone somehow holds both. The retired
            // non-consumable is lifetime access too — it just never renewed.
            if premium.owns(.lifetime) || premium.owns(.retiredMonthly) {
                return String(localized: "Lifetime access")
            }
            if premium.owns(.monthly) { return String(localized: "Monthly subscription") }
        #endif
        return String(localized: "All features unlocked")
    }

    /// Billing line under the plan title: the next charge date, the cut-off date once
    /// cancelled, or a prompt to fix a failed payment. Nil for anything that doesn't
    /// renew, so lifetime owners never see a billing date.
    var premiumRenewalDetail: String? {
        guard premium.owns(.monthly), let status = premium.subscriptionStatus else { return nil }
        if status.isInBillingRetry {
            return String(localized: "Payment issue — update your payment method")
        }
        guard let renewsAt = status.renewsAt else { return nil }
        let date = renewsAt.formatted(date: .abbreviated, time: .omitted)
        let format = status.willAutoRenew
            ? String(localized: "Renews %@")
            : String(localized: "Ends %@")
        return String(format: format, date)
    }

    /// Plan and billing state on one line, for the tvOS pane's single subtitle slot.
    var premiumStatusDetail: String {
        guard let detail = premiumRenewalDetail else { return premiumPlanTitle }
        return "\(premiumPlanTitle) · \(detail)"
    }
}

#if !os(tvOS)

    extension SettingsView {
        /// The first row in Settings: current Premium status, or a tap-to-upgrade
        /// prompt for free users.
        var premiumStatusSection: some View {
            Section {
                if premium.isPremium {
                    HStack(spacing: 12) {
                        Image(systemName: "crown")
                            .foregroundStyle(.tint)
                            .font(.title3)
                            .frame(width: 30)
                        VStack(alignment: .leading, spacing: 1) {
                            // The plan, not the product name — the section header
                            // already says "Lume Pro".
                            Text(premiumPlanTitle)
                            if let premiumRenewalDetail {
                                Text(premiumRenewalDetail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 2)

                    // Subscribers must always have a route to cancel; lifetime owners
                    // have nothing to manage, so they don't get this row.
                    if premium.hasManageableSubscription {
                        ManageSubscriptionRow()
                    }
                } else {
                    Button {
                        presentPaywall(nil)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "crown")
                                .foregroundStyle(.tint)
                                .font(.title3)
                                .frame(width: 30)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Unlock lume Pro")
                                    .foregroundStyle(.primary)
                                Text("Free plan · See what's included")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            } header: {
                // Not "Subscription" — lifetime owners see this section too, and
                // labelling a one-time purchase a subscription is what sent people
                // hunting for a cancel button that couldn't exist.
                Text("lume Pro")
            }
        }

        #if DEBUG && !SIDE_LOAD
            /// DEBUG-only override to preview the free tier and the paywall without
            /// archiving a Release build.
            var developerSection: some View {
                Section {
                    Toggle("Force Premium", isOn: Binding(
                        get: { premium.debugForcePremium },
                        set: { premium.debugForcePremium = $0 }
                    ))

                    Button("Recalculate Recommendations") {
                        RecommendationCacheStore().clear(for: ActiveProfileStore.current)
                        recommendationsRecalcToken += 1
                    }
                } header: {
                    Text("Developer")
                } footer: {
                    Text("DEBUG only. Force Premium previews the free tier and paywall. Recalculate rebuilds the For You row now, bypassing the once-a-day throttle.")
                }
            }
        #endif
    }

#endif

#if os(tvOS)

    extension SettingsView {
        /// The tvOS Premium pane: status, the upgrade / restore / manage
        /// actions, then the full benefits list.
        ///
        /// The actions lead and every feature is a focusable row: a tvOS scroll
        /// view only moves with focus, so a list of plain text below or above
        /// the only buttons couldn't be read to its end — and a subscriber, with
        /// no buttons at all, couldn't scroll it.
        var tvPremiumDetail: some View {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 8) {
                    TVSettingsSummary(
                        systemImage: "crown", title: Text(premium.isPremium ? "lume Pro" : "Free Plan"),
                        detail: Text(premium.isPremium ? premiumStatusDetail : String(localized: "Upgrade to unlock the features below"))
                    )
                }

                if premium.hasManageableSubscription {
                    ManageSubscriptionRow()
                        .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                }

                if !premium.isPremium {
                    VStack(alignment: .leading, spacing: 8) {
                        Button {
                            presentPaywall(nil)
                        } label: {
                            Label("Upgrade to Premium", systemImage: "crown")
                                .labelStyle(TVSettingsIconLabelStyle())
                        }
                        .buttonStyle(TVSettingsRowButtonStyle())

                        Button {
                            Task { await premium.restore() }
                        } label: {
                            Label("Restore Purchases", systemImage: "arrow.clockwise")
                                .labelStyle(TVSettingsIconLabelStyle())
                        }
                        .buttonStyle(TVSettingsRowButtonStyle())
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    TVSettingsSectionLabel(premium.isPremium ? "Included" : "Premium Features")
                    ForEach(PremiumFeature.availableOnThisPlatform) { feature in
                        TVPremiumFeatureRow(feature: feature, isPremium: premium.isPremium) {
                            presentPaywall(feature)
                        }
                    }
                }
            }
        }
    }

    /// One benefit: a button to the paywall on that feature for a free user,
    /// a focusable row for a subscriber so the list still scrolls.
    private struct TVPremiumFeatureRow: View {
        let feature: PremiumFeature
        let isPremium: Bool
        let showPaywall: () -> Void
        @FocusState private var isFocused: Bool

        var body: some View {
            if isPremium {
                label
                    .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                    .padding(.vertical, TVSettingsMetrics.rowVPadding)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: TVSettingsMetrics.rowCornerRadius, style: .continuous)
                            .fill(isFocused ? .white.opacity(0.14) : .clear)
                    )
                    .accessibilityElement(children: .combine)
                    .focusable()
                    .focused($isFocused)
                    .animation(.easeOut(duration: 0.15), value: isFocused)
            } else {
                Button(action: showPaywall) { label }
                    .buttonStyle(TVSettingsRowButtonStyle())
            }
        }

        private var label: some View {
            HStack(alignment: .top, spacing: 18) {
                Image(systemName: feature.systemImage)
                    .font(.system(size: 26))
                    .foregroundStyle(TVSettingsAccentStyle())
                    .frame(width: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(feature.title).font(.system(size: 24, weight: .semibold))
                    Text(feature.subtitle)
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
    }

#endif
