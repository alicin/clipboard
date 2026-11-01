import AppKit
import ClipboardCore
import SwiftUI
import UniformTypeIdentifiers

/// Fills a transparent window. The shelf rises inside it, so a real spring can drive the glass itself.
struct ShelfRoot: View {
    let model: PanelModel

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Metrics.shelfRadius, style: .continuous)
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            ShelfView(model: model)
                .frame(height: Metrics.shelfHeight)
                .clipShape(shape)
                .glassSurface(cornerRadius: Metrics.shelfRadius)
                .padding(.horizontal, Metrics.shelfMargin)
                .padding(.bottom, model.bottomGap)
                .offset(y: model.isPresented ? 0 : Metrics.shelfHeight + model.bottomGap + 40)
                .opacity(model.isPresented ? 1 : 0)
        }
        .tint(Theme.accent)
    }
}

private struct ShelfView: View {
    @Bindable var model: PanelModel

    var body: some View {
        VStack(spacing: 0) {
            TopBar(model: model)
                .frame(height: Metrics.barHeight)
                // Above the strip, so a card's glow passes behind the controls.
                .zIndex(1)
            ZStack {
                if model.clips.isEmpty {
                    if model.hasLoaded {
                        EmptyShelf(model: model)
                            .transition(.opacity.combined(with: .scale(scale: 0.97)))
                    }
                } else {
                    CardStrip(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(Motion.snappy, value: model.clips.isEmpty)
        }
    }
}

// MARK: - Top bar

private struct TopBar: View {
    @Bindable var model: PanelModel
    @Namespace private var highlight

    var body: some View {
        HStack(spacing: 12) {
            if let edit = model.edit {
                InlineEditBar(model: model, edit: edit)
                    .transition(.move(edge: .top).combined(with: .opacity))
            } else {
                HStack(spacing: 12) {
                    SearchBox(model: model)
                    ScopeChips(model: model, namespace: highlight)
                    Spacer(minLength: 8)
                    trailing
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.horizontal, Metrics.stripInset)
    }

    @ViewBuilder private var trailing: some View {
        if model.commandHeld {
            CommandHints()
                .transition(.opacity.combined(with: .offset(x: 10)))
        } else {
            HStack(spacing: 12) {
                statusNotes
                KindFilter(model: model, namespace: highlight)
                Rectangle().fill(.primary.opacity(0.12)).frame(width: 1, height: 18)
                StackButton(model: model)
                SettingsButton(model: model)
            }
            .transition(.opacity)
        }
    }

    @ViewBuilder private var statusNotes: some View {
        if model.isCapturePaused {
            Button {
                model.actions.resumeCapture()
            } label: {
                Label("Resume saving", systemImage: "play.fill")
            }
            .buttonStyle(NoteButtonStyle())
        }
        if !model.isDirectPasteEnabled {
            Button {
                model.actions.requestDirectPaste()
            } label: {
                Label("Turn on direct paste", systemImage: "bolt.fill")
            }
            .buttonStyle(NoteButtonStyle())
            .help("Choosing a clip copies it for you. To drop it straight into the app, allow Accessibility access.")
        }
    }
}

private struct CommandHints: View {
    var body: some View {
        HStack(spacing: 14) {
            hint("⌘1–9", "Paste")
            hint("⌘C", "Copy")
            hint("⌘⌫", "Delete")
            hint("⌘,", "Settings")
        }
    }

    private func hint(_ keys: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Keycap(text: keys, isSmall: true)
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }
}

private struct SearchBox: View {
    @Bindable var model: PanelModel

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(model.query.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.accentDeep))
                .symbolEffect(.bounce, value: model.query.isEmpty)
            ShelfTextField(text: $model.query, placeholder: "Search", focusToken: model.focusToken)
                .frame(height: 20)
            if !model.query.isEmpty {
                Text(model.resultCountLabel)
                    .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                    .transition(.opacity)
                Button {
                    model.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .frame(width: model.query.isEmpty ? 228 : 300, height: 34)
        .background(.primary.opacity(0.07), in: Capsule())
        .animation(Motion.snappy, value: model.query.isEmpty)
        .animation(Motion.snappy, value: model.resultCountLabel)
    }
}

private struct ScopeChips: View {
    @Bindable var model: PanelModel
    let namespace: Namespace.ID

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 2) {
                Chip(title: "History", symbol: nil, dot: nil, isSelected: model.scope == .history, namespace: namespace) {
                    model.setScope(.history)
                }
                Chip(title: "Suggested", symbol: "sparkles", dot: nil, isSelected: model.scope == .suggested, namespace: namespace) {
                    model.setScope(.suggested)
                }
                .help(suggestionHelp)

                if !model.pinboards.isEmpty {
                    Rectangle().fill(.primary.opacity(0.12)).frame(width: 1, height: 16).padding(.horizontal, 6)
                }
                ForEach(model.pinboards) { board in
                    PinboardChip(model: model, board: board, namespace: namespace)
                        .transition(.scale.combined(with: .opacity))
                }
                Button {
                    model.beginNewPinboard()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11.5, weight: .bold))
                        .frame(width: 30, height: 30)
                        .contentShape(Circle())
                }
                .buttonStyle(HoverButtonStyle())
                .help("New pinboard")
                .accessibilityLabel("New pinboard")
            }
            // Room inside the scroller, which would otherwise cut off the shadows of the selected and targeted chips.
            .padding(.vertical, 12)
            .padding(.horizontal, 10)
        }
        .scrollIndicators(.never)
        .padding(.horizontal, -10)
    }

