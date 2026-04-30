# Kindle 导书助手

一个原生 macOS 小工具，用来解决新版 Kindle 在 macOS Finder 中不显示、无法像 U 盘那样直接拖书的问题。

当前版本的目标很明确：

- 检测通过 USB 连接的 Kindle / 其他 MTP 设备
- 从 Mac 选择电子书文件
- 直接导入到 Kindle 的 `documents` 目录

它不是一个真正把 Kindle 挂载进 Finder 的文件系统驱动；第一版选择了更稳的方案，直接调用 `libmtp` 完成传输。

## 依赖

先安装 Homebrew 依赖：

```bash
brew install libmtp
```

如果你后面想进一步做成“像磁盘一样挂载”，可以在这个项目基础上继续接 FUSE / MTPFS；但那会比当前 MVP 复杂很多。

## 运行

```bash
swift run
```

也可以直接用 Xcode 打开这个目录下的 `Package.swift`。

## 打包成 .app

如果你想生成一个可双击启动的应用：

```bash
./scripts/build_app.sh
```

生成完成后，应用会出现在：

```bash
dist/Kindle 导书助手.app
```

## 使用步骤

1. 用支持数据传输的 USB 线连接 Kindle。
2. 确认 Kindle 不是只在充电状态。
3. 打开应用，点击“检查依赖”。
4. 点击“检测 Kindle”。
5. 点击“选择书籍”挑选 `epub`、`pdf`、`mobi`、`azw3`、`txt` 等文件。
6. 点击“导入到 Kindle”。

## 当前限制

- 依赖 `libmtp` 命令行工具，尚未直接链接 `libmtp` C API。
- 默认导入到 `/documents`，并兼容尝试 `/Documents`。
- 还没有做设备内容浏览、删除、封面预览、格式转换。
- 还不能把 Kindle 真正挂载成 Finder 里的卷。

## 后续可扩展方向

- 浏览 Kindle 现有文件
- 拖拽导入
- 自动识别重复书籍
- 集成格式转换
- 尝试基于 MTPFS 做只在应用内可见的“类磁盘”浏览器
