import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var viewModel: KindleViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                controls
                deviceInfoSection
                kindleBooksSection
                selectedBooksSection
                logSection
            }
            .padding(24)
        }
        .frame(minWidth: 760, minHeight: 720)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Kindle 导书助手")
                .font(.system(size: 30, weight: .bold, design: .rounded))

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

            Button("USB 检测") {
                viewModel.detectKindle()
            }
            .disabled(!viewModel.dependencyReady || viewModel.isBusy)

            Button("连接装置") {
                viewModel.connectKindleDevice()
            }
            .disabled(!viewModel.dependencyReady || viewModel.isBusy)

            Button("选择书籍") {
                viewModel.chooseBooks()
            }

            Button("复制到 Kindle") {
                viewModel.importBooks()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!viewModel.dependencyReady || viewModel.selectedBooks.isEmpty || viewModel.isBusy)

            if viewModel.isBusy {
                ProgressView()
                    .controlSize(.small)
            }

            Spacer()

            Text("目标：`\(viewModel.currentKindlePath)`")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var deviceInfoSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Kindle 信息")
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 22, verticalSpacing: 8) {
                GridRow {
                    infoItem("型号", viewModel.deviceInfo.summaryTitle)
                    infoItem("可用容量", viewModel.deviceInfo.freeSpaceDescription ?? "未提供")
                    infoItem("总容量", viewModel.deviceInfo.storageDescription ?? "未提供")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
        }
    }

    private var kindleBooksSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("复制记录")
                    .font(.headline)

                Spacer()

                Button {
                    viewModel.goUpInKindle()
                } label: {
                    Label("上级", systemImage: "chevron.up")
                }
                .disabled(!viewModel.canGoUpInKindle || viewModel.isBusy)

                Button {
                    viewModel.connectKindleDevice()
                } label: {
                    Label("更新缓存", systemImage: "arrow.clockwise")
                }
                .disabled(!viewModel.dependencyReady || viewModel.isBusy)
            }

            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .foregroundStyle(.orange)
                Text(viewModel.currentKindlePath)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )

            if viewModel.kindleItems.isEmpty {
                ContentUnavailableView(
                    "还没有装置缓存",
                    systemImage: "folder",
                    description: Text("点击“连接装置”后显示 Kindle 文件。")
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            } else if viewModel.visibleKindleItems.isEmpty {
                ContentUnavailableView(
                    "还没有复制到当前目标",
                    systemImage: "doc.badge.plus",
                    description: Text("复制成功的文件会显示在这里。")
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            } else {
                List(viewModel.visibleKindleItems) { item in
                    kindleItemRow(item)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            viewModel.openKindleItem(item)
                        }
                }
                .frame(minHeight: 180)
            }
        }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: nil) { providers in
            viewModel.importDroppedBooks(providers)
        }
    }

    private var selectedBooksSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("待复制文件")
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

    private func kindleItemRow(_ item: KindleItem) -> some View {
        HStack(spacing: 10) {
            Image(systemName: iconName(for: item))
                .foregroundStyle(iconColor(for: item))

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .lineLimit(1)
                Text(item.displayPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Text(item.kind == .folder ? item.displayKind : item.formattedSize)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func iconName(for item: KindleItem) -> String {
        if item.isKindleSidecarFolder {
            return "doc.text"
        }
        return item.kind == .folder ? "folder" : "doc"
    }

    private func iconColor(for item: KindleItem) -> Color {
        if item.isKindleSidecarFolder {
            return .secondary
        }
        return item.kind == .folder ? .orange : .teal
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

    private func infoItem(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(minWidth: 130, alignment: .leading)
    }
}