    private var suggestionHelp: String {
        if let name = model.targetApp?.localizedName { return "What you're likely to paste into \(name)" }
        return "What you're likely to paste next"
    }
}

private struct PinboardChip: View {
    @Bindable var model: PanelModel
    let board: Pinboard
    let namespace: Namespace.ID
    @State private var isTargeted = false

    private var isHighlighted: Bool {
        #if DEBUG
        if DemoControl.shared.dropTargetBoardID == board.id { return true }
        #endif
        return isTargeted
    }

    var body: some View {
        Chip(
            title: board.name, symbol: nil, dot: PinboardPalette.color(board.color),
            isSelected: model.scope == .pinboard(board.id), namespace: namespace
        ) {
            model.setScope(.pinboard(board.id))
        }
        .scaleEffect(isHighlighted ? 1.14 : 1)
        .shadow(color: PinboardPalette.color(board.color).opacity(isHighlighted ? 0.7 : 0), radius: 10)
        .animation(Motion.bouncy, value: isHighlighted)
        .contextMenu {
            Button("Rename…") { model.beginRename(board) }
            Button("Delete pinboard…", role: .destructive) { model.beginDelete(board) }
        }
        .onDrop(of: [UTType.item], isTargeted: $isTargeted) { _ in
            guard let clipID = ClipDrag.currentClipID else { return false }
            ClipDrag.currentClipID = nil
            model.pin(clipID: clipID, to: board)
            return true
        }
    }
}

