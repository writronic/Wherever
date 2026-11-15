import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import WhereverInterface

struct LocationsPane: View {
    static let newDiskID = "locations-new-disk"
    static let notificationsOffID = "locations-notifications-off"

    @ObservedObject var model: LocationsModel
    @AppStorage(NewDiskChoice.key) private var newDisk = NewDiskChoice.statusBar
    @AppStorage(TextSize.key) private var textSize = TextSize.standard

    enum Metrics {
        static let iconSize: CGFloat = 32
        static let iconSpacing: CGFloat = 8
        static let rowSpacing: CGFloat = 2
        static let rowPadding: CGFloat = 6
        static let listInset: CGFloat = 6
        static func nameFont(_ size: TextSize) -> NSFont { size.font(.systemFont(ofSize: NSFont.systemFontSize)) }
        static func pathFont(_ size: TextSize) -> NSFont { size.font(.systemFont(ofSize: NSFont.smallSystemFontSize)) }
        static func rowHeight(_ size: TextSize) -> CGFloat {
            let name = nameFont(size)
            let path = pathFont(size)
            return max(iconSize, ceil(name.ascender - name.descender + name.leading)
                + ceil(path.ascender - path.descender + path.leading) + rowSpacing) + rowPadding * 2
        }
    }

    var body: some View {
        Form {
            Section {
                Picker(selection: Binding(get: { newDisk }, set: { choice in
                    newDisk = choice
                    if choice == .notification { model.askForNotifications() }
                })) {
                    ForEach(NewDiskChoice.allCases, id: \.self) { $0.title.font(textSize.formText).tag($0) }
                } label: {
                    Text("When a disk that isn’t indexed is connected", tableName: "Settings").font(textSize.formLabel)
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier(Self.newDiskID)
            } footer: {
                if newDisk == .notification, model.notificationsOff {
                    Text("Notifications for Wherever are turned off. Allow them in System Settings > Notifications.", tableName: "Settings")
                        .font(textSize.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier(Self.notificationsOffID)
                }
            }
            Section {
                VStack(spacing: 0) {
                    List(model.items, id: \.row, selection: $model.selection) { location($0) }
                    .listStyle(.plain)
                    .environment(\.defaultMinListRowHeight, Metrics.rowHeight(textSize))
                    .scrollContentBackground(.hidden)
                    .scrollDisabled(true)
                    .frame(height: CGFloat(max(1, model.items.count)) * Metrics.rowHeight(textSize))
                    .padding(.horizontal, -Metrics.listInset)
                    .accessibilityLabel(Text("Excluded Paths", tableName: "Settings"))
                    Divider()
                    HStack(spacing: 0) {
                        Button { model.addFolder() } label: {
                            Image(systemName: "plus").frame(width: 28, height: 24).contentShape(Rectangle())
                        }
                        .accessibilityLabel(Text("Add excluded path", tableName: "Settings"))
                        .accessibilityIdentifier("locations-add")
                        Divider().frame(height: 14)
                        Button { model.removeSelected() } label: {
                            Image(systemName: "minus").frame(width: 28, height: 24).contentShape(Rectangle())
                        }
                        .accessibilityLabel(Text("Remove excluded path", tableName: "Settings"))
                        .accessibilityIdentifier("locations-remove")
                        .disabled(!model.canRemoveSelection)
                        Spacer(minLength: 0)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("locations-list")
            } header: {
                Text("Excluded Paths", tableName: "Settings").font(textSize.formHeader)
            } footer: {
                VStack(alignment: .leading, spacing: SettingsWindow.Metrics.captionSpacing) {
                    Text("Wherever skips these paths and everything inside them. Search Content still reads one, or a folder inside it, when you choose it as the Search folder.", tableName: "Settings")
                    Text("Other disks start in this list. Remove a disk to index it.", tableName: "Settings")
                    if model.failed {
                        Text("Wherever could not change the locations. Try again.", tableName: "Settings").foregroundStyle(Color(nsColor: Theme.problem))
                    }
                }
                .font(textSize.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("locations-footer")
            }
        }
        .formStyle(.grouped)
        .alert(
            Text("Exclude “\(Bidi.path(model.pending?.path ?? ""))”?", tableName: "Settings"),
            isPresented: Binding(get: { model.pending != nil }, set: { if !$0 { model.pending = nil } }),
            presenting: model.pending
        ) { _ in
            Button { model.confirmPending() } label: { Text("Exclude", tableName: "Settings") }
            Button(role: .cancel) { model.pending = nil } label: { Text("Cancel", tableName: "Settings") }
        } message: { pending in
            Text("Wherever won’t index \(pending.disks.map(Bidi.name).formatted(.list(type: .and))) while this path is in the list.", tableName: "Settings")
        }
        .onAppear {
            model.shown = true
            model.refresh()
        }
        .onDisappear { model.shown = false }
        .task { await model.readNotifications() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refresh()
            Task { await model.readNotifications() }
        }
    }

    private func text(_ note: LocationsModel.Item.Note) -> Text {
        switch note {
        case .invalid: Text("This path isn’t valid", tableName: "Settings")
        case .notConnected: Text("The disk isn’t connected", tableName: "Settings")
        case .noUUID: Text("Can’t be indexed: this disk has no UUID", tableName: "Settings")
        case .hiddenBy(let row): Text("Remove “\(Bidi.path(row))” to index this disk", tableName: "Settings")
        }
    }

    static func icon(for path: String, type: UTType) -> NSImage {
        FileManager.default.fileExists(atPath: path)
            ? NSWorkspace.shared.icon(forFile: path) : NSWorkspace.shared.icon(for: type)
    }

    private func location(_ item: LocationsModel.Item) -> some View {
        let (name, path) = (item.name, item.path)
        return HStack(spacing: Metrics.iconSpacing) {
            Image(nsImage: item.icon)
                .resizable().scaledToFit()
                .frame(width: Metrics.iconSize, height: Metrics.iconSize)
                .accessibilityLabel(Text(verbatim: name))
                .accessibilityIdentifier("locations-icon-\(path)")
            VStack(alignment: .leading, spacing: Metrics.rowSpacing) {
                Text(verbatim: name).font(Font(Metrics.nameFont(textSize)))
                    .accessibilityIdentifier("locations-name-\(path)")
                (item.note.map { text($0) } ?? Text(verbatim: (path as NSString).abbreviatingWithTildeInPath))
                    .font(Font(Metrics.pathFont(textSize))).foregroundStyle(.secondary)
                    .accessibilityIdentifier("locations-path-\(path)")
            }
            .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .frame(height: Metrics.rowHeight(textSize))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("locations-row-\(path)")
        .listRowInsets(EdgeInsets())
    }
}
