import SwiftUI
import MWDATCore

// MARK: - Stream Mode

enum StreamMode: String, CaseIterable {
    case twitch = "Twitch"
    case jitsi = "Jitsi Meeting"
}

// MARK: - Main Content View

struct ContentView: View {
    // Persisted settings
    @AppStorage("twitch_key") private var twitchStreamKey: String = ""
    @AppStorage("jitsi_room") private var jitsiRoomName: String = ""
    @AppStorage("jitsi_server") private var jitsiServer: String = "https://meet.jit.si"
    @AppStorage("display_name") private var displayName: String = ""
    @AppStorage("selected_mode") private var selectedModeRaw: String = StreamMode.twitch.rawValue

    // Managers
    @StateObject private var streamManager = StreamManager()
    @StateObject private var twitchManager = TwitchManager()
    @StateObject private var jitsiManager = JitsiManager()
    @StateObject private var jitsiFrameInjector = JitsiFrameInjector()

    // UI State
    @State private var showingSetup = true

    var selectedMode: StreamMode {
        get { StreamMode(rawValue: selectedModeRaw) ?? .twitch }
        set { selectedModeRaw = newValue.rawValue }
    }

    var body: some View {
        Group {
            if showingSetup {
                SetupView(
                    twitchStreamKey: $twitchStreamKey,
                    jitsiRoomName: $jitsiRoomName,
                    jitsiServer: $jitsiServer,
                    displayName: $displayName,
                    selectedModeRaw: $selectedModeRaw,
                    onContinue: {
                        showingSetup = false
                    }
                )
            } else {
                MainStreamingView(
                    streamManager: streamManager,
                    twitchManager: twitchManager,
                    jitsiManager: jitsiManager,
                    jitsiFrameInjector: jitsiFrameInjector,
                    selectedMode: selectedMode,
                    twitchStreamKey: twitchStreamKey,
                    jitsiRoomName: jitsiRoomName,
                    jitsiServer: jitsiServer,
                    displayName: displayName,
                    onBack: {
                        showingSetup = true
                    }
                )
            }
        }
        .onAppear {
            // Link managers together
            streamManager.twitchManager = twitchManager
            streamManager.jitsiFrameInjector = jitsiFrameInjector
            jitsiManager.frameInjector = jitsiFrameInjector

            // Check if we have required config for the selected mode
            switch selectedMode {
            case .twitch:
                showingSetup = twitchStreamKey.isEmpty
            case .jitsi:
                showingSetup = jitsiRoomName.isEmpty
            }
        }
        .onOpenURL { url in
            Task { try? await Wearables.shared.handleUrl(url) }
        }
    }
}

// MARK: - Setup View

struct SetupView: View {
    @Binding var twitchStreamKey: String
    @Binding var jitsiRoomName: String
    @Binding var jitsiServer: String
    @Binding var displayName: String
    @Binding var selectedModeRaw: String
    var onContinue: () -> Void

    @State private var inputTwitchKey = ""
    @State private var inputJitsiRoom = ""
    @State private var inputDisplayName = ""

    var selectedMode: StreamMode {
        StreamMode(rawValue: selectedModeRaw) ?? .twitch
    }

    var canContinue: Bool {
        switch selectedMode {
        case .twitch:
            return !inputTwitchKey.isEmpty
        case .jitsi:
            return !inputJitsiRoom.isEmpty
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                // Mode Selection
                Section("Stream Mode") {
                    Picker("Mode", selection: $selectedModeRaw) {
                        ForEach(StreamMode.allCases, id: \.rawValue) { mode in
                            Text(mode.rawValue).tag(mode.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                // Meta Glasses Connection
                Section("Meta Glasses") {
                    Button {
                        try? Wearables.shared.startRegistration()
                    } label: {
                        HStack {
                            Image(systemName: "glasses")
                            Text("Connect to Meta Glasses")
                        }
                    }

                    Text("Opens Meta View app to authorize connection")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Mode-specific settings
                if selectedMode == .twitch {
                    Section("Twitch Settings") {
                        SecureField("Stream Key", text: $inputTwitchKey)
                            .textContentType(.password)
                            .autocorrectionDisabled()

                        Text("Find this in Twitch Creator Dashboard > Settings > Stream")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section("Jitsi Settings") {
                        TextField("Room Name", text: $inputJitsiRoom)
                            .textContentType(.URL)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)

                        TextField("Server URL", text: $jitsiServer)
                            .textContentType(.URL)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)

                        TextField("Your Display Name", text: $inputDisplayName)
                            .textContentType(.name)
                    }

                    Section {
                        Text("Your glasses video will appear as screen share in the Jitsi meeting.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("SpecBridge Setup")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Continue") {
                        saveAndContinue()
                    }
                    .disabled(!canContinue)
                }
            }
            .onAppear {
                // Load existing values
                inputTwitchKey = twitchStreamKey
                inputJitsiRoom = jitsiRoomName
                inputDisplayName = displayName
            }
        }
    }

    private func saveAndContinue() {
        switch selectedMode {
        case .twitch:
            twitchStreamKey = inputTwitchKey
        case .jitsi:
            jitsiRoomName = inputJitsiRoom
            displayName = inputDisplayName
        }
        onContinue()
    }
}

// MARK: - Main Streaming View

struct MainStreamingView: View {
    @ObservedObject var streamManager: StreamManager
    @ObservedObject var twitchManager: TwitchManager
    @ObservedObject var jitsiManager: JitsiManager
    @ObservedObject var jitsiFrameInjector: JitsiFrameInjector

    var selectedMode: StreamMode
    var twitchStreamKey: String
    var jitsiRoomName: String
    var jitsiServer: String
    var displayName: String
    var onBack: () -> Void

    var isLive: Bool {
        switch selectedMode {
        case .twitch:
            return twitchManager.isBroadcasting
        case .jitsi:
            return jitsiManager.isInMeeting
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                // Video Preview
                videoPreview

                // Status Info
                statusSection

                // Control Buttons
                controlButtons

                Spacer()
            }
            .padding()
            .navigationTitle(selectedMode.rawValue)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Settings") {
                        onBack()
                    }
                    .disabled(streamManager.isStreaming)
                }
            }
        }
    }

