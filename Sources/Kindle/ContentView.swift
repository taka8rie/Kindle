import SwiftUI

struct ContentView: View {
    @ObservedObject var viewModel: KindleViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            controls
            selectedBooksSection
            logSection
        }
        .padding(24)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Kindle 导书助手")
                .font(.system(size: 30, weight: .bold, design: .rounded))

            Text("为不在 Finder 中显示的 MTP Kindle 提供一个直接导书入口。")
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                statusBadge(
                    title: viewModel.dependencyReady ? "libmtp 已就绪" : "缺少 libmtp",
                    color: viewModel.dependencyReady ? .green : .orange
                )
                statusBadge(
                    title: viewModel.detectedDeviceName,
                    color: viewModel.detectedDeviceName == "尚未检测设备" ? .gray : .blue
                )
            }

            Text(viewModel.statusMessage)
                .font(.callout)
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button("检查依赖") {
                viewModel.refreshDependencyStatus()
            }

            Button("检测 Kindle") {
                viewModel.detectKindle()
            }
            .disabled(!viewModel.dependencyReady || viewModel.isBusy)

            Button("选择书籍") {
                viewModel.chooseBooks()
            }

            Button("导入到 Kindle") {
                viewModel.importBooks()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!viewModel.dependencyReady || viewModel.selectedBooks.isEmpty || viewModel.isBusy)

            if viewModel.isBusy {
                ProgressView()
                    .controlSize(.small)
            }

            Spacer()

            Text("目标目录：`/documents`")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var selectedBooksSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("已选择书籍")
                .font(.headline)

            if viewModel.selectedBooks.isEmpty {
                ContentUnavailableView(
                    "还没有选择文件",
                    systemImage: "books.vertical",
                    description: Text("支持 `epub`、`pdf`、`mobi`、`azw3`、`txt` 等格式。")
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
            } else {
                List {
                    ForEach(viewModel.selectedBooks) { book in
                        HStack {
                            Image(systemName: "book.closed")
                                .foregroundStyle(.blue)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(book.fileName)
                                Text(book.url.path)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .onDelete(perform: viewModel.removeBooks)
                }
                .frame(minHeight: 210)
            }
        }
    }

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("运行日志")
                .font(.headline)

            ScrollView {
                Text(viewModel.logLines.joined(separator: "\n\n"))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(14)
            }
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.secondary.opacity(0.15))
            )
            .frame(minHeight: 180)
        }
    }

    private func statusBadge(title: String, color: Color) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(color.opacity(0.12))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}