private struct Chip: View {
    let title: String
    let symbol: String?
    let dot: Color?
    let isSelected: Bool
    let namespace: Namespace.ID
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let dot {
                    Circle()
                        .fill(dot)
                        .frame(width: 9, height: 9)
                        .overlay { Circle().strokeBorder(.white.opacity(isSelected ? 0.7 : 0), lineWidth: 1) }
                }
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .symbolEffect(.bounce, value: isSelected)
                }
                Text(title)
                    .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? AnyShapeStyle(Theme.onAccent) : AnyShapeStyle(.primary))
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background {
                if isSelected {
                    Capsule()
                        .fill(Theme.accentGradient)
                        .shadow(color: Theme.accent.opacity(0.4), radius: 6, y: 2)
                        .matchedGeometryEffect(id: "scope", in: namespace)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(HoverButtonStyle())
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct KindFilter: View {
    @Bindable var model: PanelModel
    let namespace: Namespace.ID

    var body: some View {
        HStack(spacing: 0) {
            ForEach(ClipKind.allCases, id: \.self) { kind in
                let isOn = model.kind == kind
                Button {
                    model.toggleKind(kind)
                } label: {
                    Image(systemName: kind.symbol)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(isOn ? AnyShapeStyle(Theme.onAccent) : AnyShapeStyle(.secondary))
                        .frame(width: 30, height: 30)
                        .background {
                            if isOn {
                                Circle()
                                    .fill(Theme.accentGradient)
                                    .matchedGeometryEffect(id: "kind", in: namespace)
                            }
                        }
                        .contentShape(Circle())
                }
                .buttonStyle(HoverButtonStyle())
                .help(kind.pluralName)
                .accessibilityLabel(kind.pluralName)
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
    }
}

private struct StackButton: View {
    let model: PanelModel

    var body: some View {
        Button {
            model.actions.toggleStack()
        } label: {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(model.isStackActive ? AnyShapeStyle(Theme.onAccent) : AnyShapeStyle(.secondary))
                .symbolEffect(.bounce, value: model.stackCount)
                .frame(width: 30, height: 30)
                .background {
                    if model.isStackActive {
                        Circle().fill(Theme.accentGradient).transition(.scale.combined(with: .opacity))
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if model.stackCount > 0 {
                        Text("\(model.stackCount)")
                            .font(.system(size: 9.5, weight: .bold).monospacedDigit())
                            .foregroundStyle(.white)
                            .contentTransition(.numericText())
                            .frame(minWidth: 14, minHeight: 14)
                            .background(Theme.accentDeep, in: Capsule())
                            .offset(x: 3, y: -2)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .contentShape(Circle())
                .animation(Motion.bouncy, value: model.isStackActive)
                .animation(Motion.bouncy, value: model.stackCount)
        }
        .buttonStyle(HoverButtonStyle())
        .help("Paste Stack")
        .accessibilityLabel("Paste Stack")
    }
}

private struct SettingsButton: View {
    let model: PanelModel
    @State private var isHovering = false

    var body: some View {
        Button {
            model.actions.openSettings()
        } label: {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isHovering ? 60 : 0))
                .frame(width: 30, height: 30)
                .contentShape(Circle())
        }
        .buttonStyle(HoverButtonStyle())
        .onHover { hovering in withAnimation(Motion.bouncy) { isHovering = hovering } }
        .help("Settings")
        .accessibilityLabel("Settings")
    }
}

private struct HoverButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverBody(configuration: configuration)
    }

    private struct HoverBody: View {
        let configuration: Configuration
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .background(.primary.opacity(isHovering ? 0.08 : 0), in: Capsule())
                .scaleEffect(configuration.isPressed ? 0.92 : 1)
                .animation(Motion.snappy, value: configuration.isPressed)
                .animation(.easeOut(duration: 0.12), value: isHovering)
                .onHover { isHovering = $0 }
        }
    }
}

private struct NoteButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Theme.onAccent)
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(Theme.accentGradient, in: Capsule())
            .shadow(color: Theme.accent.opacity(0.4), radius: 6, y: 2)
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(Motion.snappy, value: configuration.isPressed)
    }
}

private struct PrimaryPillStyle: ButtonStyle {
    var isDestructive = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(isDestructive ? AnyShapeStyle(.white) : AnyShapeStyle(Theme.onAccent))
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background(
                isDestructive ? AnyShapeStyle(Color.red) : AnyShapeStyle(Theme.accentGradient), in: Capsule()
            )
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(Motion.snappy, value: configuration.isPressed)
    }
}

private struct QuietPillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background(.primary.opacity(configuration.isPressed ? 0.14 : 0.08), in: Capsule())
    }
}

private struct InlineEditBar: View {
    @Bindable var model: PanelModel
    let edit: InlineEdit

