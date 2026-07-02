import SwiftUI
import UniformTypeIdentifiers

public struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var showRepoImporter = false
    @State private var showModelsImporter = false
    @State private var testingConda = false

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        // settings is a let on AppModel; bind through the store directly.
        @Bindable var settings = model.settings
        Form {
            Section("Repository") {
                HStack {
                    TextField("Repo path", text: $settings.config.repoPath, prompt: Text("/path/to/mlx-jaccl repo"))
                    Button("Choose…") { showRepoImporter = true }
                }
                Text("Checkout containing hostfiles/, server/, scripts/.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Conda environment") {
                TextField("Env name", text: $settings.config.condaEnvName)
                TextField("Prefix override", text: $settings.config.condaEnvPrefixOverride,
                          prompt: Text("auto-discover (e.g. ~/miniforge3/envs/mlxjccl)"))
                HStack {
                    Button {
                        testingConda = true
                        Task {
                            _ = await model.settings.resolveAndTestCondaPrefix()
                            testingConda = false
                        }
                    } label: {
                        if testingConda {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Test")
                        }
                    }
                    if let check = model.settings.lastToolCheck {
                        Label(check.detail, systemImage: check.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(check.ok ? .green : .red)
                            .font(.caption)
                            .textSelection(.enabled)
                    }
                }
            }

            Section("Model library") {
                HStack {
                    TextField("Models directory", text: $settings.config.modelsDirectory)
                    Button("Choose…") { showModelsImporter = true }
                }
                Text("Must be the same absolute path on every cluster node (MODEL_DIR is passed verbatim to all ranks).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                SecureField("HuggingFace token (optional)", text: $settings.config.hfToken)
                Text("Falls back to $HF_TOKEN, then ~/.cache/huggingface/token.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Sync") {
                TextField("rsync path override", text: $settings.config.rsyncPath,
                          prompt: Text("/usr/bin/rsync (openrsync)"))
                Stepper("Parallel node syncs: \(settings.config.maxParallelSyncs)",
                        value: $settings.config.maxParallelSyncs, in: 1...8)
                Text("Sequential (1) is recommended: every sync shares rank 0's uplink.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .fileImporter(isPresented: $showRepoImporter, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                model.settings.config.repoPath = url.path
                model.settingsChanged()
            }
        }
        .fileImporter(isPresented: $showModelsImporter, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                model.settings.config.modelsDirectory = url.path
                model.settingsChanged()
            }
        }
        .onDisappear {
            model.settingsChanged()
        }
    }
}
