import SwiftUI
import AppKit

/// Live log console over the coalescing ring buffer: stderr tinted, substring
/// filter, pin-to-bottom that disengages when the user scrolls up.
struct LogConsoleView: View {
    let buffer: LogBuffer
    @State private var filter = ""
    @State private var pinToBottom = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter", text: $filter)
                    .textFieldStyle(.plain)
                Toggle(isOn: $pinToBottom) {
                    Image(systemName: "arrow.down.to.line")
                }
                .toggleStyle(.button)
                .help("Pin to bottom")
                Button {
                    buffer.clear()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Clear log")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(visibleLines) { line in
                            Text(line.text)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(line.isStderr ? Color.orange : Color.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                .id(line.id)
                        }
                        Color.clear.frame(height: 1).id("log-bottom")
                    }
                    .padding(8)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .onChange(of: buffer.lines.count) {
                    if pinToBottom {
                        proxy.scrollTo("log-bottom", anchor: .bottom)
                    }
                }
            }
        }
    }

    private var visibleLines: [LogLine] {
        guard !filter.isEmpty else { return buffer.lines }
        return buffer.lines.filter { $0.text.localizedCaseInsensitiveContains(filter) }
    }
}
