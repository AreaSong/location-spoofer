import SwiftUI

extension MapHomeView {
    @ViewBuilder
    var signingExpiryHomeNotice: some View {
        if let expiration = signingExpiryStatus.expirationDate,
           case .remaining = signingExpiryStatus.kind {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                signingExpiryNotice(expiration: expiration, now: context.date)
            }
        }
    }

    @ViewBuilder
    func signingExpiryNotice(expiration: Date, now: Date) -> some View {
        let status = SigningExpiry.evaluate(expirationDate: expiration, now: now)
        let countdown = SigningExpiryCountdown.text(until: expiration, now: now)
        let showsBanner = status.showsMapBanner
            && !signingExpiryBanner.isBannerDismissed(expirationDate: expiration, now: now)
        if case .remaining = status.kind, let countdown {
            if showsBanner {
                signingExpiryBannerView(
                    countdown: countdown,
                    detail: "到期后需要重新签名安装。",
                    expiration: expiration,
                    now: now
                )
            } else {
                signingExpiryCountdownChip(countdown, urgent: status.showsMapBanner)
            }
        }
    }

    func signingExpiryCountdownChip(_ text: String, urgent: Bool) -> some View {
        HStack {
            Button {
                showSigningResignSheet = true
            } label: {
                Label(text, systemImage: "clock")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(urgent ? Color.orange : Color.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
            .accessibilityHint("打开重新签名说明")
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.13), radius: 9, y: 4)
            Spacer(minLength: 0)
        }
    }

    func signingExpiryBannerView(
        countdown: String,
        detail: String,
        expiration: Date,
        now: Date
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                showSigningResignSheet = true
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Label(countdown, systemImage: "clock")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .buttonStyle(.plain)
            .accessibilityHint("打开重新签名说明")
            HStack {
                Button("如何重签") {
                    showSigningResignSheet = true
                }
                .font(.footnote.weight(.semibold))
                .frame(minHeight: 44)
                Button("今天不再提示") {
                    signingExpiryBanner.dismissBanner(expirationDate: expiration, now: now)
                }
                .font(.footnote.weight(.semibold))
                .frame(minHeight: 44)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous))
    }
}
