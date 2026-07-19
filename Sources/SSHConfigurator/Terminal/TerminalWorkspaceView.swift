import AppKit
import SwiftUI

/// Normalized (0–1) geometry for one split boundary, produced alongside pane
/// frames by `layoutGeometry(for:in:)` so dividers can be drawn/dragged.
private struct SplitDividerGeometry: Identifiable {
    let id: UUID              // split node id
    let axis: TerminalSplitAxis
    let containerFrame: CGRect // split node's own normalized frame (for ratio math during drag)
    let lineFrame: CGRect      // zero-thickness normalized rect on the boundary
}

private struct PaneLayoutGeometry {
    var frames: [TerminalPane.ID: CGRect] = [:]
    var dividers: [SplitDividerGeometry] = []
}

/// Transparent AppKit view that owns a cursor rect for the divider hit strip.
/// SwiftUI `.onHover` + `NSCursor.push()` gets clobbered by the terminal
/// NSView's own cursor rects (IBeam); `resetCursorRects` is the reliable path.
/// `hitTest` returns nil so clicks/drags pass through to the SwiftUI gestures.
private struct DividerCursorArea: NSViewRepresentable {
    let cursor: NSCursor

    func makeNSView(context: Context) -> CursorRectView {
        CursorRectView(cursor: cursor)
    }

    func updateNSView(_ view: CursorRectView, context: Context) {
        view.cursor = cursor
        view.window?.invalidateCursorRects(for: view)
    }

    final class CursorRectView: NSView {
        var cursor: NSCursor

        init(cursor: NSCursor) {
            self.cursor = cursor
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: cursor)
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

struct TerminalWorkspaceView: View {
    @ObservedObject var model: TerminalWorkspaceModel
    @ObservedObject var startupLibrary: StartupFlowLibrary
    let engine: any EmbeddedTerminalEngine
    let isActive: Bool
    let isVisible: Bool
    @State private var showingSettingsPopover = false
    @State private var searchPaneID: TerminalPane.ID?
    @State private var searchTerm = ""
    @State private var searchSummary: TerminalSearchSummary?
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var searchFieldFocused: Bool
    @State private var transientRatios: [UUID: Double] = [:]
    @State private var hoveredDividerID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            terminalTabs
            Divider()

