import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Wherever
import WhereverInterface

@Suite(.serialized) struct LauncherGlassTests {
    @Test func theFrostedBackgroundOfMacOS13To25IsAPopoverBlurBehindTheWindow() {
        let blur = Availability.frostedLauncherBackground()
        #expect(blur.material == .popover)
        #expect(blur.blendingMode == .behindWindow)
        #expect(blur.state == .active)
        if ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 26 {
            #expect(type(of: Availability.launcherBackground(cornerRadius: LauncherMetrics.cornerRadius)) == NSVisualEffectView.self)
        }
    }

    @Test func onlyTheLauncherStatusBarLetsTheGlassShowThrough() throws {
        let name = "com.writronic.wherever.tests.launcher-glass"
        let store = try #require(UserDefaults(suiteName: name))
        store.removePersistentDomain(forName: name)
        defer { store.removePersistentDomain(forName: name) }
        let index = IndexModel(client: FakeSearchClient())
        let recorder = ActionRecorder()
        let launcher = Launcher(index: index, actions: recorder.actions, defaults: store)

        for theme in Theme.allCases {
            store.set(theme.rawValue, forKey: Theme.key)
            for look in Look.allCases {
                let main = try render(StatusBarView(index: index, model: launcher.model), store: store, look: look)
                let panel = try render(LauncherView(launcher: launcher, model: launcher.model)
                    .environment(\.resultActions, recorder.actions), store: store, look: look)
                let x = 2
                let y = panel.pixelsHigh - 3
                let alpha = try #require(panel.colorAt(x: x, y: y)).alphaComponent
                let fill = CGFloat(Launcher.standardOpacity) / 100
                #expect(abs(alpha - fill) <= 1 / 255, "\(theme) \(look): the root's fill remains and the bar adds none; bar alpha \(alpha), fill \(fill)")
                let clearPadding = try #require(panel.colorAt(x: x, y: 2)).alphaComponent
                #expect(abs(alpha - clearPadding) <= 1 / 255, "the bar covers the launcher's glass")

                let mainAlpha = try #require(main.colorAt(x: x, y: main.pixelsHigh - 3)).alphaComponent
                #expect(mainAlpha == 1, "\(theme) \(look): main window bar became transparent")
                let drawn = try #require(srgbPixel(main, x: x, y: main.pixelsHigh - 3))
                let swatch = try render(Color(nsColor: theme.windowBackground).frame(height: 8), store: store, look: look)
                let expected = try #require(srgbPixel(swatch, x: x, y: 2))
                print("launcher glass: \(theme) \(look), main \(drawn), SwiftUI swatch \(expected), AppKit \(eightBits(channels(theme.windowBackground, look)))")
                #expect(zip(drawn, expected).allSatisfy { abs($0 - $1) <= 1 }, "\(theme) \(look): main bar \(drawn), theme \(expected)")
            }
        }
    }

    @Test func theFillIsTheThemeWindowColorAtTheStoredOpacity() throws {
        let name = "com.writronic.wherever.tests.launcher-opacity"
        let store = try #require(UserDefaults(suiteName: name))
        store.removePersistentDomain(forName: name)
        defer { store.removePersistentDomain(forName: name) }
        let index = IndexModel(client: FakeSearchClient())
        let recorder = ActionRecorder()
        let launcher = Launcher(index: index, actions: recorder.actions, defaults: store)
        let launcherView = LauncherView(launcher: launcher, model: launcher.model).environment(\.resultActions, recorder.actions)

        for theme in Theme.allCases {
            store.set(theme.rawValue, forKey: Theme.key)
            for look in Look.allCases {
                let swatch = try render(Color(nsColor: theme.windowBackground).frame(height: 8), store: store, look: look)
                let expected = try #require(srgbPixel(swatch, x: 2, y: 2))
                for value in [0, 65, 100] {
                    store.set(value, forKey: Launcher.opacityKey)
                    let panel = try render(launcherView, store: store, look: look)
                    let alpha = try #require(panel.colorAt(x: 2, y: 2)).alphaComponent
                    #expect(abs(alpha - CGFloat(value) / 100) <= 1 / 255, "\(theme) \(look) \(value)%: fill alpha \(alpha)")
                    if value == 100 {
                        let drawn = try #require(srgbPixel(panel, x: 2, y: 2))
                        #expect(zip(drawn, expected).allSatisfy { abs($0 - $1) <= 1 }, "\(theme) \(look): fill \(drawn), theme \(expected)")
                    }
                }
                store.set(0, forKey: Launcher.opacityKey)
                let solid = try render(launcherView, store: store, look: look, reduceTransparency: true)
                let alpha = try #require(solid.colorAt(x: 2, y: 2)).alphaComponent
                #expect(abs(alpha - 1) <= 1 / 255, "\(theme) \(look): Reduce transparency left fill alpha \(alpha)")
                let drawn = try #require(srgbPixel(solid, x: 2, y: 2))
                #expect(zip(drawn, expected).allSatisfy { abs($0 - $1) <= 1 }, "\(theme) \(look): solid fill \(drawn), theme \(expected)")
            }
        }
    }

    private final class Measurement {
        var frames: [CGRect] = []
    }

