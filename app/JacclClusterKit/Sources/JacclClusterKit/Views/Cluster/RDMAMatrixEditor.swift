import SwiftUI

/// N×N adjacency editor. Row = "this node's local device facing →" (the matrix
/// is not symmetric in device names). One Thunderbolt cable = two cells:
/// hovering (i,j) also highlights (j,i). Cell tint encodes validation ×
/// live-verify state: red = invalid, orange = node verified but device missing,
/// green = confirmed by `ibv_devices`.
struct RDMAMatrixEditor: View {
    let store: HostfileStore
    @State private var hovered: MatrixCell?

    private var n: Int { store.document.hosts.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("RDMA Matrix").font(.headline)
            Text("Each row lists that node's local RDMA device facing each peer. Verify fills in live device suggestions.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if n == 0 {
                Text("Add nodes to edit the matrix.").foregroundStyle(.secondary)
            } else {
                Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                    GridRow {
                        Text("") // corner
                        ForEach(0..<n, id: \.self) { j in
                            Text(shortName(j))
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    ForEach(0..<n, id: \.self) { i in
                        GridRow {
                            Text(shortName(i))
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                                .gridColumnAlignment(.trailing)
                            ForEach(0..<n, id: \.self) { j in
                                cell(row: i, column: j)
                            }
                        }
                    }
                }
                .frame(maxWidth: CGFloat(n) * 130 + 120, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func cell(row i: Int, column j: Int) -> some View {
        if i == j {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.gray.opacity(0.12))
                .frame(minWidth: 90, minHeight: 26)
                .overlay(Image(systemName: "minus").foregroundStyle(.tertiary))
        } else {
            MatrixCellField(store: store, row: i, column: j, hovered: $hovered)
        }
    }

    private func shortName(_ index: Int) -> String {
        guard store.document.hosts.indices.contains(index) else { return "?" }
        let name = store.document.hosts[index].ssh
        return name.split(separator: ".").first.map(String.init) ?? name
    }
}

private struct MatrixCellField: View {
    let store: HostfileStore
    let row: Int
    let column: Int
    @Binding var hovered: MatrixCell?

    var body: some View {
        HStack(spacing: 2) {
            TextField("rdma_enN", text: deviceBinding)
                .textFieldStyle(.plain)
                .font(.system(.caption, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 5)

            if !suggestions.isEmpty {
                Menu {
                    ForEach(suggestions, id: \.self) { device in
                        Button(device) {
                            deviceBinding.wrappedValue = device
                        }
                    }
                } label: {
                    Image(systemName: "chevron.down.circle")
                        .font(.caption2)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .padding(.trailing, 4)
            }
        }
        .frame(minWidth: 90)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isPairHighlighted ? Color.accentColor.opacity(0.10) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(borderColor, lineWidth: 1.2)
        )
        .onHover { inside in
            hovered = inside ? MatrixCell(row: row, column: column) : nil
        }
        .help(helpText)
    }

    /// One cable = two cells: (i,j) and (j,i).
    private var isPairHighlighted: Bool {
        guard let hovered else { return false }
        return (hovered.row == row && hovered.column == column)
            || (hovered.row == column && hovered.column == row)
    }

    private var device: String? {
        guard store.document.hosts.indices.contains(row),
              store.document.hosts[row].rdma.indices.contains(column) else { return nil }
        return store.document.hosts[row].rdma[column]
    }

    private var borderColor: Color {
        guard let device, !device.isEmpty else { return .red }
        if device.wholeMatch(of: #/rdma_en\d+/#) == nil { return .red }
        switch store.cellStatus(row: row, column: column) {
        case .confirmed: return .green
        case .missing: return .orange
        case .unverified: return .gray.opacity(0.5)
        }
    }

    private var helpText: String {
        guard store.document.hosts.indices.contains(row),
              store.document.hosts.indices.contains(column) else { return "" }
        let from = store.document.hosts[row].ssh
        let to = store.document.hosts[column].ssh
        var text = "\(from)'s device facing \(to)"
        switch store.cellStatus(row: row, column: column) {
        case .confirmed: text += " — confirmed by ibv_devices"
        case .missing: text += " — NOT reported by ibv_devices on \(from)"
        case .unverified: text += " — run Verify to cross-check"
        }
        return text
    }

    /// Devices this row's node actually reported, best suggestions first.
    private var suggestions: [String] {
        guard store.document.hosts.indices.contains(row) else { return [] }
        let host = store.document.hosts[row].ssh
        return store.verifyResults[host]?.rdmaDevices ?? []
    }

    private var deviceBinding: Binding<String> {
        Binding(
            get: { device ?? "" },
            set: { newValue in
                guard store.document.hosts.indices.contains(row),
                      store.document.hosts[row].rdma.indices.contains(column) else { return }
                let trimmed = newValue.trimmingCharacters(in: .whitespaces)
                store.document.hosts[row].rdma[column] = trimmed.isEmpty ? nil : trimmed
                store.markEdited()
            }
        )
    }
}