    var body: some View {
        switch edit {
        case .confirmDeletePinboard(let id):
            let name = model.pinboards.first { $0.id == id }?.name ?? "this pinboard"
            Image(systemName: "trash.fill").foregroundStyle(.red)
            Text("Delete \(name)? Its clips stay in your history.")
                .font(.system(size: 13, weight: .medium))
            Spacer()
            Button("Cancel") { model.cancelEdit() }.buttonStyle(QuietPillStyle())
            Button("Delete pinboard") { model.commitEdit() }.buttonStyle(PrimaryPillStyle(isDestructive: true))
        case .renameClip:
            nameField(placeholder: "Clip name")
            Spacer()
            Button("Cancel") { model.cancelEdit() }.buttonStyle(QuietPillStyle())
            Button("Save name") { model.commitEdit() }.buttonStyle(PrimaryPillStyle())
        case .newPinboard, .renamePinboard:
            colorPicker
            nameField(placeholder: "Pinboard name")
            Spacer()
            Button("Cancel") { model.cancelEdit() }.buttonStyle(QuietPillStyle())
            Button(isNew ? "Create pinboard" : "Save pinboard") { model.commitEdit() }
                .buttonStyle(PrimaryPillStyle())
                .opacity(model.editText.trimmingCharacters(in: .whitespaces).isEmpty ? 0.45 : 1)
                .disabled(model.editText.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private var isNew: Bool {
        if case .newPinboard = edit { return true }
        return false
    }

    private func nameField(placeholder: String) -> some View {
        ShelfTextField(text: $model.editText, placeholder: placeholder, focusToken: model.focusToken)
            .frame(width: 260, height: 20)
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(.primary.opacity(0.07), in: Capsule())
    }

    private var colorPicker: some View {
        HStack(spacing: 7) {
            ForEach(PinboardPalette.names, id: \.self) { name in
                let isSelected = model.editColor == name
                Button {
                    withAnimation(Motion.bouncy) { model.editColor = name }
                } label: {
                    Circle()
                        .fill(PinboardPalette.color(name))
                        .frame(width: 18, height: 18)
                        .overlay {
                            if isSelected {
                                Circle().strokeBorder(.white, lineWidth: 2)
                                    .transition(.scale.combined(with: .opacity))
                            }
                        }
                        .scaleEffect(isSelected ? 1.2 : 1)
                        .shadow(color: PinboardPalette.color(name).opacity(isSelected ? 0.6 : 0), radius: 5)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(name)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
    }
}

private struct ShelfTextField: View {
    @Binding var text: String
    let placeholder: String
    let focusToken: Int

    var body: some View {
        #if DEBUG
        if AppEnvironment.isDemo {
            DemoTextField(text: text, placeholder: placeholder)
        } else {
            FocusedTextField(text: $text, placeholder: placeholder, focusToken: focusToken)
        }
        #else
        FocusedTextField(text: $text, placeholder: placeholder, focusToken: focusToken)
        #endif
    }
}

/// An AppKit field so focus can be forced deterministically: SwiftUI's FocusState is unreliable in a panel
/// that becomes key without its app activating.
struct FocusedTextField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let focusToken: Int

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> FocusableTextField {
        let field = FocusableTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13.5)
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        field.setAccessibilityLabel(placeholder)
        return field
    }

    func updateNSView(_ field: FocusableTextField, context: Context) {
        context.coordinator.text = $text
        if field.stringValue != text { field.stringValue = text }
        if context.coordinator.lastFocusToken != focusToken {
            context.coordinator.lastFocusToken = focusToken
            field.requestFocus()
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        var lastFocusToken = -1

        init(text: Binding<String>) {
            self.text = text
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}

final class FocusableTextField: NSTextField {
    private var wantsFocus = false

    func requestFocus() {
        wantsFocus = true
        focusIfPossible()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        focusIfPossible()
    }

    // SwiftUI can ask for focus before the field is in a window, so the request has to wait until it is.
    private func focusIfPossible() {
        guard wantsFocus, let window else { return }
        wantsFocus = false
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            window.makeFirstResponder(self)
            self.currentEditor()?.selectedRange = NSRange(location: self.stringValue.utf16.count, length: 0)
        }
    }
}

// MARK: - Empty states

private struct EmptyShelf: View {
    let model: PanelModel

    var body: some View {
        HStack(spacing: 26) {
            GhostCards()
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 17, weight: .semibold))
                Text(detail).font(.system(size: 13)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 18)
    }

    private var title: String {
        if !model.query.isEmpty { return "No clips match \u{201C}\(model.query)\u{201D}" }
        if let kind = model.kind { return "No \(kind.pluralName.lowercased()) here" }
        switch model.scope {
        case .history: return "Your history is empty"
        case .suggested: return "No suggestions yet"
        case .pinboard: return "This pinboard is empty"
        }
    }

    private var detail: String {
        if !model.query.isEmpty { return "Try fewer words, or search all of History." }
        if model.kind != nil { return "Turn off the filter to see everything." }
        switch model.scope {
        case .history: return "Copy something in any app and it lands here."
        case .suggested: return "Suggestions build up as you copy and paste between apps."
        case .pinboard: return "Drag a clip onto this pinboard's name to keep it here."
        }
    }
}

private struct GhostCards: View {
    @State private var isFanned = false

    var body: some View {
        ZStack {
            ForEach(0..<3) { index in
                let offset = CGFloat(index - 1)
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Theme.cardPaper)
                    .frame(width: 62, height: 74)
                    .overlay(alignment: .top) {
                        UnevenRoundedRectangle(topLeadingRadius: 11, topTrailingRadius: 11, style: .continuous)
                            .fill(index == 1 ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.cardTint))
                            .frame(height: 18)
                    }
                    .rotationEffect(.degrees(isFanned ? Double(offset) * 12 : 0))
                    .offset(x: isFanned ? offset * 24 : 0, y: isFanned ? abs(offset) * 6 : 0)
                    .shadow(color: .black.opacity(0.16), radius: 6, y: 3)
                    .zIndex(index == 1 ? 1 : 0)
            }
        }
        .frame(width: 130, height: 100)
        .onAppear {
            withAnimation(Motion.bouncy.delay(0.08)) { isFanned = true }
        }
    }
}
