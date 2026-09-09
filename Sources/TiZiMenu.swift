import AppKit
import Foundation

// ============================================================
// 梯子网速监控（TiZiMenu）
// 自适应版：socket 路径 / 代理端口 / mihomo 密钥 / 测速源 全部不写死，
// 启动及失联时自动重新发现——Clash Verge 升级改路径/端口、测速文件失效均自愈。
// ============================================================

// Clash Verge Rev 配置目录（自适应发现的数据源）
let CFG_DIR = NSString(string:"~/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev").expandingTildeInPath

// 事件日志路径（按当前用户展开，不含任何硬编码用户名）
let LOG_PATH = NSString(string:"~/Library/Logs/tizimenu.log").expandingTildeInPath

// 带宽测速源（按序回退；均支持 Range。主源挂了自动换下一个）
let BW_SOURCES = [
    "https://www.python.org/ftp/python/3.13.12/Python-3.13.12.tar.xz",
    "https://speed.cloudflare.com/__down?bytes=4000000",
    "https://nodejs.org/dist/v22.12.0/node-v22.12.0.tar.xz",
]

func curl(_ args:[String]) -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath:"/usr/bin/curl")
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    try? p.run(); p.waitUntilExit()
    return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding:.utf8)
}

// —— 自适应 API 定位（运行时状态，失联时自动重发现）——
var sockPath: String? = "/tmp/verge/verge-mihomo.sock"  // mihomo REST 的 unix socket；nil=走 TCP
var tcpCtl: String? = nil                               // 备用 TCP external-controller（host:port）
var apiSecret = ""                                      // mihomo secret（普通连不上时自动带上）
var proxyPort = "7897"                                  // 混合代理端口（测速走它）
var lastRediscover = Date.distantPast                   // 限频：最快 30 秒重发现一次

func getJSON(_ path:String)->[String:Any]? {
    var args = ["-s","--max-time","5"]
    if !apiSecret.isEmpty { args += ["-H","Authorization: Bearer \(apiSecret)"] }
    if let s = sockPath {
        args += ["--unix-socket", s, "http://localhost\(path)"]
    } else if let t = tcpCtl {
        args += ["http://\(t)\(path)"]
    } else { return nil }
    guard let out = curl(args), let d = out.data(using:.utf8) else { return nil }
    return try? JSONSerialization.jsonObject(with:d, options:[]) as? [String:Any]
}

// 从 Clash Verge 配置 yaml 抓顶层键值（粗暴行扫描，够用）
func yamlValue(_ key:String)->String? {
    for f in ["config.yaml","clash-verge.yaml","verge.yaml"] {
        guard let txt = try? String(contentsOfFile:CFG_DIR+"/\(f)", encoding:.utf8) else { continue }
        for line in txt.components(separatedBy:"\n") {
            let t = line.trimmingCharacters(in:.whitespaces)
            if t.hasPrefix("\(key):") {
                var v = t.dropFirst(key.count+1).trimmingCharacters(in:.whitespaces)
                v = v.trimmingCharacters(in:CharacterSet(charactersIn:"'\""))
                if !v.isEmpty { return v }
            }
        }
    }
    return nil
}

// 试一发 /version 验证端点可用（不污染正式状态）
func apiWorks(sock:String?, tcp:String?)->Bool {
    let s0 = sockPath, t0 = tcpCtl
    sockPath = sock; tcpCtl = tcp
    let ok = getJSON("/version") != nil
    sockPath = s0; tcpCtl = t0
    return ok
}

// 自动发现 mihomo 控制 API：socket 优先，TCP 兜底，secret 兜底
func discoverAPI(){
    let sec = (yamlValue("secret") ?? "")
    func tryEndpoint(sock:String?, tcp:String?)->Bool {
        apiSecret = ""
        if apiWorks(sock:sock, tcp:tcp) { sockPath = sock; tcpCtl = tcp; return true }
        if !sec.isEmpty {                       // 带配置里的 secret 再试一次
            apiSecret = sec
            if apiWorks(sock:sock, tcp:tcp) { sockPath = sock; tcpCtl = tcp; return true }
            apiSecret = ""
        }
        return false
    }
    // 1) socket 候选：/tmp/verge 全部 .sock + /tmp 下 mihomo/verge 命名的 + 配置文件声明
    var cands:[String] = []
    if let list = try? FileManager.default.contentsOfDirectory(atPath:"/tmp/verge") {
        cands += list.filter{$0.hasSuffix(".sock")}.map{"/tmp/verge/\($0)"}
    }
    if let list = try? FileManager.default.contentsOfDirectory(atPath:"/tmp") {
        cands += list.filter{$0.hasSuffix(".sock") && ($0.contains("mihomo") || $0.contains("verge"))}.map{"/tmp/\($0)"}
    }
    if let v = yamlValue("external-controller-unix") { cands.append(v) }
    var seen = Set<String>()
    for s in cands where !seen.contains(s) {
        seen.insert(s)
        if tryEndpoint(sock:s, tcp:nil) { return }
    }
    // 2) TCP 兜底：配置里的 external-controller + mihomo 常见默认端口
    var tcps:[String] = []
    if let v = yamlValue("external-controller") { tcps.append(v) }
    tcps += ["127.0.0.1:9097", "127.0.0.1:9090"]
    for t in tcps where !t.isEmpty {
        if tryEndpoint(sock:nil, tcp:t) { return }
    }
    // 3) 全失败：保持原状，下轮轮询再试
}

