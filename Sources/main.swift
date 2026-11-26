import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Foundation

// MARK: - Track model

struct Track: Identifiable {
    let id: Int
    let type: String        // video / audio / subtitles / buttons / ...
    let codecId: String
    let codecName: String
    let language: String
    let name: String
    let ext: String
}

struct Attachment: Identifiable {
    let id: Int
    let fileName: String
    let contentType: String
    let description: String
    let size: Int64
}

// MARK: - Extension mapping helper

func extFor(codecId: String, type: String) -> String {
    let c = codecId.uppercased()
    switch type {
    case "video":
        if c.contains("AVC")                    { return "h264" }
        if c.contains("HEVC")                   { return "hevc" }
        if c.contains("VP9")                    { return "vp9" }
        if c.contains("AV1")                    { return "av1" }
        if c.contains("V_MPEG2")                { return "m2v" }
        if c.contains("THEORA")                 { return "ogg" }
        if c.contains("PRORES")                 { return "mov" }
        if c.contains("VC1")                    { return "vc1" }
        return "mkv"
    case "audio":
        if c.contains("AAC")                    { return "aac" }
        if c.contains("AC3")                    { return "ac3" }
        if c.contains("EAC3")                   { return "eac3" }
        if c.contains("DTS")                    { return "dts" }
        if c.contains("FLAC")                   { return "flac" }
        if c.contains("MP3")                    { return "mp3" }
        if c.contains("MP2")                    { return "mp2" }
        if c.contains("OPUS")                   { return "opus" }
        if c.contains("PCM")                    { return "wav" }
        if c.contains("TRUEHD")                 { return "thd" }
        if c.contains("MLP")                    { return "mlp" }
        if c.contains("VORBIS")                 { return "ogg" }
        return "mka"
    case "subtitles":
        if c.contains("UTF8") || c.contains("ASCII") { return "srt" }
        if c.contains("ASS") || c.contains("SSA")    { return "ass" }
        if c.contains("USF")                    { return "usf" }
        if c.contains("WEBVTT")                 { return "vtt" }
        if c.contains("VOBSUB")                 { return "idx" }
        if c.contains("PGS")                    { return "sup" }
        if c.contains("KATE")                   { return "ogg" }
        if c.contains("DVBSUB")                 { return "sub" }
        return "srt"
    default:
        return "dat"
    }
}

// MARK: - App model (logic + state)

final class AppModel: ObservableObject, @unchecked Sendable {
    @Published var sourcePath = ""
    @Published var containerInfo = ""
    @Published var tracks: [Track] = []
    @Published var selectedIDs: Set<Int> = []
    @Published var outputNames: [Int: String] = [:]
    @Published var attachments: [Attachment] = []
    @Published var selectedAttachmentIDs: Set<Int> = []
    @Published var attachmentNames: [Int: String] = [:]
    @Published var outputDir = ""
    @Published var isExtracting = false
    @Published var progress: Double = 0
    @Published var statusMessage = "请选择一个 MKV 文件"
    @Published var logText = ""
    @Published var binPath = "/Applications/MKVToolNix.app/Contents/MacOS"
    @Published var showSettings = false

    /// 通过 NSOpenPanel / 拖拽拿到的 URL 在大多数情况下是“安全作用域”资源，
    /// 必须在访问其文件前调用 startAccessingSecurityScopedResource()，否则子进程
    /// (mkvmerge/mkvextract) 可能无权读取而静默失败。这里集中持有并保活这些作用域。
    private var scopedResources: [URL] = []

    /// 每次 loadFile 自增；runIdentify 的异步回调只接受最新一次的结果，
    /// 避免旧请求（例如误拖入目录）的失败结果覆盖后来正确加载的轨道。
    private var identifyGeneration = 0

    var mkvextractPath: String { (binPath as NSString).appendingPathComponent("mkvextract") }
    var mkvmergePath: String { (binPath as NSString).appendingPathComponent("mkvmerge") }

    deinit {
        for u in scopedResources { u.stopAccessingSecurityScopedResource() }
    }

    /// 激活 URL 的安全作用域并返回文件系统路径；非作用域 URL 上调用的结果是 no-op，安全。
    @discardableResult
    private func scope(_ url: URL) -> String {
        _ = url.startAccessingSecurityScopedResource()
        if !scopedResources.contains(url) { scopedResources.append(url) }
        return url.path
    }

