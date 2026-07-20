import AppKit
import Combine
import MetalKit
import SwiftUI
@preconcurrency import SwiftTerm

@MainActor
final class SwiftTermTerminalEngine: ObservableObject, EmbeddedTerminalEngine {
    let identifier = TerminalEngineIdentifier.swiftTerm
    private let inputRouter = TerminalInputRouter()
    private let searchRouter = TerminalSearchRouter()
    private let focusCoordinator = TerminalFocusCoordinator()

    func makeSurface(
        for pane: TerminalPane,
        synchronizedPaneIDs: Set<TerminalPane.ID>,
        isActive: Bool,
        isVisible: Bool,
        isVisibleInLayout: Bool,
        onOutput: (@MainActor @Sendable ([UInt8]) -> Void)?,
        onStartupEvent: @escaping @MainActor @Sendable (StartupFlowMarkerEvent) -> Void,
        onFindCommand: @escaping @MainActor @Sendable (TerminalFindCommand) -> Void,
        onActivate: @escaping @MainActor @Sendable () -> Void,
        onProcessExit: @escaping @MainActor @Sendable (Int32?) -> Void
    ) -> AnyView {
        AnyView(
            SwiftTermTerminalSurface(
                paneID: pane.id,
                configuration: pane.process,
                synchronizedPaneIDs: synchronizedPaneIDs,
                isActive: isActive,
                isVisible: isVisible,
                isVisibleInLayout: isVisibleInLayout,
                inputRouter: inputRouter,
                searchRouter: searchRouter,
                focusCoordinator: focusCoordinator,
                markerPrefix: pane.startupExecution?.markerPrefix,
                onOutput: onOutput,
                onStartupEvent: onStartupEvent,
                onFindCommand: onFindCommand,
                onActivate: onActivate,
                onProcessExit: onProcessExit
            )
            .id(pane.id)
        )
    }

    func send(_ bytes: [UInt8], to paneID: TerminalPane.ID) -> Bool {
        inputRouter.sendDirect(bytes, to: paneID)
    }

    @discardableResult
    func findNext(_ term: String, in paneID: TerminalPane.ID) -> TerminalSearchSummary? {
        searchRouter.findNext(term, in: paneID)
    }

    @discardableResult
    func findPrevious(_ term: String, in paneID: TerminalPane.ID) -> TerminalSearchSummary? {
        searchRouter.findPrevious(term, in: paneID)
    }

    func clearSearch(in paneID: TerminalPane.ID) {
        searchRouter.clearSearch(in: paneID)
    }

    func focusTerminal(_ paneID: TerminalPane.ID) {
        searchRouter.focusTerminal(paneID)
    }
}

@MainActor
final class TerminalInputRouter {
    typealias InputHandler = ([UInt8]) -> Void

    private var handlers: [TerminalPane.ID: InputHandler] = [:]

    func register(paneID: TerminalPane.ID, handler: @escaping InputHandler) {
        handlers[paneID] = handler
    }

    func unregister(paneID: TerminalPane.ID) {
        handlers[paneID] = nil
    }

    @discardableResult
    func sendDirect(_ bytes: [UInt8], to paneID: TerminalPane.ID) -> Bool {
        guard let handler = handlers[paneID] else { return false }
        handler(bytes)
        return true
    }

    @discardableResult
    func forward(
        _ bytes: [UInt8],
        from sourcePaneID: TerminalPane.ID,
        to synchronizedPaneIDs: Set<TerminalPane.ID>
    ) -> Int {
        guard synchronizedPaneIDs.count > 1,
              synchronizedPaneIDs.contains(sourcePaneID) else {
            return 0
        }

        var forwardedCount = 0
        for paneID in synchronizedPaneIDs where paneID != sourcePaneID {
            guard let handler = handlers[paneID] else { continue }
            handler(bytes)
            forwardedCount += 1
        }
        return forwardedCount
    }
}

@MainActor
final class TerminalSearchRouter {
    struct Handlers {
        var findNext: (String) -> TerminalSearchSummary?
        var findPrevious: (String) -> TerminalSearchSummary?
        var clear: () -> Void
        var focus: () -> Void
    }

    private var handlers: [TerminalPane.ID: Handlers] = [:]

    func register(paneID: TerminalPane.ID, handlers newHandlers: Handlers) {
        handlers[paneID] = newHandlers
    }

