import AppKit
import Observation
import ClipboardCore
import SwiftUI

enum PanelScope: Hashable {
    case history
    case suggested
    case pinboard(Int64)
}

enum InlineEdit: Equatable {
    case newPinboard(pinningClip: Int64?)
    case renamePinboard(Int64)
    case confirmDeletePinboard(Int64)
    case renameClip(Int64)
}

struct PanelActions {
    var paste: (Clip, _ invertFormatting: Bool) -> Void = { _, _ in }
    var copy: (Clip) -> Void = { _ in }
    var close: () -> Void = {}
    var openSettings: () -> Void = {}
    var toggleStack: () -> Void = {}
    var addToStack: (Clip) -> Void = { _ in }
    var requestDirectPaste: () -> Void = {}
    var resumeCapture: () -> Void = {}
}

private enum ReloadStyle {
    /// A new list: cards fan in from the start of the row.
    case reveal
    /// The search changed: cards slide into their new places and the row returns to the start.
    case search
    /// Something changed underneath: keep the selection and animate the difference.
    case refresh
}

@MainActor @Observable
final class PanelModel {
    @ObservationIgnored let store: ClipStore
    @ObservationIgnored var actions = PanelActions()
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var revealTask: Task<Void, Never>?
    @ObservationIgnored private var isLoadingMore = false
    @ObservationIgnored private static let pageSize = 60
    @ObservationIgnored private var isResetting = false
    @ObservationIgnored private(set) var stripScrollOffset: CGFloat = 0
    #if DEBUG
    var demoStripOffset: CGFloat = 0
    #endif