    init() { detectBin() }

    func detectBin() {
        let candidates = [
            "/Applications/MKVToolNix.app/Contents/MacOS",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin"
        ]
        if let found = candidates.first(where: {
            FileManager.default.fileExists(atPath: ($0 as NSString).appendingPathComponent("mkvextract"))
        }) {
            binPath = found
        }
    }

    // MARK: file pickers

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        var types: [UTType] = []
        for ext in ["mkv", "mka", "mks", "webm", "mk3d"] {
            if let t = UTType(filenameExtension: ext) { types.append(t) }
        }
        if !types.isEmpty { panel.allowedContentTypes = types }
        if panel.runModal() == .OK, let url = panel.url {
            loadURL(url)
        }
    }

    func chooseOutputDir() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            outputDir = scope(url)
        }
    }

    func chooseBinDir() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            binPath = scope(url)
        }
    }

    func openOutputDir() {
        let dir = outputDir.isEmpty ? (sourcePath as NSString).deletingLastPathComponent : outputDir
        NSWorkspace.shared.open(URL(fileURLWithPath: dir))
    }

    func toggleAll() {
        if selectedIDs.count == tracks.count {
            selectedIDs = []
        } else {
            selectedIDs = Set(tracks.map { $0.id })
        }
    }

    // MARK: load + parse

    func loadFile(_ path: String) {
        // 拒绝目录：mkvmerge 收到目录会报 open file error（见此前截图）
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir),
              !isDir.boolValue else {
            statusMessage = "请选择 MKV 文件，而不是文件夹"
            return
        }
        sourcePath = path
        tracks = []
        selectedIDs = []
        outputNames = [:]
        attachments = []
        selectedAttachmentIDs = []
        attachmentNames = [:]
        logText = ""
        progress = 0
        if outputDir.isEmpty {
            outputDir = (path as NSString).deletingLastPathComponent
        }
        statusMessage = "正在读取轨道信息…"
        identifyGeneration += 1
        let generation = identifyGeneration
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.runIdentify(path, generation: generation)
        }
    }

    /// 入口封装：先激活 URL 安全作用域，再按路径加载。
    func loadURL(_ url: URL) {
        // 拖放回调可能给出目录 URL，先拦一道
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
              !isDir.boolValue else {
            statusMessage = "请选择 MKV 文件，而不是文件夹"
            return
        }
        loadFile(scope(url))
    }

    private func runIdentify(_ path: String, generation: Int) {
        guard FileManager.default.fileExists(atPath: mkvmergePath) else {
            DispatchQueue.main.async {
                guard self.identifyGeneration == generation else { return }
                self.statusMessage = "未找到 mkvmerge（用于读取轨道信息）"
            }
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: mkvmergePath)
        process.arguments = ["-J", path]
        // 关键：GUI App 从 Finder 启动时 launchd 环境里没有 LANG/LC_ALL，
        // mkvmerge 会退回 C locale，遇到中文 title 等字段时输出在第一个非 ASCII
        // 字节处被截断（实测 C locale 下只有 443B，UTF-8 下 8070B），
        // 导致 JSON 解析失败。显式注入 UTF-8 locale。
        var env = ProcessInfo.processInfo.environment
        env["LC_ALL"] = "en_US.UTF-8"
        env["LANG"] = "en_US.UTF-8"
        env["LC_CTYPE"] = "UTF-8"
        process.environment = env

        // 把 stdout 直接重定向到临时文件，彻底避开 Pipe 的后台线程读取时序问题
        // （此前 readToEnd 在此环境下只拿到不完整的 JSON，导致两种解析器都失败）。
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mkvextract-identify-\(UUID().uuidString).json")
        let errPipe = Pipe()
        process.standardError = errPipe
        do {
            // FileHandle(forWritingTo:) 要求文件已存在，必须先创建空文件
            FileManager.default.createFile(atPath: tmpURL.path, contents: nil)
            let outHandle = try FileHandle(forWritingTo: tmpURL)
            process.standardOutput = outHandle
            try process.run()
            process.waitUntilExit()
            try? outHandle.close()
            let outData = (try? Data(contentsOf: tmpURL)) ?? Data()
            let errData = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
            defer { try? FileManager.default.removeItem(at: tmpURL) }

            let status = process.terminationStatus
            let (container, parsed, atts, errs) = parseIdentifyJSON(outData)
            let rawErr = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            #if DEBUG
            let diag = "[诊断] mkvmerge=\(mkvmergePath) 退出码=\(status) stdout=\(outData.count)B stderr=\(errData.count)B 尾=\(String((String(data: outData, encoding: .utf8) ?? "").suffix(60)))\n"
            #else
            let diag = "[诊断] 退出码=\(status) stdout=\(outData.count)B stderr=\(errData.count)B\n"
            #endif

            DispatchQueue.main.async {
                guard self.identifyGeneration == generation else { return }
                self.containerInfo = container
                self.tracks = parsed
                self.selectedIDs = Set(parsed.map { $0.id })
                for t in parsed { self.outputNames[t.id] = self.defaultName(for: t) }
                self.attachments = atts
                self.selectedAttachmentIDs = Set(atts.map { $0.id })
                for a in atts { self.attachmentNames[a.id] = a.fileName }
                self.appendLog(diag)
                if parsed.isEmpty {
                    let detail = !errs.isEmpty ? errs
                        : (!rawErr.isEmpty ? rawErr
                            : "mkvmerge 未返回轨道（可能不是 Matroska 文件，或文件无法被读取）")
                    self.statusMessage = "未找到轨道：\(detail)"
                    self.appendLog("识别失败：\(detail)\n")
                } else {
                    let attPart = atts.isEmpty ? "" : " · \(atts.count) 个附件"
                    self.statusMessage = "已加载 \(parsed.count) 条轨道\(attPart)"
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: tmpURL)
            DispatchQueue.main.async {
                guard self.identifyGeneration == generation else { return }
                self.statusMessage = "读取失败：\(error.localizedDescription)"
            }
        }
    }

    private func parseIdentifyJSON(_ data: Data) -> (String, [Track], [Attachment], String) {
        struct IdentifyResult: Codable {
            let container: IdentifyContainer?
            let tracks: [IdentifyTrack]?
            let attachments: [IdentifyAttachment]?
            let errors: [String]?
        }
        struct IdentifyContainer: Codable { let type: String? }
        struct IdentifyTrack: Codable {
            let id: Int
            let type: String
            let codec: String?
            let properties: IdentifyProperties?
        }
        struct IdentifyProperties: Codable {
            let codecId: String?
            let language: String?
            let trackName: String?
            enum CodingKeys: String, CodingKey {
                case codecId = "codec_id"
                case language
                case trackName = "track_name"
            }
        }
        struct IdentifyAttachment: Codable {
            let id: Int
            let fileName: String?
            let contentType: String?
            let description: String?
            let size: Int64?
            enum CodingKeys: String, CodingKey {
                case id
                case fileName = "file_name"
                case contentType = "content_type"
                case description
                case size
            }
        }
        do {
            let result = try JSONDecoder().decode(IdentifyResult.self, from: data)
            let container = result.container?.type ?? ""
            let parsed = (result.tracks ?? []).map { t -> Track in
                let codecId = t.properties?.codecId ?? ""
                let language = t.properties?.language ?? "—"
                let name = t.properties?.trackName ?? ""
                return Track(id: t.id, type: t.type, codecId: codecId,
                             codecName: t.codec ?? "", language: language, name: name,
                             ext: extFor(codecId: codecId, type: t.type))
            }
            let atts = (result.attachments ?? []).map { a -> Attachment in
                Attachment(id: a.id, fileName: a.fileName ?? "attachment_\(a.id)",
                           contentType: a.contentType ?? "", description: a.description ?? "",
                           size: a.size ?? 0)
            }
            let errs = (result.errors ?? []).joined(separator: "；")
            return (container, parsed, atts, errs)
        } catch {
            // Codable 对 mkvmerge 新增/变化的字段很敏感；回退到 JSONSerialization 手工取值，
            // 保证识别不会因无关字段（如 container.properties 新增键）整体失败。
            if let parsedFallback = parseIdentifyFallback(data) {
                return parsedFallback
            }
            let detail: String
            if let raw = String(data: data, encoding: .utf8), !raw.isEmpty {
                detail = "无法解析 mkvmerge 输出（\(String(raw.prefix(120)))…）"
            } else {
                detail = "mkvmerge 未返回有效输出（0 字节）"
            }
            return ("", [], [], detail)
        }
    }

    /// JSONSerialization 兜底解析：只取本 App 需要的字段，忽略其他所有键。
    private func parseIdentifyFallback(_ data: Data) -> (String, [Track], [Attachment], String)? {
        guard let obj = try? JSONSerialization.jsonObject(with: data),
              let root = obj as? [String: Any] else { return nil }
        let container = (root["container"] as? [String: Any])?["type"] as? String ?? ""
        var tracks: [Track] = []
        if let list = root["tracks"] as? [[String: Any]] {
            for t in list {
                guard let id = t["id"] as? Int,
                      let type = t["type"] as? String else { continue }
                let props = t["properties"] as? [String: Any]
                let codecId = props?["codec_id"] as? String ?? ""
                let language = props?["language"] as? String ?? "—"
                let name = props?["track_name"] as? String ?? ""
                tracks.append(Track(id: id, type: type, codecId: codecId,
                                    codecName: t["codec"] as? String ?? "",
                                    language: language, name: name,
                                    ext: extFor(codecId: codecId, type: type)))
            }
        }
        var atts: [Attachment] = []
        if let list = root["attachments"] as? [[String: Any]] {
            for a in list {
                guard let id = a["id"] as? Int else { continue }
                atts.append(Attachment(
                    id: id,
                    fileName: a["file_name"] as? String ?? "attachment_\(id)",
                    contentType: a["content_type"] as? String ?? "",
                    description: a["description"] as? String ?? "",
                    size: a["size"] as? Int64 ?? 0))
            }
        }
        let errs = (root["errors"] as? [String])?.joined(separator: "；") ?? ""
        return (container, tracks, atts, errs)
    }

    func defaultName(for t: Track) -> String {
        let base = ((sourcePath as NSString).deletingPathExtension as NSString).lastPathComponent
        return "\(base)_T\(t.id).\(t.ext)"
    }

    // MARK: extraction

    func extract() {
        guard !isExtracting else { return }
        guard !selectedIDs.isEmpty || !selectedAttachmentIDs.isEmpty else {
            statusMessage = "请先勾选要提取的轨道或附件"
            return
        }
        guard FileManager.default.fileExists(atPath: mkvextractPath) else {
            statusMessage = "未找到 mkvextract，请到设置中指定 MKVToolNix 路径"
            return
        }

        let specs = buildSpecs()
        let attSpecs = buildAttachmentSpecs()
        guard !specs.isEmpty || !attSpecs.isEmpty else { return }

        isExtracting = true
        progress = 0
        var cmdLog = "mkvextract \(sourcePath)\n"
        var args: [String] = [sourcePath]
        if !specs.isEmpty {
            cmdLog += "tracks " + specs.map { "\($0.id):\(($0.path as NSString).lastPathComponent)" }.joined(separator: "  ") + "\n"
            args.append("tracks")
            for (id, path) in specs { args.append("\(id):\(path)") }
        }
        if !attSpecs.isEmpty {
            cmdLog += "attachments " + attSpecs.map { "\($0.id):\(($0.path as NSString).lastPathComponent)" }.joined(separator: "  ") + "\n"
            args.append("attachments")
            for (id, path) in attSpecs { args.append("\(id):\(path)") }
        }
        logText = cmdLog + "\n"
        statusMessage = "正在提取…"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: mkvextractPath)
        process.arguments = args
        // 与 mkvmerge 同样注入 UTF-8 locale，避免中文文件名/输出被截断（见 runIdentify）
        var env = ProcessInfo.processInfo.environment
        env["LC_ALL"] = "en_US.UTF-8"
        env["LANG"] = "en_US.UTF-8"
        env["LC_CTYPE"] = "UTF-8"
        process.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let handler: (FileHandle) -> Void = { handle in
            let data = handle.availableData
            if data.isEmpty { return }
            if let str = String(data: data, encoding: .utf8) {
                DispatchQueue.main.async { self.appendLog(str) }
                if let p = self.parseProgress(str) {
                    DispatchQueue.main.async { self.progress = p }
                }
            }
        }
        outPipe.fileHandleForReading.readabilityHandler = handler
        errPipe.fileHandleForReading.readabilityHandler = handler

        process.terminationHandler = { proc in
            DispatchQueue.main.async {
                self.isExtracting = false
                if proc.terminationStatus == 0 {
                    self.progress = 1.0
                    self.statusMessage = "提取完成 ✓"
                } else {
                    self.statusMessage = "提取失败（退出码 \(proc.terminationStatus)）"
                }
            }
        }

        do {
            try process.run()
        } catch {
            DispatchQueue.main.async {
                self.isExtracting = false
                self.statusMessage = "启动失败：\(error.localizedDescription)"
            }
        }
    }

    private func buildSpecs() -> [(id: Int, path: String)] {
        let dir = outputDir.isEmpty ? (sourcePath as NSString).deletingLastPathComponent : outputDir
        var result: [(Int, String)] = []
        var used: Set<String> = []
        for id in selectedIDs.sorted() {
            guard let track = tracks.first(where: { $0.id == id }) else { continue }
            let fallback = defaultName(for: track)
            let name = (outputNames[id] ?? fallback)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let cand = uniquePath(in: dir, name: name.isEmpty ? fallback : name, used: &used)
            result.append((id, cand))
        }
        return result
    }

    private func buildAttachmentSpecs() -> [(id: Int, path: String)] {
        let dir = outputDir.isEmpty ? (sourcePath as NSString).deletingLastPathComponent : outputDir
        var result: [(Int, String)] = []
        var used: Set<String> = []
        for id in selectedAttachmentIDs.sorted() {
            guard let att = attachments.first(where: { $0.id == id }) else { continue }
            let name = (attachmentNames[id] ?? att.fileName)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let cand = uniquePath(in: dir, name: name.isEmpty ? att.fileName : name, used: &used)
            result.append((id, cand))
        }
        return result
    }

    /// 返回 dir/name 的不冲突路径：文件已存在或本轮已占用则追加 " (n)"。
    private func uniquePath(in dir: String, name: String, used: inout Set<String>) -> String {
        var cand = (dir as NSString).appendingPathComponent(name)
        var n = 1
        while FileManager.default.fileExists(atPath: cand) || used.contains(cand) {
            let ext = (cand as NSString).pathExtension
            let noext = (cand as NSString).deletingPathExtension
            cand = ext.isEmpty ? "\(noext) (\(n))" : noext + " (\(n))." + ext
            n += 1
        }
        used.insert(cand)
        return cand
    }

    private func parseProgress(_ s: String) -> Double? {
        guard let re = try? NSRegularExpression(pattern: #"Progress:\s*\d+/\d+ bytes \((\d+)%\)"#) else { return nil }
        if let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) {
            let num = (s as NSString).substring(with: m.range(at: 1))
            if let d = Double(num) { return d / 100.0 }
        }
        return nil
    }

    private func appendLog(_ s: String) {
        logText += s
        if logText.count > 20000 { logText = String(logText.suffix(20000)) }
    }
}