// 自动发现混合代理端口：配置文件优先，常见端口兜底，用 generate_204 实测验证
func discoverPort(){
    var ports:[String] = []
    for k in ["mixed-port","verge_mixed_port"] { if let v = yamlValue(k) { ports.append(v) } }
    ports += ["7897","7890","7899"]
    var seen = Set<String>()
    for p in ports where !seen.contains(p) {
        seen.insert(p)
        let code = curl(["-x","http://127.0.0.1:\(p)","-s","-o","/dev/null",
                         "--max-time","3","-w","%{http_code}",
                         "http://www.gstatic.com/generate_204"]) ?? ""
        if code.trimmingCharacters(in:.whitespacesAndNewlines).hasPrefix("2")
            || code.trimmingCharacters(in:.whitespacesAndNewlines).hasPrefix("3") {
            proxyPort = p; return
        }
    }
}

func currentNode()->String? { getJSON("/proxies/Proxy")?["now"] as? String }
func nodeDelay(_ n:String)->Int? {
    let e = n.addingPercentEncoding(withAllowedCharacters:.urlPathAllowed) ?? n
    let q = "http://www.gstatic.com/generate_204".addingPercentEncoding(withAllowedCharacters:.urlQueryAllowed) ?? ""
    return getJSON("/proxies/\(e)/delay?url=\(q)&timeout=4000")?["delay"] as? Int
}
// 带宽测试（预热复用两段法 + 限时自适应）：
//   第 1 段预热（跑完 TCP 慢启动）；第 2 段同连接复用计速。速度 = 计速段字节数/(total-pretransfer)。
//   ⚠️ 不能用固定 8MB+短 max-time：慢节点（<3Mbps 常态）8 秒根本下不完，被掐后体积校验全灭 → 永远"失败"
//   （2026-09-08 晚实锤的 bug：客户端看得见下载动静、app 却显示失败，就是它）。
//   正解：限时 18s 下多少算多少——截断时 字节/时间 依然是真实平均速度；卡死由 --speed-limit 兜底（4 秒 <5KB/s 即断）。
//   体积校验只防 404/空响应（>100KB 即可），不再要求下满。
func nodeBW(_ url:String)->Double? {
    guard let s = curl(["-x", "http://127.0.0.1:\(proxyPort)",
                        "-o","/dev/null","-s","-r","0-4194303", url + (url.contains("?") ? "&warmup=1" : "?warmup=1"),
                        "-o","/dev/null","-r","0-4194303", url,
                        "-w","%{http_code} %{size_download} %{time_pretransfer} %{time_total}\\n",
                        "--max-time","18","--speed-limit","5120","--speed-time","4"]),
          let line = s.trimmingCharacters(in:.whitespacesAndNewlines)
                        .components(separatedBy:"\n").last else { return nil }
    let p = line.components(separatedBy:" ").compactMap{Double($0)}
    guard p.count == 4, (200...299).contains(Int(p[0])), p[1] > 100_000, p[3] - p[2] > 0.2 else { return nil }
    return p[1] / (p[3] - p[2]) * 8 / 1_000_000
}
func nodeBW()->Double? {
    for u in BW_SOURCES { if let b = nodeBW(u) { return b } }
    return nil
}
// 事件日志（~/Library/Logs/tizimenu.log）：每次测速的结果/失败原因落一行，出问题有据可查
func logLine(_ s:String){
    let line = "\(Date()) \(s)\n"
    let fh = FileHandle(forWritingAtPath:LOG_PATH)
        ?? { FileManager.default.createFile(atPath:LOG_PATH, contents:nil); return FileHandle(forWritingAtPath:LOG_PATH) }()
    fh?.seekToEndOfFile(); fh?.write(line.data(using:.utf8)!); fh?.closeFile()
}