    func unregister(paneID: TerminalPane.ID) {
        handlers[paneID] = nil
    }

    func findNext(_ term: String, in paneID: TerminalPane.ID) -> TerminalSearchSummary? {
        handlers[paneID]?.findNext(term)
    }

    func findPrevious(_ term: String, in paneID: TerminalPane.ID) -> TerminalSearchSummary? {
        handlers[paneID]?.findPrevious(term)
    }

    func clearSearch(in paneID: TerminalPane.ID) {
        handlers[paneID]?.clear()
    }

    func focusTerminal(_ paneID: TerminalPane.ID) {
        handlers[paneID]?.focus()
    }
}

/// Single decision point for which terminal view owns keyboard focus.
///
/// Previously every pane's `updateNSView` independently scheduled a deferred
/// `makeFirstResponder` with the view captured at schedule time. Two panes
/// whose SwiftUI updates ran against momentarily inconsistent `isActive`
/// values could then steal focus from each other indefinitely — observed as
/// the keyboard going dead (every keystroke beeping) until switching views
/// forced a clean render. Funneling every claim through one coalesced pass
/// makes the most recent active pane the single winner, and re-checks every
/// precondition at execution time instead of capture time.
@MainActor
final class TerminalFocusCoordinator {
    private weak var activeView: NSView?
    private var ensurePending = false
    private var forceNextEnsure = false
    // Never removed: the coordinator lives for the app's lifetime (owned by
    // the engine, which the app owns), so there is no deinit-time cleanup to
    // fight Swift concurrency over.
    private var windowObserver: (any NSObjectProtocol)?

    init() {
        // AppKit restores a window's stored first responder when the window
        // becomes key again (app switch, popover/sheet dismissal). If that
        // restored responder is no longer the active pane, this pass corrects
        // it — no SwiftUI update is needed to recover anymore.
        windowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scheduleEnsure()
            }
        }
    }

    /// The pane rendered with `isActive == true` claims focus. Safe to call on
    /// every SwiftUI update; the resolution pass is coalesced and no-ops when
    /// the view already has focus.
    func claimFocus(for view: NSView) {
        activeView = view
        scheduleEnsure()
    }

    /// A pane rendered with `isActive == false` drops any claim it still
    /// holds, so a stale claim can never outlive the pane's active state.
    func releaseFocus(for view: NSView) {
        if activeView === view {
            activeView = nil
        }
    }

    /// User-initiated focus hand-off (e.g. closing the in-terminal search
    /// bar): bypasses the field-editor courtesy below, but still defers one
    /// runloop turn so SwiftUI can finish resolving the field's focus loss
    /// without clobbering a synchronous change.
    func focusNow(_ view: NSView) {
        activeView = view
        forceNextEnsure = true
        scheduleEnsure()
    }

    private func scheduleEnsure() {
        guard !ensurePending else { return }
        ensurePending = true
        DispatchQueue.main.async { [weak self] in
            self?.ensureFocus()
        }
    }

    private func ensureFocus() {
        ensurePending = false
        let forced = forceNextEnsure
        forceNextEnsure = false
        guard let view = activeView,
              let window = view.window,
              !view.isHiddenOrHasHiddenAncestor,
              window.isKeyWindow,
              window.firstResponder !== view else { return }
        // Don't yank focus from an in-window text field mid-edit (terminal
        // search bar, inline rename); those give focus back explicitly.
        if !forced,
           let editor = window.firstResponder as? NSTextView,
           editor.isFieldEditor {
            return
        }
        window.makeFirstResponder(view)
    }
}

@MainActor
private struct SwiftTermTerminalSurface: NSViewRepresentable {
    let paneID: TerminalPane.ID
    let configuration: TerminalProcessConfiguration
    let synchronizedPaneIDs: Set<TerminalPane.ID>
    let isActive: Bool
    let isVisible: Bool
    /// Faz 6: pane zoom. `false` while this pane is hidden behind another
    /// zoomed pane in the same session — combined with `isVisible` (tab-level
    /// visibility) to decide the NSView's `isHidden`. Kept as a separate flag
    /// rather than folded into `isVisible` at the call site so each concern
    /// (tab selection vs. zoom) stays independently readable here.
    let isVisibleInLayout: Bool
    let inputRouter: TerminalInputRouter
    let searchRouter: TerminalSearchRouter
    let focusCoordinator: TerminalFocusCoordinator
    let markerPrefix: String?
    let onOutput: (@MainActor @Sendable ([UInt8]) -> Void)?
    let onStartupEvent: @MainActor @Sendable (StartupFlowMarkerEvent) -> Void
    let onFindCommand: @MainActor @Sendable (TerminalFindCommand) -> Void
    let onActivate: @MainActor @Sendable () -> Void
    let onProcessExit: @MainActor @Sendable (Int32?) -> Void

