import AppKit
import ClipboardCore
import SwiftUI

struct SyncPage: View {
    @Bindable var sync: SyncController
    @Bindable private var preferences = Preferences.shared
    @Namespace private var selection
    @State private var passphrase = ""
    @State private var clientID = ""
    @State private var clientSecret = ""
    @State private var isConfirmingStartOver = false

    private var mode: SyncMode { preferences.syncMode }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 10) {
                choice(.off, title: "Off", detail: "Clips stay on this Mac.", symbol: "nosign", tint: Theme.tileSlate)
                choice(.iCloud, title: "iCloud Drive", detail: "Between your Macs. Nothing to set up.", symbol: "icloud.fill", tint: Theme.tileSky)
                choice(.googleDrive, title: "Google Drive", detail: "Ready for other platforms. Uses your own Google app.", symbol: "externaldrive.fill.badge.icloud", tint: Theme.accentDeep)
            }
            if mode == .googleDrive { googleSection }
            if sync.status != .off, sync.status != .needsGoogleApp { encryptionSection }
            if mode != .off, sync.status != .needsGoogleApp, sync.status != .needsPassphrase { statusSection }
            if mode != .off {
                Text("Files, text that looks like a secret and clips over 25 MB stay on this Mac.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 3)
                    .padding(.top, -12)
            }
        }
        .onAppear {
            clientID = sync.clientID
            clientSecret = sync.clientSecret
        }
    }

    private func choice(_ value: SyncMode, title: String, detail: String, symbol: String, tint: Color) -> some View {
        let isSelected = mode == value
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return Button {
            withAnimation(Motion.bouncy) { preferences.syncMode = value }
        } label: {
            VStack(alignment: .leading, spacing: 9) {
                IconTile(symbol: symbol, tint: tint)
                    .symbolEffect(.bounce, value: isSelected)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(12)
            .background(Theme.settingsCard, in: shape)
            .overlay { shape.strokeBorder(.primary.opacity(0.08), lineWidth: 0.5) }
            .overlay {
                if isSelected {
                    shape.strokeBorder(Theme.ringGradient, lineWidth: 2)
                        .matchedGeometryEffect(id: "sync", in: selection)
                }
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: Google

    @ViewBuilder private var googleSection: some View {
        if sync.isGoogleConnected {
            SettingsCard(title: "Google Drive") {
                SettingRow(
                    symbol: "checkmark.circle.fill", tint: Theme.tileMint, title: "Connected",
                    detail: sync.googleAccount.map { "Syncing to a hidden folder in \($0)'s Drive." } ?? "Syncing to a hidden folder in your Drive."
                ) {
                    Button("Disconnect") { withAnimation(Motion.snappy) { sync.disconnectGoogle() } }
                        .buttonStyle(PillButtonStyle())
                }
            }
        } else {
            SettingsCard(title: "Create your own Google app first") {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Clipboard has no servers and no Google app of its own, so you make a small one in your Google account. It's free and takes about five minutes. It can only reach its own hidden folder in your Drive, never your files.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(13)
                    RowDivider()
                    step(1, "Create a project", "Any name works.", "https://console.cloud.google.com/projectcreate")
                    step(2, "Turn on the Google Drive API", "Check your new project is the one selected.", "https://console.cloud.google.com/flows/enableapi?apiid=drive.googleapis.com")
                    step(3, "Set up the sign-in screen", "Click Get Started, name it anything, and choose External.", "https://console.cloud.google.com/auth/branding")
                    step(4, "Publish the app", "Click Publish app. If you skip this, Google signs you out every 7 days.", "https://console.cloud.google.com/auth/audience")
                    step(5, "Create a client", "Click Create Client, choose Desktop app, and copy its ID and secret below.", "https://console.cloud.google.com/auth/clients")
                    RowDivider()
                    credentials
                }
            }
        }
    }

    private func step(_ number: Int, _ title: String, _ detail: String, _ link: String) -> some View {
        HStack(spacing: 11) {
            Text("\(number)")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.onAccent)
                .frame(width: 22, height: 22)
                .background(Theme.accentGradient, in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 10)
            Button("Open") {
                if let url = URL(string: link) { NSWorkspace.shared.open(url) }
            }
            .buttonStyle(PillButtonStyle())
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 7)
    }

    private var credentials: some View {
        VStack(alignment: .leading, spacing: 9) {
            TextField("Client ID", text: $clientID)
                .textFieldStyle(.roundedBorder)
            SecureField("Client secret", text: $clientSecret)
                .textFieldStyle(.roundedBorder)
            if let problem = sync.googleProblem { problemText(problem) }
            HStack(spacing: 7) {
                if sync.isConnectingGoogle {
                    Button("Connect Google Drive") {}
                        .buttonStyle(PillButtonStyle(kind: .primary))
                        .disabled(true)
                        .opacity(0.6)
                    Button("Cancel") { sync.cancelGoogleConnection() }
                        .buttonStyle(PillButtonStyle())
                    Text("Finish signing in in your browser.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                } else {
                    Button("Connect Google Drive") { sync.connectGoogle(clientID: clientID, clientSecret: clientSecret) }
                        .buttonStyle(PillButtonStyle(kind: .primary))
                        .disabled(clientID.isEmpty || clientSecret.isEmpty)
                }
                Spacer()
            }
            Text("If Google warns the app isn't verified, that's expected because it's your own: choose Advanced, then continue. Use this same client on every device, since Drive keeps the folder per app.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(13)
    }

    // MARK: Encryption

    @ViewBuilder private var encryptionSection: some View {
        if sync.status == .needsPassphrase {
            SettingsCard(title: "Choose a passphrase") {
                VStack(alignment: .leading, spacing: 9) {
                    Text("Clips are encrypted on this Mac before they leave it, so \(mode == .iCloud ? "Apple" : "Google") can't read them. Use the same passphrase on every device. Nobody can recover it for you, so keep it somewhere safe.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    SecureField("Passphrase", text: $passphrase)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(unlock)
                    if let problem = sync.passphraseProblem { problemText(problem) }
                    HStack(spacing: 7) {
                        Button(sync.isUnlocking ? "Setting up…" : "Turn on sync", action: unlock)
                            .buttonStyle(PillButtonStyle(kind: .primary))
                            .disabled(passphrase.isEmpty || sync.isUnlocking)
                        Spacer()
                        startOverButton
                    }
                    if isConfirmingStartOver { startOverConfirmation }
                }
                .padding(13)
            }
        }
    }

    private func unlock() {
        sync.unlock(passphrase: passphrase)
        passphrase = ""
    }

    private var startOverButton: some View {
        Button("Lost it? Start over") {
            withAnimation(Motion.snappy) { isConfirmingStartOver = true }
        }
        .buttonStyle(.plain)
        .font(.system(size: 11.5))
        .foregroundStyle(.secondary)
    }

    private var startOverConfirmation: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("This erases the synced copy, and every device will need the new passphrase. The clips on your Macs stay.")
                .font(.system(size: 12, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 7) {
                Button("Keep it") { withAnimation(Motion.snappy) { isConfirmingStartOver = false } }
                    .buttonStyle(PillButtonStyle())
                Button("Erase synced copy") {
                    sync.startOver()
                    withAnimation(Motion.snappy) { isConfirmingStartOver = false }
                }
                .buttonStyle(PillButtonStyle(kind: .destructive))
            }
        }
        .padding(11)
        .background(Color.red.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: Status

    private var statusSection: some View {
        SettingsCard(title: "Status") {
            SettingRow(symbol: statusSymbol, tint: statusTint, title: statusTitle, detail: statusDetail) {
                Button("Sync now") { sync.syncNow() }
                    .buttonStyle(PillButtonStyle())
                    .disabled(sync.status == .syncing)
            }
            RowDivider()
            SettingRow(
                symbol: "arrow.counterclockwise", tint: Theme.tileSlate, title: "Start over",
                detail: "Erases the synced copy, for a lost passphrase. The clips on your Macs stay."
            ) {
                startOverButtonForStatus
            }
            if isConfirmingStartOver {
                startOverConfirmation.padding(.horizontal, 13).padding(.bottom, 11)
            }
        }
    }

    private var startOverButtonForStatus: some View {
        Button("Start over…") {
            withAnimation(Motion.snappy) { isConfirmingStartOver = true }
        }
        .buttonStyle(PillButtonStyle())
    }

    private var statusSymbol: String {
        if case .failed = sync.status { return "exclamationmark.triangle.fill" }
        return sync.status == .syncing ? "arrow.triangle.2.circlepath" : "checkmark.circle.fill"
    }

    private var statusTint: Color {
        if case .failed = sync.status { return Theme.tileSun }
        return Theme.tileMint
    }

    private var statusTitle: String {
        switch sync.status {
        case .syncing: "Syncing"
        case .failed: "Sync stopped"
        default: "Up to date"
        }
    }

    private var statusDetail: String {
        if case .failed(let message) = sync.status { return message }
        guard let last = sync.lastSynced else { return "Waiting for the first sync." }
        return "Last synced \(ClipFormat.relativeTime(last).lowercased()). Clips sync every couple of minutes, and iCloud or Google may take longer to deliver them."
    }

    private func problemText(_ problem: String) -> some View {
        Text(problem)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
    }
}
