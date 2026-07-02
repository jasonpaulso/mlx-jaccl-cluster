import SwiftUI

public enum SidebarItem: String, CaseIterable, Identifiable {
    case cluster = "Cluster"
    case server = "Server"
    case models = "Models"

    public var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .cluster: "point.3.connected.trianglepath.dotted"
        case .server: "server.rack"
        case .models: "shippingbox"
        }
    }
}

public struct RootView: View {
    @Bindable var model: AppModel
    @State private var selection: SidebarItem? = .cluster

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(SidebarItem.allCases, selection: $selection) { item in
                    Label(item.rawValue, systemImage: item.systemImage)
                        .tag(item)
                }
                .listStyle(.sidebar)
                Divider()
                ServerStatePill(server: model.server)
                    .padding(10)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210)
        } detail: {
            switch selection ?? .cluster {
            case .cluster:
                ClusterView(model: model)
            case .server:
                ServerView(model: model)
            case .models:
                ModelsView(model: model)
            }
        }
        .frame(minWidth: 940, minHeight: 620)
    }
}

/// Persistent server-state indicator in the sidebar footer.
struct ServerStatePill: View {
    let server: ServerController

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 1) {
                Text(server.state.label)
                    .font(.callout.weight(.medium))
                if case .running(let health) = server.state {
                    Text("\(health.model) · \(health.worldSize) node\(health.worldSize == 1 ? "" : "s")")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private var color: Color {
        switch server.state {
        case .stopped: .gray
        case .launching, .loadingModel, .stopping: .yellow
        case .running: .green
        case .degraded: .orange
        case .crashed: .red
        }
    }
}
