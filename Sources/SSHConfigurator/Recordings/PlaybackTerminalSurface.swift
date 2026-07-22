import AppKit
import SwiftUI
@preconcurrency import SwiftTerm

struct PlaybackTerminalSurface: NSViewRepresentable {
    @ObservedObject var engine: CastPlaybackEngine
    let onRequestClose: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onRequestClose: onRequestClose) }

    func makeNSView(context: Context) -> TerminalView {
        let settings = TerminalSettings.shared
        let terminal = TerminalView(frame: .zero, font: settings.resolvedFont)
        terminal.terminalDelegate = context.coordinator
        terminal.allowMouseReporting = false
        terminal.applyThemePalette(settings.resolvedTheme)
        context.coordinator.installEscapeMonitor()
        connect(engine: engine, terminal: terminal)
        return terminal
    }

    func updateNSView(_ terminal: TerminalView, context: Context) {
        context.coordinator.onRequestClose = onRequestClose
        terminal.font = TerminalSettings.shared.resolvedFont
        terminal.applyThemePalette(TerminalSettings.shared.resolvedTheme)
        connect(engine: engine, terminal: terminal)
    }

    static func dismantleNSView(_ terminal: TerminalView, coordinator: Coordinator) {
        coordinator.removeEscapeMonitor()
    }

    private func connect(engine: CastPlaybackEngine, terminal: TerminalView) {
        engine.feedText = { [weak terminal] text in terminal?.feed(text: text) }
        engine.resetTerminal = { [weak terminal] in
            terminal?.getTerminal().resetToInitialState()
            terminal?.needsDisplay = true
        }
    }

    final class Coordinator: NSObject, TerminalViewDelegate {
        var onRequestClose: () -> Void
        private var escapeMonitor: Any?

        init(onRequestClose: @escaping () -> Void) {
            self.onRequestClose = onRequestClose
        }

        func installEscapeMonitor() {
            guard escapeMonitor == nil else { return }
            escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.keyCode == 53, let self else { return event }
                self.onRequestClose()
                return nil
            }
        }

        func removeEscapeMonitor() {
            if let escapeMonitor {
                NSEvent.removeMonitor(escapeMonitor)
                self.escapeMonitor = nil
            }
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func send(source: TerminalView, data: ArraySlice<UInt8>) {}
        func scrolled(source: TerminalView, position: Double) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}
