import SwiftUI
import UniformTypeIdentifiers

public struct ServerView: View {
    @Bindable var model: AppModel
    @State private var selectedModelPath: String = ""
    @State private var showImporter = false
    @State private var showAdvanced = false
    @State private var showCrashSheet = false

    public init(model: AppModel) {
        self.model = model
    }

    private var server: ServerController { model.server }

    public var body: some View {
        VStack(spacing: 0) {
            HealthStatusHeader(server: server)
            Divider()
            controls
            Divider()
            LogConsoleView(buffer: server.logBuffer)
        }
        .navigationTitle("Server")
        .onChange(of: crashed) { _, isCrashed in
            showCrashSheet = isCrashed
        }
        .sheet(isPresented: $showCrashSheet) {
            CrashSheet(server: server)
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                selectedModelPath = url.path
            }
        }
    }

    private var crashed: Bool {
        if case .crashed = server.state { return true }
        return false
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Picker("Model", selection: $selectedModelPath) {
                    if selectedModelPath.isEmpty {
                        Text("Choose a model…").tag("")
                    }
                    ForEach(model.library.servableModels) { local in
                        Text(local.name).tag(local.url.path)
                    }
                    if !selectedModelPath.isEmpty,
                       !model.library.servableModels.contains(where: { $0.url.path == selectedModelPath }) {
                        Text(URL(fileURLWithPath: selectedModelPath).lastPathComponent).tag(selectedModelPath)
                    }
                }
                .frame(maxWidth: 380)

                Button("Other…") { showImporter = true }

                Spacer()

                startStopButton

                Menu {
                    Button("Force cleanup (pkill all nodes)") {
                        Task { await server.forceCleanup() }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .fixedSize()
            }

            DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                advancedGrid
            }
            .font(.callout)

            if let note = server.progressNote {
                Label(note, systemImage: "hourglass")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let error = server.lastError {
                Label(error, systemImage: "xmark.octagon.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private var startStopButton: some View {
        switch server.state {
        case .stopped, .crashed:
            Button {
                Task { await server.start(.init(modelDir: selectedModelPath)) }
            } label: {
                Label("Start", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(selectedModelPath.isEmpty)
        case .stopping:
            Button {} label: { Label("Stopping…", systemImage: "stop.fill") }
                .disabled(true)
        default:
            Button(role: .destructive) {
                Task { await server.stop() }
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
        }
    }

    private var advancedGrid: some View {
        // settings is a let on AppModel; bind through the store directly.
        @Bindable var settings = model.settings
        return Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            GridRow {
                Text("HTTP port")
                TextField("", value: $settings.config.launch.httpPort, format: .number.grouping(.never))
                    .frame(width: 80)
                Text("Control port")
                TextField("", value: $settings.config.launch.ctrlPort, format: .number.grouping(.never))
                    .frame(width: 80)
            }
            GridRow {
                Text("Queue max")
                TextField("", value: $settings.config.launch.queueMax, format: .number.grouping(.never))
                    .frame(width: 80)
                Text("Request timeout (s)")
                TextField("", value: $settings.config.launch.requestTimeoutSeconds, format: .number.grouping(.never))
                    .frame(width: 80)
            }
            GridRow {
                Toggle("Verbose mlx.launch", isOn: $settings.config.launch.verbose)
                    .gridCellColumns(4)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(.top, 6)
    }
}

// MARK: - Health header

struct HealthStatusHeader: View {
    let server: ServerController

    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 7) {
                Circle().fill(stateColor).frame(width: 10, height: 10)
                Text(server.state.label).font(.headline)
            }

            if let health = currentHealth {
                Label("world size \(health.worldSize)", systemImage: "cpu")
                    .font(.callout)
                Label("\(health.model)", systemImage: "shippingbox")
                    .font(.callout)
                    .lineLimit(1)
                queueGauge(health)
            }
            Spacer()
        }
        .padding(12)
    }

    private var currentHealth: HealthStatus? {
        if case .running(let h) = server.state { return h }
        if case .degraded = server.state { return server.lastHealth }
        return nil
    }

    private func queueGauge(_ health: HealthStatus) -> some View {
        HStack(spacing: 6) {
            Gauge(value: Double(health.queueSize), in: 0...Double(max(health.queueMax, 1))) {
                EmptyView()
            }
            .gaugeStyle(.accessoryLinearCapacity)
            .frame(width: 90)
            Text("queue \(health.queueSize)/\(health.queueMax)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var stateColor: Color {
        switch server.state {
        case .stopped: .gray
        case .launching, .loadingModel, .stopping: .yellow
        case .running: .green
        case .degraded: .orange
        case .crashed: .red
        }
    }
}

// MARK: - Crash sheet

struct CrashSheet: View {
    let server: ServerController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Server crashed", systemImage: "exclamationmark.triangle.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.red)

            if case .crashed(let code, let tail) = server.state {
                Text("mlx.launch exited with code \(code). Last output:")
                    .font(.callout)
                ScrollView {
                    Text(tail.joined(separator: "\n"))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                .frame(minHeight: 220, maxHeight: 340)
            }

            HStack {
                Button("Force cleanup") {
                    Task { await server.forceCleanup() }
                }
                Spacer()
                Button("Dismiss") {
                    server.dismissCrash()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 620)
    }
}