// MARK: - Main app

@main
struct MKVExtractGUIApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(model)
        }
        .windowResizability(.contentSize)
    }
}

// MARK: - Content view

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            header(showSettings: $model.showSettings)
            Divider()
            ScrollView {
                VStack(spacing: 14) {
                    sourceCard
                    if !model.tracks.isEmpty { tracksCard }
                    if !model.attachments.isEmpty { attachmentsCard }
                    outputCard
                    logCard
                }
                .padding(16)
            }
            Divider()
            actionBar
        }
        .frame(width: 880, height: 680)
        .tint(.indigo)
        .sheet(isPresented: $model.showSettings) { settingsSheet(showSettings: $model.showSettings) }
        .onAppear { model.detectBin() }
    }

    // MARK: header

    private func header(showSettings: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "film.stack")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor))
            VStack(alignment: .leading, spacing: 2) {
                Text("MKVExtract GUI").font(.headline).fontWeight(.semibold)
                Text("从 MKV 提取视频 / 音频 / 字幕轨道").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { showSettings.wrappedValue = true } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .font(.system(size: 16))
            .foregroundStyle(.secondary)
            .help("设置 MKVToolNix 路径")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: source card

    private var sourceCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("源文件")
            if model.sourcePath.isEmpty {
                dropZone
            } else {
                loadedFileRow
            }
        }
        .padding(16)
        .background(cardBG)
    }

    private var dropZone: some View {
        RoundedRectangle(cornerRadius: 12)
            .stroke(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
            .foregroundStyle(Color.secondary.opacity(0.5))
            .frame(height: 110)
            .overlay(
                VStack(spacing: 6) {
                    Image(systemName: "tray.and.arrow.down")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text("把 MKV 文件拖到这里").font(.subheadline)
                    Text("或点击选择文件").font(.caption).foregroundStyle(.secondary)
                }
            )
            .onTapGesture { model.chooseFile() }
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                guard let p = providers.first else { return false }
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url = url { DispatchQueue.main.async { model.loadURL(url) } }
                }
                return true
            }
    }

    private var loadedFileRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.fill")
                .font(.system(size: 30))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 3) {
                Text((model.sourcePath as NSString).lastPathComponent)
                    .font(.subheadline).fontWeight(.medium).lineLimit(1)
                Text((model.containerInfo.isEmpty ? "Matroska" : model.containerInfo)
                     + (formattedSize(model.sourcePath).isEmpty ? "" : " · " + formattedSize(model.sourcePath)))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("重新选择") { model.chooseFile() }.controlSize(.small)
        }
    }

    // MARK: tracks card

    private var tracksCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionTitle("轨道")
                Spacer()
                Text("已选 \(model.selectedIDs.count)/\(model.tracks.count)")
                    .font(.caption).foregroundStyle(.secondary)
                Button(model.selectedIDs.count == model.tracks.count ? "全不选" : "全选") {
                    model.toggleAll()
                }
                .controlSize(.small)
            }
            Divider()
            ForEach(model.tracks) { track in
                trackRow(track)
                if track.id != model.tracks.last?.id { Divider() }
            }
        }
        .padding(16)
        .background(cardBG)
    }

    private func trackRow(_ track: Track) -> some View {
        HStack(spacing: 10) {
            Image(systemName: iconFor(track.type))
                .frame(width: 22)
                .foregroundStyle(Color.accentColor)
            Toggle(isOn: Binding(
                get: { model.selectedIDs.contains(track.id) },
                set: { v in
                    if v { model.selectedIDs.insert(track.id) }
                    else { model.selectedIDs.remove(track.id) }
                }
            )) { EmptyView() }
                .labelsHidden()
                .toggleStyle(.checkbox)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("#\(track.id)").font(.caption.monospaced()).foregroundStyle(.secondary)
                    Text(track.codecName).font(.subheadline).fontWeight(.medium)
                }
                Text("\(track.type) · \(track.codecId) · \(track.language)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if model.selectedIDs.contains(track.id) {
                TextField("", text: Binding(
                    get: { model.outputNames[track.id] ?? "" },
                    set: { model.outputNames[track.id] = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
            }
        }
    }

    // MARK: attachments card

    private var attachmentsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionTitle("附件")
                Spacer()
                Text("已选 \(model.selectedAttachmentIDs.count)/\(model.attachments.count)")
                    .font(.caption).foregroundStyle(.secondary)
                Button(model.selectedAttachmentIDs.count == model.attachments.count ? "全不选" : "全选") {
                    model.selectedAttachmentIDs = model.selectedAttachmentIDs.count == model.attachments.count
                        ? [] : Set(model.attachments.map { $0.id })
                }
                .controlSize(.small)
            }
            Divider()
            ForEach(model.attachments) { att in
                attachmentRow(att)
                if att.id != model.attachments.last?.id { Divider() }
            }
        }
        .padding(16)
        .background(cardBG)
    }

    private func attachmentRow(_ att: Attachment) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "paperclip")
                .frame(width: 22)
                .foregroundStyle(Color.accentColor)
            Toggle(isOn: Binding(
                get: { model.selectedAttachmentIDs.contains(att.id) },
                set: { v in
                    if v { model.selectedAttachmentIDs.insert(att.id) }
                    else { model.selectedAttachmentIDs.remove(att.id) }
                }
            )) { EmptyView() }
                .labelsHidden()
                .toggleStyle(.checkbox)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("#\(att.id)").font(.caption.monospaced()).foregroundStyle(.secondary)
                    Text(att.fileName).font(.subheadline).fontWeight(.medium).lineLimit(1)
                }
                Text("\(att.contentType.isEmpty ? "未知类型" : att.contentType) · \(formattedBytes(att.size))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if model.selectedAttachmentIDs.contains(att.id) {
                TextField("", text: Binding(
                    get: { model.attachmentNames[att.id] ?? "" },
                    set: { model.attachmentNames[att.id] = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
            }
        }
    }

    // MARK: output card

    private var outputCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("输出目录")
            HStack(spacing: 10) {
                Image(systemName: "folder").foregroundStyle(.secondary)
                Text(model.outputDir.isEmpty ? "（与源文件同目录）" : model.outputDir)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button("选择…") { model.chooseOutputDir() }.controlSize(.small)
            }
            Text("文件名按轨道自动生成（可在上方列表中修改）。若文件已存在会自动追加序号，避免覆盖。")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(16)
        .background(cardBG)
    }

    // MARK: log card

    private var logCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("日志")
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    Text(model.logText.isEmpty ? "（暂无输出）" : model.logText)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id("log")
                }
                .frame(height: 90)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(NSColor.textBackgroundColor)))
                .onChange(of: model.logText) { _ in
                    withAnimation(.none) { proxy.scrollTo("log", anchor: .bottom) }
                }
            }
        }
        .padding(16)
        .background(cardBG)
    }

    // MARK: action bar

    private var actionBar: some View {
        VStack(spacing: 8) {
            if model.isExtracting {
                ProgressView(value: model.progress) {
                    EmptyView()
                } currentValueLabel: {
                    Text("\(Int(model.progress * 100))%").font(.caption)
                }
                .progressViewStyle(.linear)
            }
            HStack {
                Text(model.statusMessage)
                    .font(.caption)
                    .foregroundStyle(model.isExtracting ? .secondary : .primary)
                    .lineLimit(1)
                Spacer()
                if !model.isExtracting && model.progress >= 1 {
                    Button("打开输出目录") { model.openOutputDir() }.controlSize(.small)
                }
                Button {
                    model.extract()
                } label: {
                    Label("开始提取", systemImage: "arrow.down.doc.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isExtracting || model.selectedIDs.isEmpty)
                .keyboardShortcut(.return)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: settings sheet

    private func settingsSheet(showSettings: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("设置").font(.headline)
            Text("MKVToolNix 可执行文件所在目录").font(.subheadline)
            HStack {
                TextField("", text: $model.binPath)
                    .textFieldStyle(.roundedBorder)
                Button("浏览…") { model.chooseBinDir() }.controlSize(.small)
            }
            let ok = FileManager.default.fileExists(atPath: model.mkvextractPath)
            Text("当前 mkvextract：\(ok ? "已找到 ✓" : "未找到 ✗")")
                .font(.caption)
                .foregroundStyle(ok ? .green : .red)
            Spacer()
            HStack {
                Spacer()
                Button("完成") { showSettings.wrappedValue = false }
                    .keyboardShortcut(.escape)
            }
        }
        .padding(20)
        .frame(width: 440, height: 220)
    }

    // MARK: helpers

    private func sectionTitle(_ s: String) -> some View {
        Text(s)
            .font(.footnote)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
            .textCase(nil)
    }

    private var cardBG: some View {
        RoundedRectangle(cornerRadius: 12).fill(Color(NSColor.controlBackgroundColor))
    }

    private func iconFor(_ t: String) -> String {
        switch t {
        case "video":      return "film"
        case "audio":      return "music.note"
        case "subtitles":  return "captions.bubble"
        case "buttons":    return "cursorrect"
        default:           return "doc"
        }
    }

    private func formattedSize(_ path: String) -> String {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let bytes = attrs[.size] as? Int64 else { return "" }
        return formattedBytes(bytes)
    }

    private func formattedBytes(_ bytes: Int64) -> String {
        let fmt = ByteCountFormatter()
        fmt.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        fmt.countStyle = .file
        return fmt.string(fromByteCount: bytes)
    }
}
