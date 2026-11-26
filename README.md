# MKVExtract GUI

一个轻量的 macOS 原生工具，用图形界面从 MKV 文件中提取视频、音频、字幕轨道以及附件（封面、字体等）。底层调用 [MKVToolNix](https://mkvtoolnix.download/) 的 `mkvmerge` / `mkvextract`，本身只有一个 Swift 源文件，无需 Xcode 工程。

## 功能

- 拖放或选择 MKV 文件，自动识别轨道（类型 / 编码 / 语言 / 名称）
- 识别附件并单独勾选导出
- 每条轨道 / 附件都可自定义输出文件名，自动避开重名文件
- 一次 `mkvextract` 调用批量导出所有勾选内容
- 可指定输出目录（默认与源文件同目录）和 MKVToolNix 路径
- 实时日志与进度提示，浅色 / 深色外观自适应

## 环境要求

- macOS 13.0 及更高版本，Apple Silicon（构建目标为 `arm64-apple-macosx13.0`）
- Xcode Command Line Tools（`xcode-select --install`，提供 `swiftc`）
- MKVToolNix（提供 `mkvmerge` 与 `mkvextract`）

## 安装与构建

```bash
# 安装 MKVToolNix（任选其一）
brew install mkvtoolnix
# 或下载 MKVToolNix.app 放到 /Applications

git clone <仓库地址> MKVExtractGUI
cd MKVExtractGUI
bash build.sh
open build/MKVExtractGUI.app
```

构建产物位于 `build/MKVExtractGUI.app`。脚本会自动编译 SwiftUI 应用、写入 `Info.plist`、安装图标并做 ad-hoc 签名。

默认在 `/Applications/MKVToolNix.app/Contents/MacOS` 查找可执行文件；如果装在别处（例如 Homebrew），点击窗口右上角的设置按钮修改路径。

## 使用方法

1. 把 MKV 文件拖进窗口，或点击选择文件。
2. 在轨道 / 附件列表中勾选需要导出的项目，可直接修改输出文件名。
3. 选择输出目录（留空则与源文件同目录）。
4. 点击「开始提取」，完成后可用「打开输出目录」查看结果。

## 项目结构

```
MKVExtractGUI/
├── Sources/main.swift          # 全部逻辑与 SwiftUI 界面
├── Assets/
│   ├── AppIcon-master.png      # 图标母版（1024×1024）
│   ├── AppIcon.iconset/        # macOS 各尺寸图标源
│   └── AppIcon.icns            # 最终图标资源
├── build.sh                    # 一键构建脚本
└── build/                      # 构建输出（已 gitignore）
```

## 实现说明

几个刻意的设计选择，改动时注意保持：

- **不使用 App Sandbox**：沙箱会把 `mkvmerge` / `mkvextract` 子进程一起关进去，而 `NSOpenPanel` 的安全作用域不会传给子进程，访问 Downloads 等受保护目录会报 `open file error`。本地工具用 ad-hoc 签名即可。
- **子进程显式注入 UTF-8 locale**：GUI App 从 Finder 启动时 launchd 环境没有 `LANG` / `LC_ALL`，mkvmerge 回退到 C locale，遇到中文标题会截断输出（表现为识别失败）。`runIdentify` 与 `extract` 都设置了 `LC_ALL=en_US.UTF-8` 等变量。
- **识别请求带序号保护**：异步回调只接受最新一次结果，避免旧请求（例如误拖入文件夹）的失败覆盖后来正确加载的轨道。
- **stdout 重定向到临时文件**：规避 Pipe 在此环境下的读取时序问题；文件需先创建，再交给 `FileHandle(forWritingTo:)`。

## 常见问题

| 现象 | 处理 |
|---|---|
| 提示「未找到 mkvmerge / mkvextract」 | 在设置里指定 MKVToolNix 可执行文件所在目录 |
| 提示「请选择 MKV 文件，而不是文件夹」 | 拖入的是目录，请改为拖入 `.mkv` 文件 |
| 识别失败且日志含截断的 JSON | 确认已用 `bash build.sh` 重新构建（含 UTF-8 locale 修复） |
| 输出文件名重复 | 工具会自动追加 ` (1)`、` (2)` |

Intel Mac 需把 `build.sh` 中的 `-target arm64-apple-macosx13.0` 改为对应架构后重新构建。

## 许可证

暂未指定开源许可证。