func shortName(_ n:String)->String {
    var s = n.replacingOccurrences(of:"\\[[^\\]]*\\]", with:"", options:.regularExpression)
    s = s.replacingOccurrences(of:"[🇸🇬🇭🇰🇯🇵🇹🇼🇺🇸🇨🇳]", with:"", options:.regularExpression)
    s = s.replacingOccurrences(of:"\\s+", with:" ", options:.regularExpression).trimmingCharacters(in:.whitespaces)
    let parts = s.components(separatedBy:" ").filter{!$0.isEmpty}
    if parts.count>=2 {
        let pre = parts[parts.count-2]; let last = parts[parts.count-1]
        let letters = pre.components(separatedBy:CharacterSet.letters.inverted).joined()
        let digits = last.components(separatedBy:CharacterSet.decimalDigits.inverted).joined()
        if !letters.isEmpty && !digits.isEmpty { return letters+digits }
    }
    return String(s.prefix(10))
}

// 状态小点：带雾化光晕（三层同心半透明渐隐），画布加大；bounds 让点在文字行垂直居中
func dotAttachment(_ color:NSColor, r:CGFloat=2.0)->NSTextAttachment {
    let canvas: CGFloat = 12
    let img = NSImage(size:NSSize(width:canvas, height:canvas))
    img.isTemplate = false
    img.lockFocus()
    let cx = canvas/2
    // 雾化光晕：由外向内 alpha 递增
    for (gr, ga) in [(5.2, 0.10), (4.0, 0.18), (3.0, 0.30)] {
        color.withAlphaComponent(CGFloat(ga)).setFill()
        NSBezierPath(ovalIn:NSRect(x:cx-CGFloat(gr), y:cx-CGFloat(gr), width:CGFloat(gr)*2, height:CGFloat(gr)*2)).fill()
    }
    color.setFill()
    NSBezierPath(ovalIn:NSRect(x:cx-r, y:cx-r, width:r*2, height:r*2)).fill()
    img.unlockFocus()
    let a = NSTextAttachment()
    a.image = img
    // bounds.y 相对 baseline（正=向上）：origin=-2 → 图片占 [-2,+10]，点中心在 baseline 上方 4px = 文字视觉中线
    a.bounds = NSRect(x:0, y:-2, width:canvas, height:canvas)
    return a
}

class App: NSObject {
    let item = NSStatusBar.system.statusItem(withLength:NSStatusItem.variableLength)
    var measuring = false
    var lastMeasuredNode: String? = nil
    var dispFull: String? = nil
    var dispBW = ""          // 网速文字："76M" / "…" / "失败" / "超时" / "读不到"
    var dispBWOk = true      // 网速是否正常（失败染红字）
    var dispDelay: Int? = nil
    var dispStale = false
    var hasResult = false
    var lastMeasureTime: Date? = nil      // 最近一次成功测速时间 → M 定时过期用
    let STALE_SECONDS: TimeInterval = 10  // 超过 10 秒未重测 → M 变黑（节点网速波动快，有效期按秒算）

    @objc func onClick(_ sender:Any?){ measure() }

    // 小点只管延迟（2026-09-09 03:19 用户定稿，不管数据新旧）：
    // 绿=延迟<150ms / 黄=150~300ms / 红=>300ms 或失败超时 / 灰=测速中或无延迟数据（中性）
    func dotColor()->NSColor {
        if hasResult && !dispBWOk { return .systemRed }
        guard hasResult, let d = dispDelay else {
            return NSColor.controlTextColor.withAlphaComponent(0.3)
        }
        return d < 150 ? .systemGreen : (d < 300 ? .systemYellow : .systemRed)
    }

