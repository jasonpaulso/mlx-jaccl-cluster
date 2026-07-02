import SwiftUI

public struct ClusterView: View {
    @Bindable var model: AppModel
    @State private var tab: Tab = .form
    @State private var actionError: String?

    enum Tab: String, CaseIterable {
        case form = "Form"
        case source = "Source"
    }

    public init(model: AppModel) {
        self.model = model
    }

    private var store: HostfileStore { model.hostfiles }

    public var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if model.settings.config.repoPath.isEmpty {
                ContentUnavailableView(
                    "Set the repo path first",
                    systemImage: "folder.badge.questionmark",
                    description: Text("Open Settings and point the app at your mlx-jaccl repo checkout.")
                )
            } else if store.fileURL == nil {
                ContentUnavailableView(
                    "No hostfile selected",
                    systemImage: "doc.badge.gearshape",
                    description: Text("Pick a hostfile above, or create hosts.json from the example.")
                )
            } else if let error = store.loadError {
                ContentUnavailableView("Hostfile failed to load", systemImage: "exclamationmark.triangle", description: Text(error))
            } else {
                switch tab {
                case .form: HostfileFormView(model: model)
                case .source: HostfileSourceView(store: store)
                }
            }
        }
        .navigationTitle("Cluster")
        .alert(
            "Hostfile error",
            isPresented: Binding(
                get: { actionError != nil },
                set: { if !$0 { actionError = nil } }
            )
        ) {
            Button("OK") { actionError = nil }
        } message: {
            Text(actionError ?? "")
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Picker("Hostfile", selection: hostfileSelection) {
                ForEach(store.availableHostfiles, id: \.path) { url in
                    Text(url.lastPathComponent).tag(url.path as String?)
                }
                if store.fileURL == nil {
                    Text("None").tag(nil as String?)
                }
            }
            .frame(maxWidth: 320)

            if let repoURL = model.settings.config.repoURL,
               !FileManager.default.fileExists(atPath: repoURL.appendingPathComponent("hostfiles/hosts.json").path) {
                Button("Create from example") {
                    do {
                        let created = try store.createFromExample(repoURL: repoURL)
                        selectHostfile(path: created.path)
                    } catch {
                        actionError = error.localizedDescription
                    }
                }
            }

            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .frame(width: 160)

            Spacer()

            if store.isDirty {
                Button("Revert") { store.revert() }
                Button("Save") {
                    do { try store.save() } catch { actionError = error.localizedDescription }
                }
                .keyboardShortcut("s")
                .buttonStyle(.borderedProminent)
            }

            Button {
                Task {
                    // Resolve the env prefix first so verify can also check
                    // that each node has the env at the same path.
                    let check = await model.settings.resolveAndTestCondaPrefix()
                    await store.runVerify(envPrefix: check.ok ? check.prefix : nil)
                }
            } label: {
                if store.isVerifying {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Verify", systemImage: "checkmark.shield")
                }
            }
            .disabled(store.isVerifying || store.document.hosts.isEmpty)
        }
        .padding(10)
    }

    private var hostfileSelection: Binding<String?> {
        Binding(
            get: { store.fileURL?.path },
            set: { newValue in
                if let newValue { selectHostfile(path: newValue) }
            }
        )
    }

    private func selectHostfile(path: String) {
        store.load(from: URL(fileURLWithPath: path))
        // Persist relative to the repo when possible.
        if let repo = model.settings.config.repoURL, path.hasPrefix(repo.path + "/") {
            model.settings.config.selectedHostfile = String(path.dropFirst(repo.path.count + 1))
        } else {
            model.settings.config.selectedHostfile = path
        }
    }
}

// MARK: - Form tab

struct HostfileFormView: View {
    @Bindable var model: AppModel
    @State private var newNodeName = ""