    var query = "" {
        didSet {
            guard query != oldValue, !isResetting else { return }
            searchTask?.cancel()
            searchTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(AppEnvironment.isDemo ? 0 : 70))
                guard !Task.isCancelled else { return }
                self?.reload(.search)
            }
        }
    }
    var scope: PanelScope = .history {
        didSet { if scope != oldValue, !isResetting { reload(.reveal) } }
    }
    var kind: ClipKind? {
        didSet { if kind != oldValue, !isResetting { reload(.reveal) } }
    }

    private(set) var clips: [Clip] = []
    private(set) var pinboards: [Pinboard] = []
    private(set) var hasLoaded = false
    private(set) var hasMore = false
    private(set) var listIdentity = 0
    private(set) var scrollResetToken = 0
    private(set) var isRevealing = false
    var selectedID: Int64?
    var firstVisibleIndex = 0
    var commandHeld = false
    var isPreviewing = false
    var isPresented = false
    var flyingClipID: Int64?
    var isDirectPasteEnabled = true
    var isCapturePaused = false
    var isStackActive = false
    var stackCount = 0
    var focusToken = 0
    var bottomGap: CGFloat = Metrics.shelfMargin

    var edit: InlineEdit?
    var editText = ""
    var editColor = PinboardPalette.names[3]

    var targetApp: NSRunningApplication?

    init(store: ClipStore) {
        self.store = store
    }

    var selectedClip: Clip? {
        guard let selectedID else { return nil }
        return clips.first { $0.id == selectedID }
    }

    var resultCountLabel: String {
        let count = clips.count
        return hasMore ? "\(count)+" : "\(count)"
    }

    private var showsSuggestions: Bool { scope == .suggested && query.isEmpty }

    // MARK: Loading

    func prepareForShow(target: NSRunningApplication?) {
        targetApp = target
        ClipDrag.currentClipID = nil
        searchTask?.cancel()
        isResetting = true
        query = ""
        kind = nil
        scope = .history
        isResetting = false
        edit = nil
        isPreviewing = false
        commandHeld = false
        flyingClipID = nil
        focusToken += 1
        reload(.reveal)
    }

    func refresh() {
        reload(.refresh)
    }

    private func reload(_ style: ReloadStyle) {
        generation += 1
        let generation = generation
        let store = store
        let suggestions = showsSuggestions
        let bundleID = targetApp?.bundleIdentifier
        let limit = style == .refresh ? max(Self.pageSize, clips.count) : Self.pageSize
        let request = makeQuery(limit: limit, offset: 0)
        let kind = kind
        Task.detached(priority: .userInitiated) { [weak self] in
            var rows: [Clip]
            if suggestions {
                rows = (try? store.suggestions(forApp: bundleID)) ?? []
                if let kind { rows = rows.filter { $0.kind == kind } }
            } else {
                rows = (try? store.clips(request)) ?? []
            }
            let boards = (try? store.pinboards()) ?? []
            await self?.apply(rows, boards: boards, style: style, limit: suggestions ? nil : limit, generation: generation)
        }
    }

    private func makeQuery(limit: Int, offset: Int) -> ClipQuery {
        var boardID: Int64?
        if case .pinboard(let id) = scope { boardID = id }
        return ClipQuery(text: query, kind: kind, pinboardID: boardID, limit: limit, offset: offset)
    }

    private func apply(_ rows: [Clip], boards: [Pinboard], style: ReloadStyle, limit: Int?, generation: Int) {
        guard generation == self.generation else { return }
        hasLoaded = true
        hasMore = limit.map { rows.count >= $0 } ?? false
        switch style {
        case .reveal:
            beginReveal()
            clips = rows
            pinboards = boards
            // A new identity rebuilds the cards, which puts the row back at its start and replays their entrance.
            listIdentity += 1
            firstVisibleIndex = 0
            selectedID = rows.first?.id
        case .search:
            withAnimation(Motion.snappy) {
                clips = rows
                pinboards = boards
                selectedID = rows.first?.id
            }
            firstVisibleIndex = 0
            scrollResetToken += 1
        case .refresh:
            withAnimation(Motion.snappy) {
                clips = rows
                pinboards = boards
                if !rows.contains(where: { $0.id == selectedID }) { selectedID = rows.first?.id }
            }
        }
    }

    private func beginReveal() {
        revealTask?.cancel()
        isRevealing = !Motion.isReduced
        revealTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            self?.isRevealing = false
        }
    }

    func cardAppeared(at index: Int) {
        guard hasMore, !isLoadingMore, index >= clips.count - 12 else { return }
        isLoadingMore = true
        let generation = generation
        let store = store
        let request = makeQuery(limit: Self.pageSize, offset: clips.count)
        Task.detached(priority: .userInitiated) { [weak self] in
            let rows = (try? store.clips(request)) ?? []
            await self?.appendPage(rows, limit: request.limit, generation: generation)
        }
    }

    private func appendPage(_ rows: [Clip], limit: Int, generation: Int) {
        isLoadingMore = false
        guard generation == self.generation else { return }
        let known = Set(clips.map(\.id))
        clips.append(contentsOf: rows.filter { !known.contains($0.id) })
        hasMore = rows.count >= limit
    }

    func updateFirstVisible(contentOffset: CGFloat) {
        stripScrollOffset = contentOffset
        let pitch = Metrics.cardWidth + Metrics.cardSpacing
        let index = max(0, Int((contentOffset / pitch).rounded(.up)))
        if index != firstVisibleIndex { firstVisibleIndex = index }
    }

    // MARK: Selection and paste

    func select(_ clip: Clip) {
        withAnimation(Motion.snappy) { selectedID = clip.id }
    }

    func moveSelection(by delta: Int) {
        guard !clips.isEmpty else { return }
        let current = clips.firstIndex { $0.id == selectedID } ?? 0
        let target = clips[min(max(current + delta, 0), clips.count - 1)].id
        withAnimation(Motion.snappy) { selectedID = target }
    }

    func selectFirst() {
        withAnimation(Motion.snappy) { selectedID = clips.first?.id }
    }

    func selectLast() {
        withAnimation(Motion.snappy) { selectedID = clips.last?.id }
    }

    func pasteSelected(invertFormatting: Bool) {
        if let clip = selectedClip { actions.paste(clip, invertFormatting) }
    }

    func pasteVisible(number: Int) {
        let index = firstVisibleIndex + number - 1
        guard clips.indices.contains(index) else { return }
        actions.paste(clips[index], false)
    }

    func shortcutNumber(forIndex index: Int) -> Int? {
        guard commandHeld else { return nil }
        let number = index - firstVisibleIndex + 1
        return (1...9).contains(number) ? number : nil
    }

    func deleteSelected() {
        if let clip = selectedClip { delete(clip) }
    }

    func delete(_ clip: Clip) {
        let index = clips.firstIndex { $0.id == clip.id } ?? 0
        try? store.delete(clipID: clip.id)
        withAnimation(Motion.snappy) {
            clips.removeAll { $0.id == clip.id }
            if clips.indices.contains(index) {
                selectedID = clips[index].id
            } else {
                selectedID = clips.last?.id
            }
        }
    }

    func setScope(_ newScope: PanelScope) {
        withAnimation(Motion.snappy) { scope = newScope }
    }

    func toggleKind(_ newKind: ClipKind) {
        withAnimation(Motion.snappy) { kind = kind == newKind ? nil : newKind }
    }

    func cycleScope(by delta: Int) {
        let scopes: [PanelScope] = [.history, .suggested] + pinboards.map { .pinboard($0.id) }
        let current = scopes.firstIndex(of: scope) ?? 0
        setScope(scopes[(current + delta + scopes.count) % scopes.count])
    }

    // MARK: Pinboards

    func togglePin(_ clip: Clip, board: Pinboard) {
        if clip.pinboardIDs.contains(board.id) {
            try? store.unpin(clipID: clip.id, pinboardID: board.id)
        } else {
            try? store.pin(clipID: clip.id, pinboardID: board.id)
        }
        reload(.refresh)
    }

    func pin(clipID: Int64, to board: Pinboard) {
        try? store.pin(clipID: clipID, pinboardID: board.id)
        reload(.refresh)
    }

    func beginNewPinboard(pinning clip: Clip? = nil) {
        editText = ""
        editColor = PinboardPalette.names[pinboards.count % PinboardPalette.names.count]
        startEdit(.newPinboard(pinningClip: clip?.id))
    }

    func beginRename(_ board: Pinboard) {
        editText = board.name
        editColor = board.color
        startEdit(.renamePinboard(board.id))
    }

    func beginDelete(_ board: Pinboard) {
        startEdit(.confirmDeletePinboard(board.id))
    }

    func beginRename(_ clip: Clip) {
        editText = clip.title ?? ""
        startEdit(.renameClip(clip.id))
    }

    private func startEdit(_ newEdit: InlineEdit) {
        withAnimation(Motion.snappy) { edit = newEdit }
        focusToken += 1
    }

    func commitEdit() {
        guard let edit else { return }
        let text = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch edit {
        case .newPinboard(let clipID):
            guard !text.isEmpty else { return }
            if let board = try? store.createPinboard(name: text, color: editColor), let clipID {
                try? store.pin(clipID: clipID, pinboardID: board.id)
            }
        case .renamePinboard(let id):
            guard !text.isEmpty else { return }
            try? store.updatePinboard(id: id, name: text, color: editColor)
        case .confirmDeletePinboard(let id):
            try? store.deletePinboard(id: id)
            if scope == .pinboard(id) { setScope(.history) }
        case .renameClip(let id):
            try? store.rename(clipID: id, title: text)
        }
        finishEdit()
        reload(.refresh)
    }

    func cancelEdit() { finishEdit() }

    private func finishEdit() {
        withAnimation(Motion.snappy) { edit = nil }
        editText = ""
        focusToken += 1
    }
}