            if let session = model.selectedSession {
                sessionHeader(session)
                Divider()
                ZStack {
                    ForEach(model.sessions) { openSession in
                        sessionSurface(openSession)
                            .opacity(model.selectedSessionID == openSession.id ? 1 : 0)
                            .allowsHitTesting(isActive && model.selectedSessionID == openSession.id)
                            .accessibilityHidden(!isActive || model.selectedSessionID != openSession.id)
                    }
                }
                .background(terminalBackground)
                .onChange(of: model.selectedSessionID) { _, _ in
                    closeSearch(returningFocus: false)
                }
                .onChange(of: session.activePaneID) { _, _ in
                    closeSearch(returningFocus: false)
                }
            } else {
                ContentUnavailableView(
                    "Terminal not opened",
                    systemImage: "terminal",
                    description: Text("Click an SSH connection in the sidebar.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var terminalBackground: Color {
        Color(nsColor: NSColor(srgbRed: 0.035, green: 0.043, blue: 0.055, alpha: 1))
    }

    private var terminalTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(model.sessions) { session in
                    HStack(spacing: 5) {
                        Button {
                            model.selectedSessionID = session.id
                        } label: {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(statusColor(session.status))
                                    .frame(width: 7, height: 7)
                                Text(session.alias)
                                    .lineLimit(1)
                                if session.panes.count > 1 {
                                    Text("\(session.panes.count)")
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)

                        Button {
                            model.closeTab(session.id)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption2.weight(.bold))
                        }
                        .buttonStyle(.plain)
                        .help("Close the tab and all SSH connections")
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        model.selectedSessionID == session.id
                            ? Color.accentColor.opacity(0.16)
                            : Color.secondary.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 7)
                    )
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(minHeight: 44)
    }

    private func sessionHeader(_ session: TerminalSession) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "terminal.fill")
            VStack(alignment: .leading, spacing: 2) {
                Text(session.alias)
                    .font(.headline)
                Text(sessionStatusText(session))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if session.panes.count > 1 && session.synchronizedPaneIDs.isEmpty {
                Text("⌘-click to select for sync")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(engine.identifier == .swiftTerm ? "SwiftTerm · SSH" : "Ghostty · SSH")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)

            if session.activePane?.startupExecution != nil {
                Button("Run startup flow again", systemImage: "arrow.clockwise.circle") {
                    runStartupAgain(in: session)
                }
                .labelStyle(.iconOnly)
                .disabled(session.activePane?.status != .running || session.isStartupRunning)
                .help("Manually re-run the startup flow in the active terminal")
            }

            if session.synchronizedPaneIDs.count > 1 {
                Button("Turn off sync", systemImage: "link.badge.minus") {
                    model.clearPaneSynchronization(in: session.id)
                }
                .labelStyle(.iconOnly)
                .help("Clear synchronized terminal selection")
            }

            Button("Split vertically", systemImage: "rectangle.split.2x1") {
                model.splitActivePane(
                    in: session.id,
                    axis: .vertical,
                    startupProfile: startupLibrary.profile(for: session.activePane?.alias ?? "")
                )
            }
            .labelStyle(.iconOnly)
            .help("Split the active terminal vertically; opens the same connection on the right")

            Button("Split horizontally", systemImage: "rectangle.split.1x2") {
                model.splitActivePane(
                    in: session.id,
                    axis: .horizontal,
                    startupProfile: startupLibrary.profile(for: session.activePane?.alias ?? "")
                )
            }
            .labelStyle(.iconOnly)
            .help("Split the active terminal horizontally; opens the same connection below")

            if session.panes.count > 1 {
                Button("Close pane", systemImage: "rectangle.badge.xmark", role: .destructive) {
                    model.closePane(session.activePaneID, in: session.id)
                }
                .labelStyle(.iconOnly)
                .help("Close the active terminal pane")
            }

            Button("Close connection", systemImage: "stop.circle", role: .destructive) {
                model.closeTab(session.id)
            }
            .labelStyle(.iconOnly)
            .help("Close the terminal tab and all SSH processes")

            Button {
                showingSettingsPopover = true
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .help("Terminal appearance settings")
            .popover(isPresented: $showingSettingsPopover, arrowEdge: .bottom) {
                TerminalSettingsView()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func sessionSurface(_ session: TerminalSession) -> some View {
        GeometryReader { geometry in
            let geometryInfo = layoutGeometry(for: session.layout)

            ZStack(alignment: .topLeading) {
                ForEach(session.panes) { pane in
                    let normalizedFrame = geometryInfo.frames[pane.id] ?? CGRect(x: 0, y: 0, width: 1, height: 1)
                    let paneIsActive = isActive &&
                        model.selectedSessionID == session.id &&
                        session.activePaneID == pane.id

                    paneSurface(pane, in: session, isActive: paneIsActive)
                        .frame(
                            width: max(1, geometry.size.width * normalizedFrame.width - 2),
                            height: max(1, geometry.size.height * normalizedFrame.height - 2)
                        )
                        .position(
                            x: geometry.size.width * normalizedFrame.midX,
                            y: geometry.size.height * normalizedFrame.midY
                        )
                }

                ForEach(geometryInfo.dividers) { divider in
                    splitDividerHandle(divider, in: geometry, sessionID: session.id)
                }
            }
        }
    }

    /// A near-invisible hit strip straddling a split boundary: drag to resize,
    /// double-click to reset to 50/50. Never touches first responder — only
    /// writes `transientRatios`/`model.setSplitRatio`.
    private func splitDividerHandle(
        _ divider: SplitDividerGeometry,
        in geometry: GeometryProxy,
        sessionID: TerminalSession.ID
    ) -> some View {
        let isVertical = divider.axis == .vertical
        let hitThickness: CGFloat = 8
        let hitWidth = isVertical ? hitThickness : geometry.size.width * divider.lineFrame.width
        let hitHeight = isVertical ? geometry.size.height * divider.lineFrame.height : hitThickness
        let isHighlighted = hoveredDividerID == divider.id || transientRatios[divider.id] != nil

        return ZStack {
            Rectangle()
                .fill(Color.clear)
                .frame(width: hitWidth, height: hitHeight)
                .contentShape(Rectangle())
                .background(DividerCursorArea(cursor: isVertical ? .resizeLeftRight : .resizeUpDown))

            Rectangle()
                .fill(isHighlighted ? Color.accentColor : Color.secondary.opacity(0.4))
                .frame(
                    width: isVertical ? (isHighlighted ? 2 : 1) : hitWidth,
                    height: isVertical ? hitHeight : (isHighlighted ? 2 : 1)
                )
        }
        .position(
            x: geometry.size.width * divider.lineFrame.midX,
            y: geometry.size.height * divider.lineFrame.midY
        )
        .onHover { hovering in
            if hovering {
                hoveredDividerID = divider.id
            } else if hoveredDividerID == divider.id {
                hoveredDividerID = nil
            }
        }
        .onTapGesture(count: 2) {
            model.setSplitRatio(0.5, splitID: divider.id, in: sessionID)
        }
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { value in
                    let rawRatio = isVertical
                        ? (value.location.x / geometry.size.width - divider.containerFrame.minX) / divider.containerFrame.width
                        : (value.location.y / geometry.size.height - divider.containerFrame.minY) / divider.containerFrame.height
                    transientRatios[divider.id] = min(
                        max(rawRatio, TerminalPaneLayout.minimumSplitRatio),
                        TerminalPaneLayout.maximumSplitRatio
                    )
                }
                .onEnded { _ in
                    if let finalRatio = transientRatios[divider.id] {
                        model.setSplitRatio(finalRatio, splitID: divider.id, in: sessionID)
                    }
                    transientRatios.removeAll()
                }
        )
    }

    private func paneSurface(
        _ pane: TerminalPane,
        in session: TerminalSession,
        isActive: Bool
    ) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(statusColor(pane.status))
                        .frame(width: 6, height: 6)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(pane.alias)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                        if let startupState = pane.startupState {
                            Text(startupStatusText(startupState))
                                .font(.caption2)
                                .foregroundStyle(startupStatusColor(startupState))
                                .lineLimit(1)
                        }
                    }
                    if session.synchronizedPaneIDs.contains(pane.id) {
                        Image(systemName: "link")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())

                Button {
                    model.closePane(pane.id, in: session.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.bold))
                }
                .buttonStyle(.plain)
                .help("Close this terminal pane")
            }
            .padding(.horizontal, 8)
            .frame(height: pane.startupState == nil ? 27 : 38)
            .background(
                session.synchronizedPaneIDs.contains(pane.id)
                    ? Color.orange.opacity(0.20)
                    : isActive ? Color.accentColor.opacity(0.18) : Color.black.opacity(0.22)
            )