    private struct Frames: PreferenceKey {
        nonisolated static var defaultValue: [CGRect] { [] }
        nonisolated static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) { value += nextValue() }
    }

    @Test func theFooterUsesTheFieldInsetsAndKeepsEveryItemClearOfTheCorners() async throws {
        let fake = FakeSearchClient(hits: [.named("report")])
        let index = IndexModel(client: fake)
        let model = index.makeModel()
        fake.send(.stateChanged(IndexState(phase: .crawling, bootPhase: .live, indexingDisks: ["Disk 1"], indexed: 2_550_850)))
        model.query = "rep"
        fake.send(.resultsReady(fake.latest, count: 1))
        try await untilTrue(waitingFor: "the footer's state and search time") {
            index.indexState?.indexed == 2_550_850 && model.lastSearchTime != nil
        }
        for direction in [LayoutDirection.leftToRight, .rightToLeft] {
            let measured = Measurement()
            let view = StatusBarView(index: index, model: model, clearsBackground: true)
                .environment(\.layoutDirection, direction)
                .environment(\.locale, Locale(identifier: direction == .rightToLeft ? "ar" : "en"))
                .overlayPreferenceValue(StatusBarView.ContentBounds.self) { anchors in
                    GeometryReader { proxy in
                        Color.clear.preference(key: Frames.self, value: anchors.map { proxy[$0] })
                    }
                }
                .onPreferenceChange(Frames.self) { frames in
                    MainActor.assumeIsolated { measured.frames = frames }
                }
            let host = SearchHost(root: AnyView(view))
            defer { host.close() }
            host.window.setContentSize(NSSize(width: LauncherMetrics.width, height: LauncherMetrics.barHeight(.standard)))
            try await host.until("all six footer item frames, including the hidden marks and separator") { measured.frames.count == 6 }
            let bounds = measured.frames.reduce(CGRect.null) { $0.union($1) }
            let width = host.view.bounds.width
            let height = host.view.bounds.height
            let bottom = max(SearchMetrics.statusVerticalInset, ceil(26 * (1 - 1 / sqrt(CGFloat(2)))))
            let scale = host.window.backingScaleFactor
            #expect((bounds.minX - LauncherMetrics.fieldSide) * scale == 0)
            #expect((width - bounds.maxX - LauncherMetrics.fieldSide) * scale == 0)
            #expect((height - bounds.maxY - bottom) * scale == 0)
            let line = bounds.height
            #expect((height - 1 - line - SearchMetrics.statusVerticalInset - bottom) * scale == 0)
            for frame in measured.frames {
                for x in [frame.minX, frame.maxX] {
                    for y in [frame.minY, frame.maxY] {
                        let dx = max(0, 26 - min(x, width - x))
                        let dy = max(0, 26 - (height - y))
                        #expect(max(0, dx * dx + dy * dy - 26 * 26) * scale * scale == 0,
                            "footer frame \(frame) enters a bottom corner in \(direction)")
                    }
                }
            }
            print("launcher footer geometry: \(direction), scale \(scale), height \(height), font line \(line), content bottom \(bounds.maxY), actual inset \(height - bounds.maxY), required inset \(bottom), items \(measured.frames)")
            let state = try #require(measured.frames.first)
            let search = try #require(measured.frames.last)
            #expect(direction == .rightToLeft ? state.minX > search.maxX : state.maxX < search.minX)
        }
    }

    @Test func onlyTheFailedLauncherBarGrowsByTheSentenceLines() async throws {
        let name = "com.writronic.wherever.tests.launcher-failed"
        let store = try #require(UserDefaults(suiteName: name))
        store.removePersistentDomain(forName: name)
        defer { store.removePersistentDomain(forName: name) }
        let fake = FakeSearchClient()
        let index = IndexModel(client: fake)
        let model = index.makeModel()
        for size in [TextSize.standard, .maximum] {
            store.set(size.rawValue, forKey: TextSize.key)
            for phase in [IndexPhase.live, .failed, .live] {
                fake.send(.stateChanged(IndexState(phase: phase, bootPhase: phase, indexed: 10)))
                try await untilTrue(waitingFor: "the \(phase) phase") { index.indexState?.bootPhase == phase }
                let bar = StatusBarView(index: index, model: model, clearsBackground: true).defaultAppStorage(store)
                let height = NSHostingView(rootView: bar.frame(width: LauncherMetrics.width)).fittingSize.height
                let sentence = phase == .failed ? LauncherMetrics.sentenceHeight(size, width: LauncherMetrics.width) : 0
                #expect(height == LauncherMetrics.barHeight(size) + sentence, "\(phase) at \(size.rawValue): \(height) pt")
                #expect(phase != .failed || sentence >= StatusBarView.launcherLineHeight(size))
            }
        }
    }

    private func render(_ view: some View, store: UserDefaults, look: Look, reduceTransparency: Bool = false) throws -> NSBitmapImageRep {
        let dark = look == .dark || look == .darkContrast
        let contrast = look == .lightContrast || look == .darkContrast
        let renderer = ImageRenderer(content: view
            .defaultAppStorage(store)
            .environment(\.colorScheme, dark ? .dark : .light)
            .environment(\._colorSchemeContrast, contrast ? .increased : .standard)
            .environment(\._accessibilityReduceTransparency, reduceTransparency)
            .frame(width: LauncherMetrics.width))
        renderer.scale = 1
        var image: NSBitmapImageRep?
        look.appearance.performAsCurrentDrawingAppearance {
            image = renderer.cgImage.map(NSBitmapImageRep.init(cgImage:))
        }
        return try #require(image)
    }
}