    // MARK: - Video Preview

    private var videoPreview: some View {
        ZStack {
            Color.black

            if let videoImage = streamManager.currentFrame {
                Image(uiImage: videoImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "glasses")
                        .font(.system(size: 48))
                        .foregroundStyle(.gray)
                    Text("Glasses Offline")
                        .foregroundStyle(.gray)
                }
            }

            // Live indicator
            if isLive {
                VStack {
                    HStack {
                        Spacer()
                        Text("LIVE")
                            .font(.caption.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.red)
                            .cornerRadius(4)
                            .padding(8)
                    }
                    Spacer()
                }
            }
        }
        .frame(height: 400)
        .cornerRadius(12)
    }

    // MARK: - Status Section

    private var statusSection: some View {
        VStack(spacing: 4) {
            HStack {
                Image(systemName: "glasses")
                Text("Glasses: \(streamManager.status)")
            }
            .foregroundStyle(streamManager.isStreaming ? .green : .secondary)

            if selectedMode == .twitch {
                HStack {
                    Image(systemName: "tv")
                    Text("Twitch: \(twitchManager.connectionStatus)")
                }
                .foregroundStyle(twitchManager.isBroadcasting ? .green : .secondary)
            } else {
                HStack {
                    Image(systemName: "video")
                    Text("Jitsi: \(jitsiManager.meetingStatus)")
                }
                .foregroundStyle(jitsiManager.isInMeeting ? .green : .secondary)

                if jitsiFrameInjector.isConnected {
                    HStack {
                        Image(systemName: "arrow.up.circle")
                        Text("Frames: \(jitsiFrameInjector.framesSent)")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .font(.subheadline)
    }

    // MARK: - Control Buttons

    private var controlButtons: some View {
        VStack(spacing: 12) {
            // Main action button
            Button {
                Task {
                    await toggleStream()
                }
            } label: {
                HStack {
                    Image(systemName: streamManager.isStreaming ? "stop.fill" : "play.fill")
                    Text(streamManager.isStreaming ? "Stop" : "Go Live")
                }
                .frame(maxWidth: .infinity)
                .padding()
            }
            .buttonStyle(.borderedProminent)
            .tint(streamManager.isStreaming ? .red : .green)

            // Mode-specific info
            if selectedMode == .jitsi && !jitsiRoomName.isEmpty {
                HStack {
                    Text("Room: \(jitsiRoomName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let url = URL(string: "\(jitsiServer)/\(jitsiRoomName)") {
                        ShareLink(item: url) {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .font(.caption)
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func toggleStream() async {
        if streamManager.isStreaming {
            await stopStream()
        } else {
            await startStream()
        }
    }

    private func startStream() async {
        // Set the output mode
        switch selectedMode {
        case .twitch:
            streamManager.outputMode = .twitch
        case .jitsi:
            streamManager.outputMode = .jitsi
        }

        // Start glasses streaming
        await streamManager.startStreaming()

        // Start the destination
        switch selectedMode {
        case .twitch:
            await twitchManager.startBroadcast(streamKey: twitchStreamKey)

        case .jitsi:
            let config = JitsiMeetingConfig(
                serverURL: jitsiServer,
                roomName: jitsiRoomName,
                displayName: displayName.isEmpty ? "SpecBridge User" : displayName,
                startWithVideoMuted: true  // We use screen share for glasses video
            )
            jitsiManager.joinMeeting(config: config)
        }
    }

    private func stopStream() async {
        // Stop glasses streaming (this will also stop outputs)
        await streamManager.stopStreaming()

        // Additional cleanup
        if selectedMode == .jitsi {
            jitsiManager.leaveMeeting()
        }
    }
}

// MARK: - Preview

#Preview {
    ContentView()
}