            Divider()

            ZStack {
                engine.makeSurface(
                    for: pane,
                    synchronizedPaneIDs: session.isStartupRunning ? [] : session.synchronizedPaneIDs,
                    // While the search bar owns focus the surface must not claim it
                    // back on every state change; closing the bar restores focus.
                    isActive: isActive && searchPaneID != pane.id,
                    isVisible: isVisible && model.selectedSessionID == session.id,
                    onStartupEvent: { event in
                        model.startupEvent(event, sessionID: session.id, paneID: pane.id)
                    },
                    onFindCommand: { command in
                        handleFindCommand(command, paneID: pane.id)
                    },
                    onActivate: {
                        // Plain click inside the already-active pane must not
                        // run selectPane — it would clear an in-progress
                        // synchronized-pane selection. ⌘-click always goes
                        // through (it toggles sync membership).
                        guard NSEvent.modifierFlags.contains(.command)
                                || session.activePaneID != pane.id else { return }
                        selectPane(pane.id, in: session.id)
                    }
                ) { exitCode in
                    model.processDidExit(sessionID: session.id, paneID: pane.id, exitCode: exitCode)
                }

                if case let .exited(exitCode) = pane.status {
                    exitedPaneOverlay(pane, in: session, exitCode: exitCode)
                }

                if searchPaneID == pane.id {
                    searchBar
                        .frame(maxHeight: .infinity, alignment: .top)
                }
            }
        }
        .background(terminalBackground)
        .overlay {
            Rectangle()
                .stroke(
                    session.synchronizedPaneIDs.contains(pane.id)
                        ? Color.orange
                        : isActive ? Color.accentColor : Color.secondary.opacity(0.28),
                    lineWidth: isActive || session.synchronizedPaneIDs.contains(pane.id) ? 1.5 : 1
                )
        }
        .contentShape(Rectangle())
        .simultaneousGesture(
            TapGesture().onEnded {
                selectPane(pane.id, in: session.id)
            }
        )
    }

    private func selectPane(_ paneID: TerminalPane.ID, in sessionID: TerminalSession.ID) {
        model.selectPane(
            paneID,
            in: sessionID,
            extendingSynchronization: NSEvent.modifierFlags.contains(.command)
        )
    }

    private func runStartupAgain(in session: TerminalSession) {
        let paneID = session.activePaneID
        guard let command = model.prepareManualStartup(
            sessionID: session.id,
            paneID: paneID
        ) else { return }
        guard engine.send(Array(command.utf8), to: paneID) else {
            model.manualStartupSendFailed(sessionID: session.id, paneID: paneID)
            return
        }
    }

    /// Single recursive walk producing both normalized pane frames and the
    /// divider geometry needed to draw/drag split boundaries. `effectiveRatio`
    /// reads `transientRatios` first so an in-progress drag resizes panes
    /// live without writing to the model on every tick.
    private func layoutGeometry(
        for layout: TerminalPaneLayout,
        in frame: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    ) -> PaneLayoutGeometry {
        switch layout {
        case let .pane(pane):
            return PaneLayoutGeometry(frames: [pane.id: frame], dividers: [])

        case let .split(id, axis, ratio, first, second):
            let effectiveRatio = transientRatios[id] ?? ratio
            let firstFrame: CGRect
            let secondFrame: CGRect
            let lineFrame: CGRect

            switch axis {
            case .vertical:
                let firstWidth = frame.width * effectiveRatio
                firstFrame = CGRect(x: frame.minX, y: frame.minY, width: firstWidth, height: frame.height)
                secondFrame = CGRect(x: frame.minX + firstWidth, y: frame.minY, width: frame.width - firstWidth, height: frame.height)
                lineFrame = CGRect(x: frame.minX + firstWidth, y: frame.minY, width: 0, height: frame.height)
            case .horizontal:
                let firstHeight = frame.height * effectiveRatio
                firstFrame = CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: firstHeight)
                secondFrame = CGRect(x: frame.minX, y: frame.minY + firstHeight, width: frame.width, height: frame.height - firstHeight)
                lineFrame = CGRect(x: frame.minX, y: frame.minY + firstHeight, width: frame.width, height: 0)
            }

            var geometry = layoutGeometry(for: first, in: firstFrame)
            let secondGeometry = layoutGeometry(for: second, in: secondFrame)
            geometry.frames.merge(secondGeometry.frames) { current, _ in current }
            geometry.dividers.append(
                SplitDividerGeometry(id: id, axis: axis, containerFrame: frame, lineFrame: lineFrame)
            )
            geometry.dividers.append(contentsOf: secondGeometry.dividers)
            return geometry
        }
    }

    private func statusText(_ status: TerminalPane.Status) -> String {
        switch status {
        case .running:
            return String(localized: "SSH connection is open")
        case let .exited(code):
            return code.map { String(localized: "Terminal process closed (exit: \($0))") }
                ?? String(localized: "Terminal process closed")
        }
    }

    private func sessionStatusText(_ session: TerminalSession) -> String {
        if session.isStartupRunning {
            return String(localized: "Startup flow running · sync input locked")
        }
        if session.synchronizedPaneIDs.count > 1 {
            // TODO(plural)
            return String(localized: "\(session.synchronizedPaneIDs.count) synchronized panes")
        }
        return session.panes.count == 1
            ? statusText(session.status)
            // TODO(plural)
            : String(localized: "\(session.panes.count) panes")
    }

    private func startupStatusText(_ state: StartupFlowRunState) -> String {
        switch state {
        case .ready:
            return String(localized: "Startup flow ready")
        case .skipped:
            return String(localized: "Skipped for this connection")
        case let .running(stepIndex):
            return stepIndex.map { String(localized: "Startup: step \($0 + 1) running") }
                ?? String(localized: "Startup flow running")
        case .completed:
            return String(localized: "Startup flow completed")
        case let .failed(stepIndex, message):
            return String(localized: "Step \(stepIndex + 1) failed: \(message)")
        }
    }

    private func startupStatusColor(_ state: StartupFlowRunState) -> Color {
        switch state {
        case .ready, .skipped:
            return .secondary
        case .running:
            return .orange
        case .completed:
            return .green
        case .failed:
            return .red
        }
    }

    private func statusColor(_ status: TerminalPane.Status) -> Color {
        switch status {
        case .running:
            return .green
        case .exited:
            return .red
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("Search in terminal", text: $searchTerm)
                .textFieldStyle(.plain)
                .font(.callout)
                .focused($searchFieldFocused)
                .frame(width: 200)
                .onKeyPress(.return, phases: .down) { press in
                    runFind(forward: !press.modifiers.contains(.shift))
                    return .handled
                }
                // The terminal's performKeyEquivalent only fires while the terminal
                // itself is first responder, so ⌘G has to be handled here too.
                .onKeyPress(keys: ["g"], phases: .down) { press in
                    guard press.modifiers.contains(.command) else { return .ignored }
                    runFind(forward: !press.modifiers.contains(.shift))
                    return .handled
                }

            Text(searchCounterText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(searchSummary?.total ?? 0 > 0 ? .secondary : Color.secondary.opacity(0.6))
                .frame(minWidth: 42, alignment: .trailing)

            Button {
                runFind(forward: false)
            } label: {
                Image(systemName: "chevron.up")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.plain)
            .disabled(searchTerm.isEmpty)
            .help("Previous match (⇧⌘G)")

            Button {
                runFind(forward: true)
            } label: {
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.plain)
            .disabled(searchTerm.isEmpty)
            .help("Next match (⌘G)")

            Button {
                closeSearch()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
            }
            .buttonStyle(.plain)
            .help("Close search (Esc)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
        .padding(.top, 8)
        .padding(.trailing, 10)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .onExitCommand { closeSearch() }
        .onChange(of: searchTerm) { _, _ in scheduleIncrementalFind() }
    }

    private var searchCounterText: String {
        guard let summary = searchSummary, summary.total > 0 else { return "0/0" }
        return "\(summary.index)/\(summary.total)"
    }

    private func handleFindCommand(_ command: TerminalFindCommand, paneID: TerminalPane.ID) {
        switch command {
        case .open:
            if searchPaneID != paneID {
                closeSearch(returningFocus: false)
                searchPaneID = paneID
            }
            searchFieldFocused = true
        case .next, .previous:
            guard searchPaneID == paneID else {
                closeSearch(returningFocus: false)
                searchPaneID = paneID
                searchFieldFocused = true
                return
            }
            runFind(forward: command == .next)
        }
    }

    private func runFind(forward: Bool) {
        guard let paneID = searchPaneID else { return }
        searchTask?.cancel()
        guard !searchTerm.isEmpty else {
            engine.clearSearch(in: paneID)
            searchSummary = nil
            return
        }
        searchSummary = forward
            ? engine.findNext(searchTerm, in: paneID)
            : engine.findPrevious(searchTerm, in: paneID)
    }

    // Restart from the top on every edit so the match the counter points at is
    // always the first one, instead of walking forward as the term grows.
    private func scheduleIncrementalFind() {
        searchTask?.cancel()
        guard let paneID = searchPaneID else { return }
        guard !searchTerm.isEmpty else {
            engine.clearSearch(in: paneID)
            searchSummary = nil
            return
        }

        searchTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, searchPaneID == paneID else { return }
            engine.clearSearch(in: paneID)
            searchSummary = engine.findNext(searchTerm, in: paneID)
        }
    }

    /// - Parameter returningFocus: pass `false` when focus is already headed
    ///   elsewhere (pane/tab switch), otherwise the closing bar steals it back.
    private func closeSearch(returningFocus: Bool = true) {
        guard let paneID = searchPaneID else { return }
        searchTask?.cancel()
        searchTask = nil
        engine.clearSearch(in: paneID)
        searchPaneID = nil
        searchTerm = ""
        searchSummary = nil
        searchFieldFocused = false
        if returningFocus {
            engine.focusTerminal(paneID)
        }
    }

    // WP7: status band shown over an unexpectedly-disconnected pane. A user-
    // initiated tab/pane close never reaches this (the pane's gone from the
    // model before the view re-renders), so this always represents a
    // disconnect the user didn't ask for — hence "Bağlantı koptu" applies
    // uniformly, including a plain `exit` typed into the remote shell.
    @ViewBuilder
    private func exitedPaneOverlay(
        _ pane: TerminalPane,
        in session: TerminalSession,
        exitCode: Int32?
    ) -> some View {
        let reconnectState = model.paneReconnectStates[pane.id]
        let isRealHost = session.hostID != -1

        ZStack {
            Color.black.opacity(0.65)
                .background(.ultraThinMaterial)

            VStack(spacing: 16) {
                Image(systemName: exitCode == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(exitCode == 0 ? .green : .red)

                VStack(spacing: 6) {
                    Text("Connection lost")
                        .font(.headline)
                        .foregroundStyle(.primary)

                    if let code = exitCode {
                        Text("Terminal process exited (exit code: \(code)).")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Terminal process ended.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    if let statusText = reconnectStatusText(reconnectState) {
                        Text(statusText)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                if case let .countingDown(attempt, maxAttempts, fireDate) = reconnectState {
                    countdownView(attempt: attempt, maxAttempts: maxAttempts, fireDate: fireDate, paneID: pane.id)
                }

                HStack(spacing: 12) {
                    Button {
                        let profile = startupLibrary.profile(for: pane.alias)
                        model.manualReconnectRequested(pane.id, in: session.id, startupProfile: profile)
                    } label: {
                        Label("Reconnect", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)

                    Button(role: .destructive) {
                        model.closePane(pane.id, in: session.id)
                    } label: {
                        Text("Close Pane")
                    }
                    .buttonStyle(.bordered)
                }

                if isRealHost {
                    Toggle(
                        "Automatically reconnect to this server",
                        isOn: Binding(
                            get: { model.isAutoReconnectEnabled(forAlias: pane.alias) },
                            set: { newValue in
                                model.setAutoReconnectEnabled(
                                    newValue,
                                    forAlias: pane.alias,
                                    paneID: pane.id,
                                    sessionID: session.id
                                )
                            }
                        )
                    )
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(24)
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.92), in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
            }
            .shadow(radius: 12)
            .frame(maxWidth: 380)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Connection lost banner")
    }

    private func reconnectStatusText(_ state: AutoReconnectManager.State?) -> String? {
        switch state {
        case let .exhausted(attempts):
            return String(localized: "Automatic reconnect attempts exhausted (\(attempts)/\(AutoReconnectManager.maxAttempts)).")
        case .networkReturnedSuggestion:
            return String(localized: "Network connection is back — reconnect?")
        case .countingDown, .awaitingManualReconnect, nil:
            return nil
        }
    }

    /// Live "N sn içinde yeniden denenecek" countdown with a "Vazgeç" button
    /// that cancels the pending automatic attempt. Ticks once a second purely
    /// for display — the actual retry timer lives in `AutoReconnectManager`.
    private func countdownView(
        attempt: Int,
        maxAttempts: Int,
        fireDate: Date,
        paneID: TerminalPane.ID
    ) -> some View {
        TimelineView(.periodic(from: Date(), by: 1)) { context in
            let remaining = max(0, Int(fireDate.timeIntervalSince(context.date).rounded(.up)))
            HStack(spacing: 8) {
                Text("Automatic attempt \(attempt)/\(maxAttempts) — retrying in \(remaining)s")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Cancel") {
                    model.cancelReconnectCountdown(paneID)
                }
                .buttonStyle(.plain)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.accentColor)
            }
        }
    }
}