    @ObservedObject private var settings = TerminalSettings.shared

    func makeCoordinator() -> Coordinator {
        Coordinator(
            paneID: paneID,
            inputRouter: inputRouter,
            searchRouter: searchRouter,
            onProcessExit: onProcessExit
        )
    }

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let terminal = SynchronizableLocalProcessTerminalView(frame: .zero)
        terminal.processDelegate = context.coordinator
        terminal.font = settings.resolvedFont
        terminal.applyTheme(settings.resolvedTheme)
        terminal.getTerminal().setCursorStyle(settings.resolvedCursorStyle)
        terminal.scrollSensitivity = CGFloat(settings.scrollSensitivity)
        terminal.optionAsMetaKey = false
        terminal.changeScrollback(10_000)
        terminal.synchronizedPaneIDs = synchronizedPaneIDs
        terminal.onUserInput = { [weak inputRouter, weak terminal] bytes in
            guard let terminal else { return }
            inputRouter?.forward(
                bytes,
                from: paneID,
                to: terminal.synchronizedPaneIDs
            )
        }
        terminal.onOutput = onOutput
        if let markerPrefix {
            terminal.configureStartupMarkers(prefix: markerPrefix) { event in
                Task { @MainActor in
                    onStartupEvent(event)
                }
            }
        }
        terminal.onFindCommand = { command in
            onFindCommand(command)
        }
        // Clicking a pane's terminal area must also select that pane in the
        // model. AppKit already hands the clicked view first responder status;
        // without the model catching up, the still-"active" old pane would
        // reclaim focus on the next SwiftUI update (the v1.0 "must click the
        // pane title to switch" complaint — the SwiftUI tap gesture doesn't
        // reliably fire over an NSViewRepresentable).
        terminal.onMouseDownActivate = {
            onActivate()
        }
        inputRouter.register(paneID: paneID) { [weak terminal] bytes in
            terminal?.receiveSynchronizedInput(bytes)
        }
        searchRouter.register(
            paneID: paneID,
            handlers: TerminalSearchRouter.Handlers(
                findNext: { [weak terminal] term in
                    terminal?.performFind(term, forward: true)
                },
                findPrevious: { [weak terminal] term in
                    terminal?.performFind(term, forward: false)
                },
                clear: { [weak terminal] in
                    terminal?.clearSearch()
                },
                focus: { [weak terminal, focusCoordinator] in
                    guard let terminal else { return }
                    focusCoordinator.focusNow(terminal)
                }
            )
        )

