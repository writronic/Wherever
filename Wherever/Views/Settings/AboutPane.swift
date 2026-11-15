import AppKit
import Foundation
import SwiftUI

struct AboutPane: View {
    let open: (URL) -> Void
    var metrics = Metrics.settings
    @AppStorage(TextSize.key) private var textSize = TextSize.standard

    struct Metrics {
        let top: CGFloat
        let iconToName: CGFloat
        let nameToVersion: CGFloat
        let versionToDescription: CGFloat
        let descriptionToMadeWith: CGFloat
        let madeWithToCopyright: CGFloat
        let copyrightToButtons: CGFloat
        let buttonsToLicence: CGFloat
        let versionSize: CGFloat
        let descriptionSize: CGFloat
        let madeWithSize: CGFloat
        let copyrightSize: CGFloat
        let buttonSize: CGFloat
        let licenceSize: CGFloat

        static let iconSize: CGFloat = 96
        static let iconCorner: CGFloat = 20
        static let nameSize: CGFloat = 24
        static let buttonSpacing: CGFloat = 10
        static let stackedButtonSpacing: CGFloat = 8

        static let settings = Metrics(
            top: 24, iconToName: 16, nameToVersion: 10, versionToDescription: 8, descriptionToMadeWith: 40,
            madeWithToCopyright: 16, copyrightToButtons: 18, buttonsToLicence: 40,
            versionSize: 14, descriptionSize: 14, madeWithSize: 16, copyrightSize: 14, buttonSize: 13, licenceSize: 14
        )
        static let window = Metrics(
            top: 20, iconToName: 14, nameToVersion: 14, versionToDescription: 6, descriptionToMadeWith: 38,
            madeWithToCopyright: 6, copyrightToButtons: 14, buttonsToLicence: 33,
            versionSize: 13, descriptionSize: 12, madeWithSize: 14, copyrightSize: 12, buttonSize: 12, licenceSize: 12
        )
    }

    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "" }

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: Metrics.iconSize, height: Metrics.iconSize)
                .clipShape(RoundedRectangle(cornerRadius: Metrics.iconCorner))
                .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
                .accessibilityHidden(true)
            Text(verbatim: "Wherever")
                .font(textSize.font(size: Metrics.nameSize, weight: .bold, design: .rounded))
                .padding(.top, metrics.iconToName)
            Text("Version \(version)", tableName: "Settings")
                .font(textSize.font(size: metrics.versionSize)).foregroundStyle(.secondary)
                .padding(.top, metrics.nameToVersion)
            Text("Wherever it is, find it.", tableName: "Welcome")
                .font(textSize.font(size: metrics.descriptionSize)).foregroundStyle(.secondary)
                .padding(.top, metrics.versionToDescription)
            Text("Made with ❤️", tableName: "Settings")
                .font(textSize.font(size: metrics.madeWithSize, weight: .semibold))
                .padding(.top, metrics.descriptionToMadeWith)
            Text("Copyright © 2026 Writronic. All rights reserved.", tableName: "Settings")
                .font(textSize.font(size: metrics.copyrightSize)).foregroundStyle(.secondary)
                .padding(.top, metrics.madeWithToCopyright)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Metrics.buttonSpacing) { buttons }
                VStack(spacing: Metrics.stackedButtonSpacing) { buttons }
            }
            .font(textSize.font(size: metrics.buttonSize))
            .padding(.top, metrics.copyrightToButtons)
            Text(verbatim: "GPL-3.0-or-later")
                .font(textSize.font(size: metrics.licenceSize)).foregroundStyle(.tertiary)
                .padding(.top, metrics.buttonsToLicence)
        }
        .multilineTextAlignment(.center)
        .padding(.top, metrics.top)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var buttons: some View {
        Button { open(AppLinks.website) } label: { Text("Visit Website", tableName: "Settings") }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("about-website")
        Button {
            open(AppLinks.donate)
        } label: {
            Label { Text("Donate", tableName: "Settings") } icon: { Image(systemName: "heart.fill") }
        }
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier("about-donate")
    }
}