    func render(){
        guard let btn = item.button else { return }
        let full = dispFull ?? "?"
        let short = (full == "?") ? "!" : shortName(full)

        let f = NSFont.menuBarFont(ofSize:0)
        let fNum = NSFont.monospacedDigitSystemFont(ofSize:f.pointSize, weight:.regular)
        let main = NSColor.controlTextColor

        let s = NSMutableAttributedString()
        s.append(NSAttributedString(string:short, attributes:[.font:f, .foregroundColor:main]))

        if !dispBW.isEmpty {
            s.append(NSAttributedString(string:" ", attributes:[.font:f]))
            s.append(NSAttributedString(attachment: dotAttachment(dotColor(), r:2.0)))
            let col: NSColor = dispBWOk ? main : .systemRed
            s.append(NSAttributedString(string:" ", attributes:[.font:f]))

            // M 数据新旧指示（用户定稿）：最新=M 白色；过期=M 黑色（深色菜单栏上黑=熄灭，对比最大）
            if dispBW.hasSuffix("M") {
                let num = String(dispBW.dropLast())
                let unitSize: CGFloat = max(9, f.pointSize - 3)
                let fUnit = NSFont.systemFont(ofSize:unitSize, weight:.regular)
                s.append(NSAttributedString(string:num, attributes:[.font:fNum, .foregroundColor:col]))
                // 数字与单位之间留一丢丢间距（两个窄空格）
                s.append(NSAttributedString(string:"\u{2009}\u{2009}", attributes:[.font:fUnit]))
                let mColor: NSColor = dispStale ? NSColor.black.withAlphaComponent(0.85) : .white
                s.append(NSAttributedString(string:"M", attributes:[
                    .font:fUnit,
                    .foregroundColor: mColor
                ]))
            } else {
                s.append(NSAttributedString(string:dispBW, attributes:[.font:fNum, .foregroundColor:col]))
            }
        }

        btn.attributedTitle = s
        btn.toolTip = (full == "?" ? "读不到节点（正在自动重新探测 Clash 接口…）" : full)
            + "\n小点=延迟：绿<150ms / 黄150~300 / 红>300或失败；M 变黑=数据过期（换节点或超10秒），点一下刷新"
            + "\n点击刷新"
    }

    override init(){
        super.init()
        item.behavior = []
        item.autosaveName = "TiZiMenuStatusItem"
        item.button?.action = #selector(onClick); item.button?.target = self
        if currentNode() == nil { discoverAPI(); discoverPort() }  // 起不来就先摸一遍
        dispFull = currentNode()
        render()
        measure()
        Timer.scheduledTimer(withTimeInterval:5, repeats:true){ [weak self] _ in
            guard let self = self, !self.measuring else { return }
            if let cur = currentNode() {
                if self.dispFull != cur { self.dispFull = cur; self.render() }
                // M 过期判定（二选一即黑）：① 当前节点 ≠ 测速时节点；② 距上次成功测速超 10 秒
                if let lm = self.lastMeasuredNode {
                    let stale = (cur != lm)
                        || Date().timeIntervalSince(self.lastMeasureTime ?? .distantPast) > self.STALE_SECONDS
                    if stale != self.dispStale { self.dispStale = stale; self.render() }
                }
            } else if Date().timeIntervalSince(lastRediscover) > 30 {
                // 读不到节点 → 限频自动重发现 socket/端口/密钥（Clash 升级改路径也能自愈）
                lastRediscover = Date()
                DispatchQueue.global().async { discoverAPI(); discoverPort() }
            }
        }
    }

    func measure(){
        guard !measuring else { return }
        measuring = true
        dispStale = false
        dispFull = currentNode()
        dispBW = "…"
        dispBWOk = true
        hasResult = false
        render()
        var done = false
        // 45s 兜底：限时测速单源最多 18s，卡死源由 --speed-limit 快速淘汰
        let timeout = DispatchWorkItem { [weak self] in
            guard let self = self, !done else { return }
            done = true; self.measuring = false
            self.dispBW = "超时"; self.dispBWOk = false; self.hasResult = true
            self.lastMeasuredNode = nil
            logLine("测速兜底超时 45s")
            self.render()
        }
        DispatchQueue.main.asyncAfter(deadline:.now()+30, execute:timeout)
        DispatchQueue.global().async {
            let n = currentNode() ?? "?"
            let d = (n != "?") ? nodeDelay(n) : nil
            let b = nodeBW()
            DispatchQueue.main.async {
                guard !done else { return }
                done = true; timeout.cancel(); self.measuring = false
                self.dispFull = (n == "?") ? nil : n
                self.hasResult = true
                self.dispDelay = d
                if n == "?" {
                    self.dispBW = "读不到"; self.dispBWOk = false
                    self.lastMeasuredNode = nil
                    logLine("读不到节点：接口失联")
                } else if let _ = d, let b = b {
                    let bwStr = (b >= 10) ? String(format:"%.0fM", b) : String(format:"%.1fM", b)
                    self.dispBW = bwStr; self.dispBWOk = true
                    self.lastMeasuredNode = n
                    self.lastMeasureTime = Date()
                    logLine("\(n) 延迟\(d!)ms 带宽\(bwStr)")
                } else {
                    self.dispBW = "失败"; self.dispBWOk = false
                    self.lastMeasuredNode = nil
                    logLine("\(n) 测速失败：延迟=\(d.map{String($0)} ?? "无") 带宽=\(b.map{String($0)} ?? "nil")（三源全废或延迟失败）")
                }
                self.render()
            }
        }
    }
}

let app = App()
NSApplication.shared.setActivationPolicy(.accessory)
NSApplication.shared.run()