        let environment = configuration.environment
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }

        terminal.startProcess(
            executable: configuration.executableURL.path,
            args: configuration.arguments,
            environment: environment,
            currentDirectory: configuration.currentDirectoryURL?.path
        )

        terminal.isHidden = !(isVisible && isVisibleInLayout)

        if isActive {
            focusCoordinator.claimFocus(for: terminal)
        }

        return terminal
    }

    func updateNSView(_ terminal: LocalProcessTerminalView, context: Context) {
        let shouldBeVisible = isVisible && isVisibleInLayout
        if let terminal = terminal as? SynchronizableLocalProcessTerminalView {
            terminal.synchronizedPaneIDs = synchronizedPaneIDs
            // Reassigned every update: the closure captures this render's view
            // values (active pane, session state); the one from makeNSView
            // would act on the first render's snapshot forever.
            terminal.onMouseDownActivate = {
                onActivate()
            }
            terminal.onOutput = onOutput
            let font = settings.resolvedFont
            if terminal.font != font {
                terminal.font = font
            }
            terminal.applyTheme(settings.resolvedTheme)
            // Terminal.setCursorStyle already no-ops when the style hasn't
            // changed, so this is safe to call unconditionally on every
            // update — same reasoning as the font/theme calls above.
            terminal.getTerminal().setCursorStyle(settings.resolvedCursorStyle)
            terminal.scrollSensitivity = CGFloat(settings.scrollSensitivity)
        }
        if terminal.isHidden == shouldBeVisible {
            terminal.isHidden = !shouldBeVisible
            if shouldBeVisible {
                terminal.needsDisplay = true
                // SwiftTerm's Metal row cache keys rows on content generation and
                // font/size, not on color — a theme switch while this pane was
                // hidden schedules a full-redraw dirty range, but that range can be
                // silently overwritten by an unrelated content update that arrives
                // before the (paused, on-demand) Metal view is ever actually drawn
                // again. Reapplying the theme right as the pane becomes visible
                // re-primes a fresh dirty range immediately before the next draw,
                // closing that window so unhidden surfaces never show stale colors.
                if let terminal = terminal as? SynchronizableLocalProcessTerminalView {
                    terminal.applyTheme(settings.resolvedTheme, forceRefresh: true)
                }
            }
        }
        if isActive {
            focusCoordinator.claimFocus(for: terminal)
        } else {
            focusCoordinator.releaseFocus(for: terminal)
        }
    }

    static func dismantleNSView(_ terminal: LocalProcessTerminalView, coordinator: Coordinator) {
        (terminal as? SynchronizableLocalProcessTerminalView)?.finalizeStartupMarkers()
        coordinator.inputRouter.unregister(paneID: coordinator.paneID)
        coordinator.searchRouter.unregister(paneID: coordinator.paneID)
        terminal.processDelegate = nil
        terminal.terminate()
    }

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate, @unchecked Sendable {
        let paneID: TerminalPane.ID
        let inputRouter: TerminalInputRouter
        let searchRouter: TerminalSearchRouter
        private let onProcessExit: @MainActor @Sendable (Int32?) -> Void

        init(
            paneID: TerminalPane.ID,
            inputRouter: TerminalInputRouter,
            searchRouter: TerminalSearchRouter,
            onProcessExit: @escaping @MainActor @Sendable (Int32?) -> Void
        ) {
            self.paneID = paneID
            self.inputRouter = inputRouter
            self.searchRouter = searchRouter
            self.onProcessExit = onProcessExit
        }

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

        func processTerminated(source: TerminalView, exitCode: Int32?) {
            let terminal = source as? SynchronizableLocalProcessTerminalView
            Task { @MainActor [weak terminal, onProcessExit] in
                terminal?.finalizeStartupMarkers()
                onProcessExit(exitCode)
            }
        }
    }
}

@MainActor
final class SynchronizableLocalProcessTerminalView: LocalProcessTerminalView {
    var synchronizedPaneIDs: Set<TerminalPane.ID> = []
    var onUserInput: (([UInt8]) -> Void)?
    var onOutput: (@MainActor @Sendable ([UInt8]) -> Void)?
    var onFindCommand: ((TerminalFindCommand) -> Void)?
    var onMouseDownActivate: (() -> Void)?

    private var isPasting = false
    private var didConfigureRenderer = false
    private var startupMarkerParser: StartupFlowMarkerParser?
    private var onStartupEvent: ((StartupFlowMarkerEvent) -> Void)?
    private var appliedThemeID: String?

    /// Applies a terminal color theme: the 16 ANSI palette entries plus
    /// background/foreground/cursor. No-ops if `theme` is already applied,
    /// unless `forceRefresh` is set (used when a pane transitions from
    /// hidden to visible — see the call site in `updateNSView` for why).
    func applyTheme(_ theme: TerminalTheme, forceRefresh: Bool = false) {
        guard forceRefresh || appliedThemeID != theme.id else { return }
        appliedThemeID = theme.id

        let palette = theme.palette
        installColors(palette.ansi.map { $0.swiftTermColor })
        nativeBackgroundColor = palette.background.nsColor
        nativeForegroundColor = palette.foreground.nsColor
        caretColor = palette.cursor?.nsColor ?? Self.systemDefaultCaretColor

        // installColors/nativeForegroundColor/nativeBackgroundColor each already
        // mark the terminal's full screen dirty and schedule a throttled Metal
        // redraw (SwiftTerm's `colorsChanged()`), but that schedule can be
        // silently overwritten by an unrelated small content update before this
        // surface is next actually drawn (its row cache keys on content
        // generation and font/size, not color). Forcing an immediate display
        // request here narrows that window for visible surfaces; the
        // `forceRefresh` reapplication on unhide closes it for hidden ones.
        needsDisplay = true
    }