    private var store: HostfileStore { model.hostfiles }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                issuesSection
                nodesSection
                RDMAMatrixEditor(store: store)
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private var issuesSection: some View {
        let issues = store.document.validate()
        if !issues.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(issues) { issue in
                    Label {
                        Text(issue.message).font(.callout)
                    } icon: {
                        Image(systemName: issue.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(issue.severity == .error ? .red : .orange)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var nodesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Nodes").font(.headline)
            ForEach(Array(store.document.hosts.enumerated()), id: \.element.id) { index, _ in
                NodeRow(model: model, index: index)
            }
            HStack {
                TextField("new-node.local", text: $newNodeName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                    .onSubmit(addNode)
                Button("Add Node", action: addNode)
                    .disabled(newNodeName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func addNode() {
        let name = newNodeName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        store.document.addNode(ssh: name)
        newNodeName = ""
        store.markEdited()
    }
}

struct NodeRow: View {
    @Bindable var model: AppModel
    let index: Int

    private var store: HostfileStore { model.hostfiles }

    var body: some View {
        if store.document.hosts.indices.contains(index) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    Text(index == 0 ? "rank 0" : "rank \(index)")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(index == 0 ? Color.accentColor.opacity(0.2) : Color.gray.opacity(0.15),
                                    in: Capsule())

                    TextField("ssh host", text: sshBinding)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)

                    if index == 0 {
                        TextField("coordinator LAN IP", text: coordinatorIPBinding)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 160)
                            .help("Rank 0 LAN IP used as CTRL_HOST (ips[0] in the hostfile). Must be an address this node currently has — JACCL binds it.")
                        if !coordinatorIPSuggestions.isEmpty {
                            Menu {
                                ForEach(coordinatorIPSuggestions, id: \.self) { ip in
                                    Button(ip) {
                                        coordinatorIPBinding.wrappedValue = ip
                                    }
                                }
                            } label: {
                                Image(systemName: "chevron.down.circle")
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                            .help("Rank 0's current IPv4 addresses")
                        }
                    }

                    verifyChip
                    envChip
                    setupButton

                    Spacer()

                    Button(role: .destructive) {
                        store.document.removeNode(at: index)
                        store.markEdited()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove node (also removes its matrix column)")
                }
                provisioningStatus
            }
        }
    }

    private var host: String {
        store.document.hosts.indices.contains(index) ? store.document.hosts[index].ssh : ""
    }

    /// Rank 0's live addresses: from the last verify when available, else
    /// from this Mac's interfaces when rank 0 is this machine. Link-local
    /// (169.254.x, e.g. Thunderbolt) sorted last.
    private var coordinatorIPSuggestions: [String] {
        var ips = store.verifyResults[host]?.ipv4Addresses ?? []
        if ips.isEmpty && LocalNetwork.hostRefersToThisMachine(host) {
            ips = LocalNetwork.ipv4Interfaces().map(\.address)
        }
        return ips.sorted { a, b in
            let aLocal = a.hasPrefix("169.254.")
            let bLocal = b.hasPrefix("169.254.")
            if aLocal != bLocal { return !aLocal }
            return a < b
        }
    }

    @ViewBuilder
    private var envChip: some View {
        if let result = store.verifyResults[host], result.sshOK, let envOK = result.envOK {
            if envOK {
                Label("env", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .help("Python environment found at rank 0's prefix path")
            } else {
                Label("env missing", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help("No python environment at rank 0's prefix path — use Set up node")
            }
        }
    }

    /// Copies rank 0's repo + python env to the node at identical paths, so no
    /// terminal setup is needed on workers (RDMA enablement excepted).
    @ViewBuilder
    private var setupButton: some View {
        if index != 0,
           let result = store.verifyResults[host], result.sshOK,
           result.envOK != true || model.provisioning.state(for: host) == .succeeded {
            switch model.provisioning.state(for: host) {
            case .running:
                ProgressView().controlSize(.small)
            case .succeeded:
                Label("set up", systemImage: "checkmark.seal.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            default:
                Button("Set up node") {
                    model.provisioning.provision(host: host)
                }
                .font(.caption)
                .help("Copy the repo and python environment from this Mac to \(host) (same absolute paths), then verify imports there.")
            }
        }
    }

    @ViewBuilder
    private var provisioningStatus: some View {
        switch model.provisioning.state(for: host) {
        case .running(let detail, let transferredBytes):
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(detail).font(.caption).foregroundStyle(.secondary)
                if transferredBytes > 0 {
                    Text(ByteCountFormatter.string(fromByteCount: transferredBytes, countStyle: .file))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.leading, 52)
        case .failed(let message):
            Label(message, systemImage: "xmark.octagon.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .textSelection(.enabled)
                .padding(.leading, 52)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var verifyChip: some View {
        let host = store.document.hosts[index].ssh
        if let result = store.verifyResults[host] {
            if result.sshOK {
                Label("\(result.remoteHostname ?? "ok") · \(result.rdmaDevices.count) rdma", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .help("RDMA devices: \(result.rdmaDevices.joined(separator: ", "))")
            } else {
                Label("unreachable", systemImage: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .help(result.failureHint ?? "SSH failed")
            }
        }
    }

    private var sshBinding: Binding<String> {
        Binding(
            get: { store.document.hosts.indices.contains(index) ? store.document.hosts[index].ssh : "" },
            set: {
                guard store.document.hosts.indices.contains(index) else { return }
                store.document.hosts[index].ssh = $0
                store.markEdited()
            }
        )
    }

    private var coordinatorIPBinding: Binding<String> {
        Binding(
            get: { store.document.hosts.first?.ips.first ?? "" },
            set: {
                guard !store.document.hosts.isEmpty else { return }
                store.document.hosts[0].ips = $0.isEmpty ? [] : [$0]
                store.markEdited()
            }
        )
    }
}

// MARK: - Source tab

struct HostfileSourceView: View {
    let store: HostfileStore
    @State private var text: String = ""
    @State private var parseError: String?

    var body: some View {
        VStack(spacing: 0) {
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .autocorrectionDisabled()
                .padding(4)
            Divider()
            HStack {
                if let parseError {
                    Label(parseError, systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                        .lineLimit(1)
                }
                Spacer()
                Button("Apply") {
                    do {
                        try store.applySource(text)
                        parseError = nil
                    } catch {
                        parseError = error.localizedDescription
                    }
                }
            }
            .padding(8)
        }
        .onAppear { text = store.sourceText() }
        .onChange(of: store.document) {
            // Keep in sync when the form tab edited the document.
            text = store.sourceText()
        }
    }
}