    /// SwiftTerm's own default caret color (`MacCaretView.caretColor`'s initial
    /// value), used to restore the exact original look when a theme with no
    /// explicit cursor color (only "system" today) is applied over one that did
    /// set a custom cursor color.
    private static let systemDefaultCaretColor = NSColor.selectedControlColor

    func configureStartupMarkers(
        prefix: String,
        onEvent: @escaping (StartupFlowMarkerEvent) -> Void
    ) {
        startupMarkerParser = StartupFlowMarkerParser(prefix: prefix)
        onStartupEvent = onEvent
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        guard window != nil, !didConfigureRenderer else { return }
        didConfigureRenderer = true

        do {
            metalBufferingMode = .perFrameAggregated
            try setUseMetal(true)
        } catch {
            // SwiftTerm keeps using CoreGraphics when Metal is unavailable.
        }
    }

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        super.send(source: source, data: data)

        let eventType = NSApp.currentEvent?.type
        guard isPasting || eventType == .keyDown else { return }
        onUserInput?(Array(data))
    }

    override func dataReceived(slice: ArraySlice<UInt8>) {
        guard var parser = startupMarkerParser else {
            onOutput?(Array(slice))
            super.dataReceived(slice: slice)
            return
        }

        let result = parser.process(slice)
        startupMarkerParser = parser
        if !result.visibleBytes.isEmpty {
            onOutput?(result.visibleBytes)
            super.dataReceived(slice: result.visibleBytes[...])
        }
        for event in result.events {
            onStartupEvent?(event)
        }
    }

    override func paste(_ sender: Any) {
        isPasting = true
        defer { isPasting = false }
        super.paste(sender)
    }

    override func mouseDown(with event: NSEvent) {
        onMouseDownActivate?()
        super.mouseDown(with: event)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hitView = super.hitTest(point)
        // SwiftTerm's Metal renderer is an MTKView inserted above the terminal
        // view. Xcode 16 Release builds deliver clicks to that child, bypassing
        // TerminalView.mouseDown and our pane-activation callback entirely.
        // Route only renderer hits back to the terminal; scrollers and other
        // interactive child views keep their native hit targets.
        return hitView is MTKView ? self : hitView
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Key equivalents walk the view hierarchy depth-first, not the responder
        // chain, so without this every split pane would answer for the focused one.
        guard window?.firstResponder === self else {
            return super.performKeyEquivalent(with: event)
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command),
              let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }

        // Compares against the registry instead of bare character literals so
        // this dispatch can never drift from what AppShortcut.findInTerminal /
        // .findNext / .findPrevious document in Help.
        let shift = flags.contains(.shift)
        func matches(_ shortcut: AppShortcut) -> Bool {
            String(shortcut.key.character) == key && shortcut.modifiers.contains(.shift) == shift
        }

        if matches(.findInTerminal) {
            onFindCommand?(.open)
            return true
        }
        if matches(.findNext) {
            onFindCommand?(.next)
            return true
        }
        if matches(.findPrevious) {
            onFindCommand?(.previous)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    // Route the responder-chain find action into our own search bar instead of
    // SwiftTerm's built-in find bar. Deliberately does not call super.
    override func performFindPanelAction(_ sender: Any?) {
        onFindCommand?(.open)
    }

    func performFind(_ term: String, forward: Bool) -> TerminalSearchSummary? {
        guard !term.isEmpty else {
            clearSearch()
            return nil
        }

        let options = SearchOptions()
        let found = forward
            ? findNext(term, options: options, scrollToResult: true)
            : findPrevious(term, options: options, scrollToResult: true)
        guard found else { return .empty }

        let summary = searchMatchSummary(term, options: options)
        return TerminalSearchSummary(index: summary.index, total: summary.total)
    }

    func receiveSynchronizedInput(_ bytes: [UInt8]) {
        super.send(source: self, data: bytes[...])
    }

    func finalizeStartupMarkers() {
        guard var parser = startupMarkerParser else { return }
        let visible = parser.finalize()
        startupMarkerParser = parser
        if !visible.isEmpty {
            onOutput?(visible)
            super.dataReceived(slice: visible[...])
        }
    }
}
