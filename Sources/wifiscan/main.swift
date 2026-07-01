// wifiscan — a terminal WiFi survey & channel planner for macOS
//
// Backend: CoreWLAN (CWWiFiClient) — the only API on modern macOS (airport is
// gone since 14.4) that returns RSSI / channel / band / width / security for
// *neighbouring* networks. Requires Location Services permission for the
// responsible app (Ghostty/iTerm/Terminal) to reveal SSIDs.
//
// What macOS will NOT give a third-party binary (and so we don't model): BSSID
// and country code are gated behind Apple-private entitlements
// (com.apple.private.corewifi.bssid / .countrycode) carried only by airportd and
// Apple's own tools, so they always come back nil — there is no point storing them.
//
// noise floor caveat: macOS only measures noise on the channel the radio is
// currently tuned to, so neighbouring BSSes report noise == 0. SNR is therefore
// meaningful only for the channel you're on; we show "—" otherwise and lean on
// RSSI + channel congestion instead.
//
// The pure model / channel-plan / congestion / layout logic lives in Core.swift
// (framework-free, unit-tested). This file holds CoreWLAN/CoreLocation, the TUI,
// the out-of-process scan helper, and the entrypoint.

import CoreLocation
import CoreWLAN
import Darwin
import Foundation

// MARK: - Scanner

final class Scanner {
    let client = CWWiFiClient.shared()
    var iface: CWInterface? { client.interface() }

    var interfaceName: String { iface?.interfaceName ?? "—" }
    var currentSSID: String? { iface?.ssid() }
    var powerOn: Bool { iface?.powerOn() ?? false }

    static let securityChecks: [(CWSecurity, String)] = [
        (.wpa3Enterprise, "WPA3-E"), (.wpa3Personal, "WPA3"), (.wpa3Transition, "WPA3-T"),
        (.wpa2Enterprise, "WPA2-E"), (.wpa2Personal, "WPA2"),
        (.wpaEnterprise, "WPA-E"), (.wpaPersonal, "WPA"),
        (.WEP, "WEP"), (.dynamicWEP, "dWEP"), (.none, "Open"),
    ]

    static func securityLabel(_ n: CWNetwork) -> String {
        var hits: [String] = []
        for (s, label) in securityChecks where n.supportsSecurity(s) { hits.append(label) }
        // Collapse common transition combos for readability.
        if hits.contains("WPA3-T") && hits.contains("WPA2") { return "WPA2/3" }
        if hits.contains("WPA3") { return "WPA3" }
        return hits.first ?? "?"
    }

    func scan() -> (nets: [BSS], error: String?) {
        guard let iface = iface else { return ([], "no Wi-Fi interface") }
        do {
            let raw = try iface.scanForNetworks(withName: nil)
            let nets = raw.map { n -> BSS in
                let ch = n.wlanChannel
                return BSS(
                    ssid: (n.ssid?.isEmpty == false ? n.ssid! : "‹hidden›"),
                    rssi: n.rssiValue,
                    noise: n.noiseMeasurement,
                    channel: ch?.channelNumber ?? 0,
                    band: Band.from(ch?.channelBand.rawValue ?? 0),
                    widthMHz: widthCodeToMHz(ch?.channelWidth.rawValue ?? 0),
                    security: Scanner.securityLabel(n),
                    hidden: (n.ssid?.isEmpty != false),
                    utilization: qbssUtilization(n.informationElementData)
                )
            }
            return (nets, nil)
        } catch {
            return ([], error.localizedDescription)
        }
    }
}

// MARK: - Terminal capabilities

/// What the host terminal can do, sniffed once from the environment. Lets the
/// renderer light up modern features on Ghostty/iTerm/kitty while degrading to the
/// portable path on Terminal.app or when piped.
enum Term {
    /// 24-bit colour. Ghostty (and iTerm, kitty, modern xterm) export
    /// COLORTERM=truecolor for child processes; we inherit it whether wifiscan is
    /// typed at a shell or run directly via `ghostty -e`.
    static let truecolor: Bool = {
        let ct = ProcessInfo.processInfo.environment["COLORTERM"]
        return ct == "truecolor" || ct == "24bit"
    }()
}

// MARK: - ANSI

enum Ansi {
    static var enabled = true
    static func wrap(_ s: String, _ code: String) -> String {
        enabled ? "\u{1B}[\(code)m\(s)\u{1B}[0m" : s
    }
    static func bold(_ s: String) -> String { wrap(s, "1") }
    static func dim(_ s: String) -> String { wrap(s, "2") }
    static func fg256(_ s: String, _ c: Int) -> String { wrap(s, "38;5;\(c)") }
    static func bg256(_ s: String, _ c: Int) -> String { wrap(s, "48;5;\(c)") }
    static func fgRGB(_ s: String, _ c: RGB) -> String { wrap(s, "38;2;\(c.r);\(c.g);\(c.b)") }

    // Signal → colour (256-palette). Logic lives in Core (signalColorCode) so it
    // is unit-testable without this enum.
    static func signalColor(_ rssi: Int) -> Int { signalColorCode(rssi) }

    /// Colour a string by signal strength — a smooth 24-bit gradient on truecolor
    /// terminals, the 256-palette bucket otherwise.
    static func signalColored(_ s: String, _ rssi: Int) -> String {
        Term.truecolor ? fgRGB(s, signalRGB(rssi)) : fg256(s, signalColorCode(rssi))
    }
    /// Colour a string by congestion fraction (0 quiet → 1 busiest), truecolor or 256.
    static func congestionColored(_ s: String, _ frac: Double) -> String {
        Term.truecolor ? fgRGB(s, congestionRGB(frac)) : fg256(s, loadColor(frac))
    }
    /// Tint a string with the band's accent colour, truecolor or 256.
    static func bandColored(_ s: String, _ b: Band) -> String {
        Term.truecolor ? fgRGB(s, bandRGB(b)) : fg256(s, bandColorCode(b))
    }

    static func signalBar(_ rssi: Int, width: Int = 10) -> String {
        // Map -90..-30 dBm → 0..width cells, with sub-cell (⅛-block) precision and a
        // dotted track for the remainder.
        let frac = max(0.0, min(1.0, Double(rssi + 90) / 60.0))
        let fill = subCellBar(frac, width: width)
        let track = String(repeating: "·", count: max(0, width - displayWidth(fill)))
        return signalColored(fill + track, rssi)
    }
}

/// Named 256-colour palette for UI chrome. (Signal-quality colours live in
/// signalColorCode; channel-map congestion colours in loadColor.)
private enum Pal {
    static let badgeFg = 231, badgeBg = 25   // "wifiscan" badge
    static let label = 244                   // dim field labels & minor marks (DFS, hidden)
    static let value = 252                   // field values (iface, SSID, …)
    static let text = 250                    // neutral text (table header, rec tags)
    static let heading = 39                  // channel-map band headings
    static let accent = 47                   // recommendations heading / authorized
    static let best = 46                     // highlighted cleanest channel
    static let warn = 208                    // permission warning / not-authorized
    static let error = 196                   // scan errors
    static let scanning = 226                // scanning spinner
}

/// Braille spinner frames for the in-flight scan indicator.
private let spinnerFrames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

/// Channel-map bar colour by congestion fraction (0 = quiet → 1 = busiest channel
/// in the band), so the bar's colour and length tell the same story.
private func loadColor(_ frac: Double) -> Int {
    switch frac {
    case ..<0.20: return 46     // green — quiet
    case ..<0.45: return 82
    case ..<0.70: return 226    // yellow
    case ..<0.88: return 208    // orange
    default:      return 196    // red — most congested
    }
}

/// Clip a possibly-ANSI-coloured string to `cols` visible terminal cells,
/// copying escape sequences verbatim and re-appending a reset if truncated so
/// colour can't bleed past the cut.
private func clipAnsi(_ s: String, _ cols: Int) -> String {
    if cols <= 0 { return "" }
    var out = "", width = 0, truncated = false
    var i = s.startIndex
    while i < s.endIndex {
        let c = s[i]
        if c == "\u{1B}" {                       // copy the whole escape sequence
            out.append(c)
            var j = s.index(after: i)
            while j < s.endIndex {
                let e = s[j]; out.append(e); j = s.index(after: j)
                if e.isLetter { break }
            }
            i = j
            continue
        }
        let cw = charDisplayWidth(c)
        if width + cw > cols { truncated = true; break }
        out.append(c); width += cw
        i = s.index(after: i)
    }
    if truncated && Ansi.enabled { out += "\u{1B}[0m" }
    return out
}

// MARK: - Rendering

let timeFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")   // fixed HH:mm:ss, locale-independent
    f.dateFormat = "HH:mm:ss"
    return f
}()

struct Layout { var rows: Int; var cols: Int }

func termSize() -> Layout {
    var w = winsize()
    if ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &w) == 0, w.ws_row > 0 {
        return Layout(rows: Int(w.ws_row), cols: Int(w.ws_col))
    }
    return Layout(rows: 24, cols: 100)
}

func bandFilterLabel(_ b: Band?) -> String { b?.longLabel ?? "All bands" }

/// Table column widths (responsive-ish; SSID flexes to fill). Shared by renderTable
/// and tableSortRegions so the on-screen layout and the mouse hit-test can't drift.
/// The Load (QBSS airtime) and Trend (sparkline) columns only appear once the window
/// is wide enough to spare the room, so narrow terminals lose nothing.
private func tableColWidths(_ cols: Int) -> (ssid: Int, chan: Int, band: Int, width: Int, sig: Int, bar: Int, snr: Int, util: Int, sec: Int, trend: Int) {
    let chan = 7, band = 5, width = 6, sig = 6, bar = 11, snr = 5, sec = 7
    let util = cols >= 84 ? 5 : 0                        // QBSS airtime column
    let trend = cols >= 96 ? App.historyLen : 0          // sparkline column, wide screens only
    let nCols = 8 + (util > 0 ? 1 : 0) + (trend > 0 ? 1 : 0)
    let fixed = chan + band + width + sig + bar + snr + util + sec + trend + (nCols - 1) // gaps
    let ssid = max(14, min(32, cols - fixed))
    return (ssid, chan, band, width, sig, bar, snr, util, sec, trend)
}

/// x-ranges (1-based screen columns) of each header cell paired with the sort key a
/// click on it selects. Order mirrors renderTable's columns; "dBm", "Signal" and
/// "Trend" all sort by power. Used by mouse click-to-sort.
func tableSortRegions(_ cols: Int) -> [(range: ClosedRange<Int>, key: SortKey)] {
    let w = tableColWidths(cols)
    var order: [(Int, SortKey)] = [
        (w.ssid, .name), (w.chan, .channel), (w.band, .band), (w.width, .width),
        (w.sig, .power), (w.bar, .power), (w.snr, .snr),
    ]
    if w.util > 0 { order.append((w.util, .util)) }
    order.append((w.sec, .security))
    if w.trend > 0 { order.append((w.trend, .power)) }
    var regions: [(range: ClosedRange<Int>, key: SortKey)] = []
    var x = 1
    for (width, key) in order {
        regions.append((x...(x + width - 1), key))
        x += width + 1   // +1 for the " " separator between columns
    }
    return regions
}

private func renderTable(_ nets: [BSS], cols: Int, connSSID: String?, history: [String: [Int]]) -> [String] {
    let w = tableColWidths(cols)
    let (wSSID, wChan, wBand, wWidth, wSig, wBar, wSnr, wUtil, wSec, wTrend) = (w.ssid, w.chan, w.band, w.width, w.sig, w.bar, w.snr, w.util, w.sec, w.trend)
    var out: [String] = []

    var headerCells = [
        padTo("SSID", wSSID), padLeft("Chan", wChan), padTo("Band", wBand),
        padLeft("Width", wWidth), padLeft("dBm", wSig), padTo("Signal", wBar),
        padLeft("SNR", wSnr),
    ]
    if wUtil > 0 { headerCells.append(padLeft("Load", wUtil)) }
    headerCells.append(padTo("Sec", wSec))
    if wTrend > 0 { headerCells.append(padTo("Trend", wTrend)) }
    out.append(Ansi.bold(Ansi.fg256(headerCells.joined(separator: " "), Pal.text)))

    for n in nets {
        let snrStr = n.snr.map { "\($0)" } ?? "—"
        let widthStr = n.widthMHz > 0 ? "\(n.widthMHz)" : "—"
        let connected = connSSID != nil && !n.hidden && n.ssid == connSSID
        // The connected network glows in the accent colour; others use the usual
        // value/dim tints. A leading "▸" marks it without disturbing column widths
        // (it replaces the first cell of the SSID field, which padTo reserves).
        // sanitizeSSID neutralises any terminal escapes a hostile AP put in its name
        // (the connected-match test above compares the raw name, so it's unaffected).
        let safeName = sanitizeSSID(n.ssid)
        let ssidText = connected ? "▸ " + safeName : safeName
        let ssid = connected
            ? Ansi.bold(Ansi.fg256(padTo(ssidText, wSSID), Pal.accent))
            : Ansi.fg256(padTo(ssidText, wSSID), n.hidden ? Pal.label : Pal.value)
        let chan = padLeft("\(n.channel)", wChan)
        let band = Ansi.bandColored(padTo(n.band.label, wBand), n.band)
        let dbm = Ansi.signalColored(padLeft("\(n.rssi)", wSig), n.rssi)
        // signalBar already emits exactly (wBar-1) blocks + 1 space = wBar visible
        // cells, so it is dropped into the row directly — never padded. (padTo on an
        // ANSI string counts escape bytes and would truncate mid-escape.)
        let bar = Ansi.signalBar(n.rssi, width: wBar - 1) + " "
        let snr = padLeft(snrStr, wSnr)
        let sec = padTo(n.security, wSec)
        var cells = [ssid, chan, band, padLeft(widthStr, wWidth), dbm, bar, snr]
        if wUtil > 0 {
            // QBSS airtime, coloured like the channel map (green quiet → red busy).
            let cell = n.utilization.map {
                Ansi.congestionColored(padLeft("\(Int(($0 * 100).rounded()))%", wUtil), $0)
            } ?? Ansi.fg256(padLeft("—", wUtil), Pal.label)
            cells.append(cell)
        }
        cells.append(sec)
        if wTrend > 0 {
            // Right-align the sparkline so the latest sample sits at the column edge;
            // colour it by the current signal so trend and strength read together.
            let samples = history[netKey(n)] ?? [n.rssi]
            let spark = sparkline(samples)
            let padded = String(repeating: " ", count: max(0, wTrend - displayWidth(spark))) + spark
            cells.append(Ansi.signalColored(padded, n.rssi))
        }
        out.append(cells.joined(separator: " "))
    }
    return out
}

private func renderGraph(_ nets: [BSS], cols: Int) -> [String] {
    var out: [String] = []
    let bands: [Band] = [.ghz24, .ghz5, .ghz6]
    var firstBand = true
    for band in bands {
        let inBand = nets.filter { $0.band == band }
        if inBand.isEmpty { continue }
        if !firstBand { out.append("") }      // separator between bands, none before the first
        firstBand = false
        out.append(Ansi.bold(Ansi.fg256("▎ \(band.longLabel)  (\(inBand.count) networks)", Pal.heading)))

        // Occupancy per active channel, weighted by overlapping energy.
        let activeChans = Set(inBand.map { $0.channel }).sorted()
        let loads = Analysis.loads(nets, band: band, candidates: activeChans)
        let maxW = max(loads.map { $0.weighted }.max() ?? 1, 1e-9)
        for load in loads.sorted(by: { $0.channel < $1.channel }) {
            let frac = load.weighted / maxW
            let barMax = max(0, min(cols - 28, 40))
            let bar = subCellBar(frac, width: barMax)   // ⅛-block sub-cell precision
            let dfs = (band == .ghz5 && ChannelPlan.isDFS(load.channel)) ? Ansi.fg256(" DFS", Pal.label) : ""
            let label = padLeft("ch \(load.channel)", 7)
            let cnt = padLeft("\(load.apCount)ap", 5)
            let strongest = padLeft(load.apCount > 0 ? "\(load.strongest)dBm" : "—", 8)
            // Colour by congestion (same metric as the bar's length), so a long red
            // bar reliably means "most congested" rather than "has one loud AP".
            let colored = Ansi.congestionColored(bar, frac)
            out.append("  \(label) \(cnt) \(strongest)  \(colored)\(dfs)")
        }
    }
    return out
}

private func renderRecommendations(_ nets: [BSS], excluding: Set<String>) -> [String] {
    var out: [String] = []
    var heading = Ansi.bold(Ansi.fg256("Recommended clean channels", Pal.accent))
    // Say which of the user's networks were left out of the model, so a "clean"
    // verdict on the channel their own AP occupies isn't a surprise.
    let excluded = excluding.filter { x in nets.contains { $0.ssid == x } }.sorted()
    if !excluded.isEmpty {
        heading += Ansi.dim("  (ignoring your \(excluded.map(sanitizeSSID).joined(separator: ", ")))")
    }
    out.append(heading)

    func fmt(_ recs: [ChannelLoad], band: Band) -> String {
        guard let best = recs.first else { return Ansi.dim("—") }
        // If every candidate is equally empty, none is specifically "best".
        let allClear = recs.allSatisfy { $0.weighted == 0 && $0.apCount == 0 }
        return recs.prefix(3).map { r -> String in
            let dfs = (band == .ghz5 && ChannelPlan.isDFS(r.channel)) ? "*" : ""
            // The margin says whether the runner-up actually matters: "+3dB" ≈ twice
            // the interfering energy of the best pick.
            let margin = loadMarginLabel(r.weighted, best: best.weighted).map { " \($0)" } ?? ""
            let tag = "ch \(r.channel)\(dfs) (\(r.apCount)ap\(margin))"
            return (!allClear && r.channel == best.channel) ? Ansi.bold(Ansi.fg256(tag, Pal.best)) : Ansi.fg256(tag, Pal.text)
        }.joined(separator: "  ")
    }
    func row(_ label: String, _ body: String, _ note: String) {
        out.append("  " + padTo(label, 9) + body + Ansi.dim("  \(note)"))
    }

    if nets.contains(where: { $0.band == .ghz24 }) {
        row("2.4 GHz", fmt(Analysis.recommend(nets, band: .ghz24, candidates: ChannelPlan.cand24, excluding: excluding), band: .ghz24),
            "only 1/6/11 are non-overlapping")
    }
    if nets.contains(where: { $0.band == .ghz5 }) {
        row("5 GHz", fmt(Analysis.recommend(nets, band: .ghz5, candidates: ChannelPlan.cand5NonDFS, excluding: excluding), band: .ghz5),
            "non-DFS (preferred)")
        row("", fmt(Analysis.recommend(nets, band: .ghz5, candidates: ChannelPlan.cand5DFS, excluding: excluding), band: .ghz5),
            "DFS* — cleaner, but may drop on radar")
    }
    if nets.contains(where: { $0.band == .ghz6 }) {
        row("6 GHz", fmt(Analysis.recommend(nets, band: .ghz6, candidates: ChannelPlan.cand6PSC, excluding: excluding), band: .ghz6),
            "PSC channels")
    }
    return out
}

// MARK: - App

final class App {
    let scanner = Scanner()
    let lock = NSLock()

    // --- fields shared with the background scan thread (guard with `lock`) ---
    var nets: [BSS] = []
    var scanError: String?
    var lastScan: Date?
    var scanning = false
    var scanCount = 0
    var locationStatus = "unknown"
    var ifaceName = "—"            // cached so draw() never calls CoreWLAN per frame
    var connSSID: String?
    var generation = 0             // bumped on every visible state change; the loop draws only when it advances

    // --- UI state (main-thread-confined; not locked) ---
    var sortKey: SortKey = .power
    var ascending = false
    var bandFilter: Band? = nil
    var graphMode = false
    var showHelp = false
    var autoRefresh = true
    var interval: TimeInterval = 6
    var scroll = 0
    var quit = false

    // --- config (set once at startup, read-only afterwards) ---
    var excludeSSIDs: Set<String> = []   // --exclude-ssid: your own APs, kept out of recommendations
    var logPath: String?                 // --log: append every scan as survey JSONL

    /// SSIDs kept out of the congestion/recommendation model: yours. The connected
    /// network is always excluded — moving your own AP moves its energy with it, so
    /// counting it would bias recommendations away from its current channel.
    func effectiveExclusions(conn: String?) -> Set<String> {
        var e = excludeSSIDs
        if let c = conn { e.insert(c) }
        return e
    }

    // --- render frame cache (main-thread-confined) ---
    var lastFrame = ""
    var lastCols = 0
    var lastRows = 0
    var lastTitle = ""             // last OSC-2 window title emitted (de-dupe)

    // --- mouse hit-test state, refreshed each draw (main-thread-confined) ---
    var headerScreenRow = -1                                  // 1-based row of the table header (-1 = none/graph)
    var sortRegions: [(range: ClosedRange<Int>, key: SortKey)] = []
    /// Sort key whose header cell covers 1-based screen column `col`, if any.
    func sortColumnAt(_ col: Int) -> SortKey? { sortRegions.first { $0.range.contains(col) }?.key }

    // --- per-network RSSI history for sparklines (guard with `lock`) ---
    static let historyLen = 12
    static let graceMisses = 3     // scans a network may miss before its history drops
    var history: [String: [Int]] = [:]
    var historyMiss: [String: Int] = [:]   // consecutive scans each key has been absent
    /// Copy the history under the lock for use on the main (render) thread.
    func historyCopy() -> [String: [Int]] { lock.lock(); defer { lock.unlock() }; return history }
    /// Lightweight locked read of the scanning latch (for the spinner animation).
    func isScanning() -> Bool { lock.lock(); defer { lock.unlock() }; return scanning }

    var spinnerTick = 0            // advances each idle loop while scanning (main-thread-confined)

    init() {
        ifaceName = scanner.interfaceName
        connSSID = scanner.currentSSID
    }

    /// Kick off a scan on a background thread. Returns false if one is already in
    /// flight (so callers don't count a skipped tick as a refresh).
    @discardableResult
    func triggerScan() -> Bool {
        lock.lock()
        if scanning { lock.unlock(); return false }
        scanning = true
        generation += 1          // surface the scanning spinner
        lock.unlock()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            // Always release the latch, even on an unexpected early return — a stuck
            // `scanning` would otherwise freeze every future scan.
            defer { self.lock.lock(); self.scanning = false; self.lock.unlock() }
            let result = HelperClient.shared.scan()   // persistent open-launched helper so SSIDs are visible
            let iface = self.scanner.interfaceName
            // The front-end may be denied the connected SSID (it isn't an app session
            // under macOS 26's redaction rules); the helper always is — fall back to it.
            let conn = self.scanner.currentSSID ?? result.conn
            if result.error == nil, let path = self.logPath {
                appendSurveyLog(path, nets: result.nets)
            }
            self.lock.lock()
            if result.error == nil {
                self.nets = result.nets
                // Append this scan's RSSI to each network's ring buffer. WiFi scans
                // routinely miss a beacon, so an absent network keeps its history for
                // graceMisses consecutive misses before it's dropped — one bad scan
                // shouldn't wipe a stable neighbour's trend.
                let live = Set(result.nets.map { netKey($0) })
                for key in self.history.keys where !live.contains(key) {
                    self.historyMiss[key, default: 0] += 1
                    if self.historyMiss[key]! >= App.graceMisses {
                        self.history[key] = nil
                        self.historyMiss[key] = nil
                    }
                }
                for n in result.nets {
                    let key = netKey(n)
                    self.historyMiss[key] = nil
                    var h = self.history[key, default: []]
                    h.append(n.rssi)
                    if h.count > App.historyLen { h.removeFirst(h.count - App.historyLen) }
                    self.history[key] = h
                }
            }
            self.scanError = result.error
            if let s = result.status { self.locationStatus = s }
            self.ifaceName = iface
            self.connSSID = conn
            self.lastScan = Date()
            self.scanCount += 1
            self.generation += 1
            self.lock.unlock()
        }
        return true
    }

    func snapshot() -> (nets: [BSS], err: String?, last: Date?, scanning: Bool, count: Int,
                        iface: String, conn: String?, loc: String) {
        lock.lock(); defer { lock.unlock() }
        return (nets, scanError, lastScan, scanning, scanCount, ifaceName, connSSID, locationStatus)
    }

    /// Bump the redraw generation under the lock (called on the main thread on input).
    func markDirty() { lock.lock(); generation += 1; lock.unlock() }
    /// Read the redraw generation under the lock.
    func readGeneration() -> Int { lock.lock(); defer { lock.unlock() }; return generation }

    func visibleNets(_ all: [BSS]) -> [BSS] {
        let filtered = bandFilter == nil ? all : all.filter { $0.band == bandFilter }
        return sortNets(filtered, by: sortKey, ascending: ascending)
    }
}

// MARK: - Terminal raw mode

private var savedTermios = termios()
private var rawActive: sig_atomic_t = 0

private func writeRaw(_ s: String) {
    var bytes = Array(s.utf8)
    _ = write(STDOUT_FILENO, &bytes, bytes.count)
}

private func enterRaw() {
    tcgetattr(STDIN_FILENO, &savedTermios)
    rawActive = 1   // set first, so a signal arriving mid-setup still restores fully
    var raw = savedTermios
    raw.c_lflag &= ~(UInt(ECHO | ICANON | ISIG | IEXTEN))
    raw.c_iflag &= ~(UInt(IXON | ICRNL | BRKINT | INPCK | ISTRIP))
    raw.c_oflag &= ~(UInt(OPOST))
    // VMIN = 0, VTIME = 1 → read returns after 0.1s if no key (paces the loop).
    withUnsafeMutablePointer(to: &raw.c_cc) {
        $0.withMemoryRebound(to: cc_t.self, capacity: Int(NCCS)) { cc in
            cc[Int(VMIN)] = 0
            cc[Int(VTIME)] = 1
        }
    }
    tcsetattr(STDIN_FILENO, TCSANOW, &raw)
    // alt screen + hide cursor · save the window title so we can restore it on exit
    // · enable SGR mouse reporting (button presses + wheel). Terminals that don't
    // support a given mode silently ignore it.
    writeRaw("\u{1B}[?1049h\u{1B}[?25l\u{1B}[22;2t\u{1B}[?1000h\u{1B}[?1006h")
}

/// Async-signal-safe: uses only write() and tcsetattr() (both on the POSIX
/// async-signal-safe list) — never stdio — so it is safe to call from a signal
/// handler as well as the normal exit path. Idempotent via rawActive.
private func leaveRaw() {
    guard rawActive != 0 else { return }
    rawActive = 0
    // Mirror enterRaw in reverse: disable mouse · show cursor + main screen · restore
    // the saved window title. All async-signal-safe (write only).
    writeRaw("\u{1B}[?1006l\u{1B}[?1000l\u{1B}[?25h\u{1B}[?1049l\u{1B}[23;2t")
    tcsetattr(STDIN_FILENO, TCSANOW, &savedTermios)
}

/// A decoded mouse report (SGR 1006). `col`/`row` are 1-based screen cells.
struct MouseEvent { let button: Int; let col: Int; let row: Int; let press: Bool }

/// One unit of input: a single-key command, a mouse report, or nothing this tick.
enum Input { case key(Character), mouse(MouseEvent), none }

private func readByte() -> UInt8? {
    var b: UInt8 = 0
    return read(STDIN_FILENO, &b, 1) == 1 ? b : nil
}

private func readInput() -> Input {
    guard let b = readByte() else { return .none }
    if b != 0x1B {
        // ASCII only — TUI commands are all single-byte; ignore multibyte UTF-8.
        return b < 0x80 ? .key(Character(UnicodeScalar(b))) : .none
    }
    // ESC: a lone Esc, an arrow/function key, or an SGR mouse report. Only CSI ("ESC [")
    // carries mouse; anything else we drain and ignore. A lone Esc (nothing follows
    // within VTIME) is a real keypress — surface it so it can quit / close help.
    guard let b1 = readByte() else { return .key("\u{1B}") }
    guard b1 == 0x5B /* [ */ else { _ = readByte(); return .none }  // e.g. SS3 (ESC O …)
    // Drain the CSI body up to its final byte (0x40–0x7E). Draining the WHOLE sequence
    // — not a fixed byte count — is what keeps a mouse report's digits from leaking out
    // as stray single-key commands. 32 bytes is well above any real sequence.
    var body = [UInt8]()
    for _ in 0..<32 {
        guard let c = readByte() else { break }
        body.append(c)
        if (0x40...0x7E).contains(c) { break }
    }
    // SGR mouse: "ESC [ < b ; x ; y" then 'M' (press) or 'm' (release).
    if let first = body.first, first == 0x3C /* < */,
       let final = body.last, final == 0x4D /* M */ || final == 0x6D /* m */ {
        let nums = String(decoding: body.dropFirst().dropLast(), as: UTF8.self)
            .split(separator: ";").compactMap { Int($0) }
        if nums.count == 3 {
            return .mouse(MouseEvent(button: nums[0], col: nums[1], row: nums[2], press: final == 0x4D))
        }
    }
    return .none
}

// MARK: - Interactive loop

func runInteractive(app: App) {
    // Install restore-on-signal BEFORE mutating terminal state (closes the
    // startup race). leaveRaw() is async-signal-safe; _exit() skips stdio+atexit.
    for sig in [SIGINT, SIGTERM] {
        signal(sig) { _ in
            // kill() is async-signal-safe; reap the persistent helper on Ctrl-C so
            // it doesn't linger (it would self-exit on heartbeat loss anyway).
            if helperPidGlobal > 0 { kill(helperPidGlobal, SIGTERM) }
            leaveRaw(); _exit(0)
        }
    }
    atexit { leaveRaw() }
    enterRaw()

    app.triggerScan()
    var lastAuto = Date()
    var lastBeat = Date.distantPast
    var lastGen = -1, lastCols = 0, lastRows = 0

    while !app.quit {
        // Heartbeat the persistent helper so it stays alive between scans (the
        // auto-refresh interval can be far longer than the helper's staleness window).
        if Date().timeIntervalSince(lastBeat) >= 3 {
            HelperClient.shared.beat()
            lastBeat = Date()
        }
        // Auto-refresh. Only reset the timer when a scan actually started, so a
        // tick skipped because a scan was still in flight retries next loop
        // instead of silently stretching the interval.
        if app.autoRefresh, Date().timeIntervalSince(lastAuto) >= app.interval {
            if app.triggerScan() { lastAuto = Date() }
        }
        // Redraw only when something actually changed — input, scan state, or a
        // resize. Otherwise the loop just idles in readKey() at ~0% CPU. While a scan
        // is in flight we also tick the spinner so it animates (~10 fps via VTIME).
        let sz = termSize()
        let gen = app.readGeneration()
        let scanning = app.isScanning()
        if scanning { app.spinnerTick &+= 1 }
        if gen != lastGen || sz.cols != lastCols || sz.rows != lastRows || scanning {
            draw(app)
            lastGen = gen; lastCols = sz.cols; lastRows = sz.rows
        }
        switch readInput() {
        case .key(let k):   handleKey(k, app: app)
        case .mouse(let m): handleMouse(m, app: app)
        case .none:         break
        }
    }
    leaveRaw()
    savePrefs(app)               // remember sort/filter/interval for next launch
    HelperClient.shared.shutdown()
}

func handleKey(_ k: Character, app: App) {
    // The help overlay is modal-lite: whatever the key, just dismiss it.
    if app.showHelp { app.showHelp = false; app.markDirty(); return }
    switch k {
    case "q", "\u{1B}", "\u{04}", "\u{03}": app.quit = true  // q / Esc / Ctrl-D / Ctrl-C (ISIG is off)
    case "?": app.showHelp = true; app.scroll = 0
    case "r": app.triggerScan()
    case "a": app.autoRefresh.toggle()
    case "g", "\t": app.graphMode.toggle(); app.scroll = 0
    case "p": setSort(app, .power)
    case "s": setSort(app, .snr)
    case "c": setSort(app, .channel)
    case "n": setSort(app, .name)
    case "w": setSort(app, .width)
    case "e": setSort(app, .security)
    case "l": setSort(app, .util)
    case "b": cycleBand(app)
    case "1": app.bandFilter = .ghz24; app.scroll = 0
    case "2": app.bandFilter = .ghz5; app.scroll = 0
    case "6": app.bandFilter = .ghz6; app.scroll = 0
    case "0": app.bandFilter = nil; app.scroll = 0
    case "j": app.scroll += 1
    case "k": app.scroll = max(0, app.scroll - 1)
    case "d", " ": app.scroll += 10
    case "u": app.scroll = max(0, app.scroll - 10)
    case "+", "=": app.interval = min(60, app.interval + 1)
    case "-", "_": app.interval = max(2, app.interval - 1)
    default: break
    }
    app.markDirty()   // any key may have changed view state → redraw next loop
}

func handleMouse(_ m: MouseEvent, app: App) {
    // Wheel reports as buttons 64 (up) / 65 (down), regardless of press/release.
    if m.button & 64 != 0 {
        if m.button & 1 == 0 { app.scroll = max(0, app.scroll - 3) }   // wheel up
        else { app.scroll += 3 }                                       // wheel down (draw clamps)
        app.markDirty()
        return
    }
    // Left-button press on the table header → sort by the clicked column. Bit 5 (32)
    // marks motion/drag; the low two bits select the button (0 = left).
    let leftPress = m.press && m.button & 0b11 == 0 && m.button & 32 == 0
    guard leftPress, !app.graphMode, m.row == app.headerScreenRow else { return }
    if let key = app.sortColumnAt(m.col) {
        setSort(app, key)
        app.markDirty()
    }
}

func setSort(_ app: App, _ key: SortKey) {
    if app.sortKey == key { app.ascending.toggle() } else { app.sortKey = key; app.ascending = false }
    app.scroll = 0
}

func cycleBand(_ app: App) {
    switch app.bandFilter {
    case nil: app.bandFilter = .ghz24
    case .ghz24: app.bandFilter = .ghz5
    case .ghz5: app.bandFilter = .ghz6
    case .ghz6, .unknown: app.bandFilter = nil
    }
    app.scroll = 0
}

func draw(_ app: App) {
    let layout = termSize()
    let snap = app.snapshot()
    let visible = app.visibleNets(snap.nets)

    // Live window/tab title (OSC 2), emitted only when it changes. Shown by Ghostty
    // et al.; restored to the saved title on exit (see leaveRaw).
    if Ansi.enabled {
        let title = "wifiscan — \(snap.nets.count) networks · \(snap.iface)"
        if title != app.lastTitle {
            app.lastTitle = title
            print("\u{1B}]2;\(title)\u{07}", terminator: "")
        }
    }

    var lines: [String] = []

    // Header — an animated braille spinner while a scan is in flight.
    let spinner = spinnerFrames[app.spinnerTick % spinnerFrames.count]
    let scanningTag = snap.scanning ? Ansi.fg256(" \(spinner) scanning…", Pal.scanning) : ""
    let lastStr = snap.last.map { timeFormatter.string(from: $0) } ?? "—"
    let head1 = Ansi.bg256(Ansi.bold(Ansi.fg256("  wifiscan  ", Pal.badgeFg)), Pal.badgeBg)
        + " " + Ansi.fg256("iface ", Pal.label) + Ansi.fg256(snap.iface, Pal.value)
        + Ansi.fg256("  connected ", Pal.label) + Ansi.fg256(snap.conn.map(sanitizeSSID) ?? "—", Pal.value)
        + Ansi.fg256("  location ", Pal.label)
        + Ansi.fg256(snap.loc, snap.loc == "authorized" ? Pal.accent : Pal.warn)
        + scanningTag
    lines.append(clipAnsi(head1, layout.cols))

    let head2 = Ansi.fg256("networks ", Pal.label) + Ansi.bold("\(snap.nets.count)")
        + Ansi.fg256("  shown ", Pal.label) + "\(visible.count)"
        + Ansi.fg256("  view ", Pal.label) + (app.graphMode ? "channel-map" : "list")
        + Ansi.fg256("  sort ", Pal.label) + app.sortKey.label + (app.ascending ? "↑" : "↓")
        + Ansi.fg256("  filter ", Pal.label) + bandFilterLabel(app.bandFilter)
        + Ansi.fg256("  auto ", Pal.label) + (app.autoRefresh ? "on(\(Int(app.interval))s)" : "off")
        + Ansi.fg256("  last ", Pal.label) + lastStr
    lines.append(clipAnsi(head2, layout.cols))
    lines.append(Ansi.dim(String(repeating: "─", count: min(layout.cols, 120))))

    if let err = snap.err {
        lines.append(clipAnsi(Ansi.fg256("scan error: \(err)", Pal.error), layout.cols))
    }
    // SSID names are masked only when Location isn't authorized — distinguish that
    // from genuinely hidden (cloaked) APs using the helper's reported status.
    let hidden = snap.nets.filter { $0.hidden }.count
    if !snap.nets.isEmpty && hidden > 0 && snap.loc != "authorized" && snap.loc != "unknown" {
        lines.append(Ansi.fg256("⚠ SSIDs hidden — Location Services isn't active for wifiscan.", Pal.warn))
        lines.append(Ansi.dim("  Enable 'wifiscan' in System Settings → Privacy & Security → Location Services, then rerun."))
    }

    // Body
    let recLines = renderRecommendations(snap.nets, excluding: app.effectiveExclusions(conn: snap.conn))
    let footer = footerLines()
    let chrome = lines.count + recLines.count + footer.count + 2
    let bodyBudget = max(3, layout.rows - chrome)

    var body: [String]
    if app.showHelp {
        body = helpOverlayLines()
    } else if app.graphMode {
        body = renderGraph(visible, cols: layout.cols)
    } else {
        body = renderTable(visible, cols: layout.cols, connSSID: snap.conn, history: app.historyCopy())
    }
    // Scroll handling (keep header row when scrolling table).
    let headerRow = (!app.graphMode && !app.showHelp && !body.isEmpty) ? body.removeFirst() : nil
    let maxScroll = max(0, body.count - bodyBudget + (headerRow != nil ? 1 : 0))
    if app.scroll > maxScroll { app.scroll = maxScroll }
    var bodyView = Array(body.dropFirst(app.scroll).prefix(bodyBudget - (headerRow != nil ? 1 : 0)))
    if let h = headerRow { bodyView.insert(h, at: 0) }

    // Record where the table header lands (1-based screen row) and the clickable
    // column regions, so a mouse click can map to a sort column. bodyView[0] is the
    // header, so it renders at the next screen row after the chrome already in `lines`.
    if headerRow != nil {
        app.headerScreenRow = lines.count + 1
        app.sortRegions = tableSortRegions(layout.cols)
    } else {
        app.headerScreenRow = -1
    }

    // Clip EVERY body/recommendation line to the terminal width — an over-long row
    // would wrap (DECAWM) and shear the whole frame on narrow windows.
    lines.append(contentsOf: bodyView.map { clipAnsi($0, layout.cols) })
    // Pad the body region so the bottom chrome sits flush at the bottom. `used` must
    // count ALL trailing lines — the separator (+1), the recommendations, and the
    // footer — otherwise the assembled frame overshoots layout.rows by one and the
    // prefix(layout.rows) below clips the last line (the footer).
    let used = lines.count + 1 + recLines.count + footer.count
    if used < layout.rows {
        lines.append(contentsOf: Array(repeating: "", count: layout.rows - used))
    }
    lines.append(Ansi.dim(String(repeating: "─", count: min(layout.cols, 120))))
    lines.append(contentsOf: recLines.map { clipAnsi($0, layout.cols) })
    lines.append(contentsOf: footer.map { clipAnsi($0, layout.cols) })   // never wrap the layout

    // Paint. Clear each line to EOL rather than wiping the whole screen every frame
    // (that caused continuous flicker), and skip the write entirely when the frame
    // is byte-identical to the last one (the loop runs ~10x/s but data rarely changes).
    let painted = Array(lines.prefix(layout.rows))
    let sizeChanged = (layout.cols != app.lastCols || layout.rows != app.lastRows)
    var screen = sizeChanged ? "\u{1B}[2J\u{1B}[H" : "\u{1B}[H"
    screen += painted.map { $0 + "\u{1B}[K" }.joined(separator: "\r\n")
    screen += "\u{1B}[J"

    if screen == app.lastFrame && !sizeChanged { return }
    app.lastFrame = screen
    app.lastCols = layout.cols
    app.lastRows = layout.rows
    // Synchronized output (DEC 2026): the terminal buffers the whole frame and swaps
    // it in one shot, so a refresh never tears. Ignored by terminals that lack it.
    print("\u{1B}[?2026h" + screen + "\u{1B}[?2026l", terminator: "")
    fflush(stdout)
}

func footerLines() -> [String] {
    let keys = "[q]uit  [?]help  [r]escan  [g]raph  [a]uto  sort p/s/c/n/w/e/[l]oad  [b]and 1/2/6/0  j/k u/d scroll  [+/-]interval  ·  wheel scrolls · click a header to sort"
    return [Ansi.dim(keys)]
}

/// The `?` key's overlay, rendered in place of the table/graph body.
private func helpOverlayLines() -> [String] {
    let rows: [(String, String)] = [
        ("q · Esc · Ctrl-C", "quit"),
        ("?", "toggle this help"),
        ("r", "rescan now"),
        ("a", "toggle auto-refresh"),
        ("g / Tab", "toggle channel-map view"),
        ("p s c n w e l", "sort: power · SNR · channel · name · width · security · load"),
        ("(same key again)", "reverse the sort direction"),
        ("b · 1 2 6 0", "cycle band · filter 2.4 / 5 / 6 / all"),
        ("j k · u d · Space", "scroll: line · 10 lines · 10 lines down"),
        ("+ / -", "auto-refresh interval"),
        ("mouse", "wheel scrolls · click a column header to sort"),
    ]
    var out = [Ansi.bold(Ansi.fg256("Keys", Pal.heading)), ""]
    for (k, v) in rows {
        out.append("  " + Ansi.fg256(padTo(k, 20), Pal.accent) + Ansi.fg256(v, Pal.text))
    }
    out.append("")
    out.append(Ansi.dim("  press any key to close"))
    return out
}

// MARK: - Diagnostics

func runDiag(app: App) {
    let s = app.scanner
    let res = HelperClient.shared.scan()   // scan via the open-launched helper, like the TUI
    defer { HelperClient.shared.shutdown() }
    let named = res.nets.filter { !$0.hidden }.count
    print("wifiscan diagnostics")
    print("  interface          : \(s.interfaceName)")
    print("  power on           : \(s.powerOn)")
    print("  connected ssid     : \(s.currentSSID.map(sanitizeSSID) ?? "—")")
    print("  helper conn ssid   : \(res.conn.map(sanitizeSSID) ?? "—")")
    print("  helper location    : \(res.status ?? "unknown")")
    print("  scan error         : \(res.error ?? "none")")
    print("  networks found     : \(res.nets.count)")
    print("  SSIDs visible      : \(named)/\(res.nets.count)")
    print("  app bundle         : \(appBundlePath())")
    if s.currentSSID == nil && res.conn != nil {
        print("")
        print("  note: the front-end can't read the connected SSID but the helper can;")
        print("        the TUI header falls back to the helper's value automatically.")
    }
    if res.nets.count > 0 && named == 0 {
        print("")
        print("  ⚠ SSIDs are masked — Location Services isn't authorized for wifiscan.")
        print("    System Settings → Privacy & Security → Location Services → enable 'wifiscan'.")
    }
}

// MARK: - One-shot (non-interactive) mode

func runOnce(app: App, json: Bool) {
    let result = HelperClient.shared.scan()
    HelperClient.shared.shutdown()   // one-shot mode: don't leave a daemon behind
    if result.error == nil, let path = app.logPath {
        appendSurveyLog(path, nets: result.nets)   // log the FULL scan, pre-filter
    }
    var all = result.nets
    if let bf = app.bandFilter { all = all.filter { $0.band == bf } }
    let nets = sortNets(all, by: app.sortKey, ascending: app.ascending)
    let conn = app.scanner.currentSSID ?? result.conn
    if json {
        struct Out: Encodable {
            let ssid: String; let rssi: Int; let noise: Int?
            let snr: Int?; let channel: Int; let band: String; let widthMHz: Int
            let security: String; let hidden: Bool; let utilization: Double?
        }
        let arr = nets.map { Out(ssid: $0.ssid, rssi: $0.rssi,
            noise: $0.noiseValid ? $0.noise : nil, snr: $0.snr, channel: $0.channel,
            band: $0.band.longLabel, widthMHz: $0.widthMHz, security: $0.security,
            hidden: $0.hidden, utilization: $0.utilization) }
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(arr), let s = String(data: d, encoding: .utf8) { print(s) }
        else { print("[]") }
        if let e = result.error { FileHandle.standardError.write(Data("scan error: \(e)\n".utf8)) }
        return
    }
    print(Ansi.bold("wifiscan — \(nets.count) networks  (iface \(app.scanner.interfaceName), connected \(conn.map(sanitizeSSID) ?? "—"))"))
    if let e = result.error { print(Ansi.fg256("scan error: \(e)", Pal.error)) }
    if !nets.isEmpty && result.status != "authorized" && nets.contains(where: { $0.hidden }) {
        print(Ansi.fg256("⚠ SSIDs hidden — enable 'wifiscan' in System Settings → Privacy & Security → Location Services.", Pal.warn))
    }
    print("")
    // One-shot: no cross-scan history, so each sparkline shows its single sample.
    for line in renderTable(nets, cols: termSize().cols, connSSID: conn, history: [:]) { print(line) }
    print("")
    for line in renderGraph(nets, cols: termSize().cols) { print(line) }
    print("")
    for line in renderRecommendations(nets, excluding: app.effectiveExclusions(conn: conn)) { print(line) }
    print("")
    print(Ansi.dim("noise/SNR are only reported by macOS for the channel the radio is tuned to; ‹—› elsewhere is expected."))
}

// MARK: - Preferences (persisted TUI view settings)

/// Last-used view settings, restored at the next launch (CLI flags override).
/// Every field is optional so old and new versions of the file coexist.
struct Prefs: Codable {
    var sort: String?
    var ascending: Bool?
    var band: String?
    var interval: Double?
    var autoRefresh: Bool?
    var graphMode: Bool?
}

let prefsPath = NSHomeDirectory() + "/.config/wifiscan/config.json"

/// Shared by --sort and the prefs file (SortKey.label.lowercased() maps back here).
let sortNames: [String: SortKey] = [
    "power": .power, "snr": .snr, "chan": .channel, "channel": .channel, "name": .name,
    "band": .band, "width": .width, "sec": .security, "security": .security,
    "load": .util, "util": .util,
]
/// Shared by --band and the prefs file ("all" → no filter).
let bandNames: [String: Band?] = [
    "2.4": .ghz24, "2": .ghz24, "24": .ghz24, "5": .ghz5, "6": .ghz6, "all": nil,
]

func loadPrefs(into app: App) {
    guard let data = FileManager.default.contents(atPath: prefsPath),
          let p = try? JSONDecoder().decode(Prefs.self, from: data) else { return }
    if let s = p.sort, let k = sortNames[s] { app.sortKey = k }
    if let a = p.ascending { app.ascending = a }
    if let b = p.band, let v = bandNames[b] { app.bandFilter = v }
    if let i = p.interval { app.interval = min(60, max(2, i)) }
    if let a = p.autoRefresh { app.autoRefresh = a }
    if let g = p.graphMode { app.graphMode = g }
}

func savePrefs(_ app: App) {
    let p = Prefs(sort: app.sortKey.label.lowercased(), ascending: app.ascending,
                  band: app.bandFilter?.label ?? "all", interval: app.interval,
                  autoRefresh: app.autoRefresh, graphMode: app.graphMode)
    let dir = (prefsPath as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let d = try? enc.encode(p) { try? d.write(to: URL(fileURLWithPath: prefsPath)) }
}

// MARK: - Survey log & report (--log / --report)

/// Append one scan to the JSONL survey log (one SurveyScan object per line).
func appendSurveyLog(_ path: String, nets: [BSS]) {
    let scan = SurveyScan(ts: Date().timeIntervalSince1970, nets: nets.map(SurveyNet.init))
    guard let data = try? JSONEncoder().encode(scan) else { return }
    if !FileManager.default.fileExists(atPath: path) {
        FileManager.default.createFile(atPath: path, contents: nil)
    }
    guard let fh = FileHandle(forWritingAtPath: path) else { return }
    defer { try? fh.close() }
    _ = try? fh.seekToEnd()
    fh.write(data)
    fh.write(Data("\n".utf8))
}

/// Aggregate a --log survey: per band, the cleanest candidate channel for each hour
/// of day (congestion is time-of-day dependent — an evening-only scan misleads),
/// plus the minimax "all-day pick" whose worst hour is the least bad.
func runReport(path: String, app: App) {
    guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else {
        die("cannot read survey log '\(path)'")
    }
    let dec = JSONDecoder()
    let scans = raw.split(whereSeparator: \.isNewline)
        .compactMap { try? dec.decode(SurveyScan.self, from: Data($0.utf8)) }
    if scans.isEmpty { die("no scans in '\(path)' — record some with --log first") }

    var excl = app.excludeSSIDs
    if let c = app.scanner.currentSSID { excl.insert(c) }

    let cal = Calendar.current
    let hourly = Survey.byHour(scans) { cal.component(.hour, from: Date(timeIntervalSince1970: $0)) }

    let df = DateFormatter()
    df.locale = Locale(identifier: "en_US_POSIX")
    df.dateFormat = "yyyy-MM-dd HH:mm"
    let tsMin = scans.map { $0.ts }.min()!, tsMax = scans.map { $0.ts }.max()!
    print(Ansi.bold("wifiscan survey — \(scans.count) scans, "
        + "\(df.string(from: Date(timeIntervalSince1970: tsMin))) → \(df.string(from: Date(timeIntervalSince1970: tsMax)))"))
    if !excl.isEmpty { print(Ansi.dim("ignoring your networks: \(excl.sorted().map(sanitizeSSID).joined(separator: ", "))")) }

    func loadText(_ w: Double) -> String { w > 0 ? "\(Int((10 * log10(w)).rounded()))dBm" : "clean" }

    let plans: [(Band, [Int], String)] = [
        (.ghz24, ChannelPlan.cand24, "1/6/11 only"),
        (.ghz5, ChannelPlan.cand5NonDFS, "non-DFS"),
        (.ghz6, ChannelPlan.cand6PSC, "PSC"),
    ]
    for (band, candidates, note) in plans {
        guard scans.contains(where: { $0.nets.contains { Band.from($0.band) == band } }) else { continue }
        print("")
        print(Ansi.bold(Ansi.fg256("▎ \(band.longLabel)  (\(note))", Pal.heading)))
        var hourlyLoads: [[ChannelLoad]] = []
        for h in hourly.keys.sorted() {
            let loads = Survey.averageLoads(hourly[h]!, band: band, candidates: candidates, excluding: excl)
            hourlyLoads.append(loads)
            let best = loads.min(by: Analysis.cleaner)!
            let hh = padLeft(String(format: "%02d:00", h), 6)
            print("  \(hh)  ch \(padTo("\(best.channel)", 4)) \(padLeft(loadText(best.weighted), 8))  (\(hourly[h]!.count) scans)")
        }
        if let pick = Survey.allDayPick(hourlyLoads) {
            print("  " + Ansi.bold(Ansi.fg256("all-day pick: ch \(pick.channel)", Pal.best))
                + Ansi.dim("  (worst hour \(loadText(pick.weighted)))"))
        }
    }
}

// MARK: - Out-of-process scan helper
//
// macOS 26 redacts Wi-Fi SSIDs for any process that isn't launched as a real app
// session: a CLI spawned by a shell gets masked names even when Location Services
// is authorized. The fix (found empirically) is to run scans in a helper instance
// of ourselves launched via LaunchServices (`open`), which counts as an app session
// and sees real SSIDs. We keep one such helper alive (the persistent daemon below)
// and hand results back as JSON over a per-front-end control dir.

struct ScanRecord: Codable {
    let ssid: String, rssi: Int, noise: Int, channel: Int
    let band: Int, widthMHz: Int, security: String, hidden: Bool
    let utilization: Double?
}
struct ScanFile: Codable {
    let error: String?
    let status: String?
    let conn: String?          // the helper's view of the connected SSID (see triggerScan)
    let nets: [ScanRecord]
}
private func record(_ b: BSS) -> ScanRecord {
    ScanRecord(ssid: b.ssid, rssi: b.rssi, noise: b.noise, channel: b.channel,
               band: b.band.rawValue, widthMHz: b.widthMHz, security: b.security, hidden: b.hidden,
               utilization: b.utilization)
}
private func bss(_ r: ScanRecord) -> BSS {
    BSS(ssid: r.ssid, rssi: r.rssi, noise: r.noise, channel: r.channel,
        band: Band.from(r.band), widthMHz: r.widthMHz, security: r.security, hidden: r.hidden,
        utilization: r.utilization)
}

/// Resolve the real .app bundle path. Bundle.main is unreliable when we're invoked
/// through the ~/.bin/wifiscan symlink (it reports the symlink's directory), so we
/// resolve the actual executable and walk up to the enclosing ".app".
private func appBundlePath() -> String {
    var size: UInt32 = 4096
    var buf = [CChar](repeating: 0, count: Int(size))
    var exe = Bundle.main.executablePath ?? (CommandLine.arguments.first ?? "")
    let rc = _NSGetExecutablePath(&buf, &size)
    if rc == 0 {
        exe = String(cString: buf)
    } else if rc == -1 {
        // Buffer too small; `size` now holds the required length — retry once.
        buf = [CChar](repeating: 0, count: Int(size))
        if _NSGetExecutablePath(&buf, &size) == 0 { exe = String(cString: buf) }
    }
    var u = URL(fileURLWithPath: exe).resolvingSymlinksInPath()   // follow the symlink into the bundle
    while u.pathExtension != "app" && u.path != "/" {
        u = u.deletingLastPathComponent()
    }
    return u.pathExtension == "app" ? u.path : Bundle.main.bundlePath
}

// MARK: Atomic file IPC helpers

private func atomicWriteString(_ path: String, _ s: String) {
    try? s.write(toFile: path, atomically: true, encoding: .utf8)   // temp + rename
}
private func readIntFile(_ path: String) -> Int? {
    guard let s = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
    return Int(s.trimmingCharacters(in: .whitespacesAndNewlines))
}
private func processAlive(_ pid: pid_t) -> Bool { pid > 0 && kill(pid, 0) == 0 }

// MARK: Persistent scan daemon
//
// Rather than spawn a fresh `open`-launched app per scan (a new process + Location
// engagement + ~1s settle every refresh), launch ONE long-lived helper via `open`
// and drive it over a tiny file protocol in a per-front-end control dir:
//   pid             helper's pid (readiness signal)
//   req / resp      monotonic scan sequence — requested / completed
//   scan-<n>.json   the ScanFile for sequence n
//   beat            front-end heartbeat (epoch s); helper self-exits if it goes stale
// The helper stays a LaunchServices app session (so SSIDs reveal exactly as the
// per-scan helper did) and pays the Location settle only once, at startup.

private var helperPidGlobal: pid_t = 0   // mirrored so the signal handler can SIGTERM it on exit

final class HelperClient {
    static let shared = HelperClient()
    private let dir = NSTemporaryDirectory() + "wifiscan-daemon-\(getpid())/"
    private let lock = NSLock()
    private var seq = 0
    private var helperPid: pid_t?

    /// Refresh the heartbeat so the daemon knows we're alive (call periodically).
    func beat() { atomicWriteString(dir + "beat", "\(Int(Date().timeIntervalSince1970))") }

    /// One scan via the persistent daemon. On the rare infra failure the daemon is
    /// torn down (see daemonScan), so the next call relaunches a fresh one.
    func scan() -> (nets: [BSS], error: String?, status: String?, conn: String?) {
        lock.lock(); defer { lock.unlock() }
        let bundle = appBundlePath()
        // Without a real .app the `open` relaunch can't reveal SSIDs — fail clearly.
        guard bundle.hasSuffix(".app") else {
            return ([], "not running from a .app bundle — install with `make`; SSID scan needs the bundle's identity", nil, nil)
        }
        return daemonScan(bundle: bundle) ?? ([], "scan helper restarting…", nil, nil)
    }

    func shutdown() {
        lock.lock(); defer { lock.unlock() }
        shutdownLocked()
    }

    /// Body of shutdown, for callers that ALREADY hold `lock`. NSLock is not
    /// re-entrant, so daemonScan's timeout path calling the public shutdown() from
    /// inside scan()'s lock would deadlock the scan thread forever — the spinner
    /// would never stop and quitting would hang.
    private func shutdownLocked() {
        if let p = helperPid, processAlive(p) { kill(p, SIGTERM) }
        helperPid = nil; helperPidGlobal = 0
        try? FileManager.default.removeItem(atPath: dir)
    }

    /// nil ⇒ infra failure (caller falls back to a one-shot scan).
    private func daemonScan(bundle: String) -> (nets: [BSS], error: String?, status: String?, conn: String?)? {
        guard ensureRunning(bundle: bundle) else { return nil }
        seq += 1
        let mySeq = seq
        atomicWriteString(dir + "req", "\(mySeq)")
        let deadline = Date().addingTimeInterval(mySeq == 1 ? 12 : 6)   // first scan settles Location
        var lastBeat = Date()
        while Date() < deadline {
            if let r = readIntFile(dir + "resp"), r >= mySeq {
                for _ in 0..<20 {     // the json is written before resp; allow fs settle
                    if let data = FileManager.default.contents(atPath: dir + "scan-\(mySeq).json"),
                       let f = try? JSONDecoder().decode(ScanFile.self, from: data) {
                        try? FileManager.default.removeItem(atPath: dir + "scan-\(mySeq).json")
                        return (f.nets.map(bss), f.error, f.status, f.conn)
                    }
                    usleep(10_000)
                }
                return nil
            }
            usleep(25_000)
            // Keep the daemon alive while we wait — once a second is plenty (its
            // staleness window is 15 s); beating every poll tick was ~40 writes/s.
            if Date().timeIntervalSince(lastBeat) >= 1 { beat(); lastBeat = Date() }
        }
        shutdownLocked()           // wedged helper → kill so the next call relaunches fresh
        return nil
    }

    private func ensureRunning(bundle: String) -> Bool {
        if let p = helperPid, processAlive(p) { return true }
        startHelper(bundle: bundle)
        return helperPid != nil
    }

    private func startHelper(bundle: String) {
        try? FileManager.default.removeItem(atPath: dir)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        seq = 0
        beat()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        // No -W: the helper persists; `open` returns once it has launched the app.
        p.arguments = ["-n", "-g", "-j", bundle, "--args", "--scan-daemon", dir]
        do { try p.run() } catch { return }
        p.waitUntilExit()          // waits for `open`, not the (detached) helper
        let deadline = Date().addingTimeInterval(10)
        var lastBeat = Date()
        while Date() < deadline {   // wait for the helper to publish its pid
            if let pid = readIntFile(dir + "pid").map({ pid_t($0) }), processAlive(pid) {
                helperPid = pid; helperPidGlobal = pid; return
            }
            usleep(50_000)
            if Date().timeIntervalSince(lastBeat) >= 1 { beat(); lastBeat = Date() }
        }
    }
}

/// Persistent helper mode (reached only via `open … --scan-daemon <dir>`): engage
/// Location once, then serve scan requests over the control dir until the
/// front-end's heartbeat goes stale (it quit or crashed).
final class ScanDaemon: NSObject, CLLocationManagerDelegate {
    private let mgr = CLLocationManager()
    private let dir: String
    private let scanner = Scanner()
    private var lastDone = 0
    private var startTime = Date()
    private var lastActivity = Date()
    private var settled = false

    init(dir: String) { self.dir = dir; super.init(); mgr.delegate = self }

    /// Remove our control dir, then exit — used on self-exit paths (orphan/idle) so
    /// a SIGKILLed front-end doesn't leave the dir behind. (On a normal quit the
    /// front-end SIGTERMs us and removes the dir itself.)
    private func cleanExit() -> Never {
        try? FileManager.default.removeItem(atPath: dir)
        exit(0)
    }

    func run() {
        atomicWriteString(dir + "pid", "\(getpid())")   // publish readiness
        mgr.requestWhenInUseAuthorization()
        mgr.startUpdatingLocation()
        startTime = Date(); lastActivity = Date()
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [self] _ in tick() }
        RunLoop.current.run()
    }

    private func authStatus() -> String {
        switch mgr.authorizationStatus {
        case .authorizedAlways, .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "not-determined"
        @unknown default: return "unknown"
        }
    }

    private func tick() {
        let now = Date()
        if !settled {     // one-time Location settle, same as the per-scan helper
            if now.timeIntervalSince(startTime) >= 1.0 { settled = true } else { return }
        }
        if let reqSeq = readIntFile(dir + "req"), reqSeq > lastDone {
            let r = scanner.scan()
            let out = ScanFile(error: r.error, status: authStatus(),
                               conn: scanner.currentSSID, nets: r.nets.map(record))
            if let data = try? JSONEncoder().encode(out) {
                try? data.write(to: URL(fileURLWithPath: dir + "scan-\(reqSeq).json"), options: .atomic)
            }
            atomicWriteString(dir + "resp", "\(reqSeq)")
            try? FileManager.default.removeItem(atPath: dir + "scan-\(reqSeq - 2).json")   // tidy
            lastDone = reqSeq
            lastActivity = now
        }
        // Self-exit once the front-end stops heart-beating …
        if now.timeIntervalSince(startTime) > 5 {
            if let b = readIntFile(dir + "beat") {
                if now.timeIntervalSince1970 - Double(b) > 15 { cleanExit() }
            } else {
                cleanExit()
            }
        }
        // … or after a long idle period, as an ultimate backstop.
        if now.timeIntervalSince(lastActivity) > 300 { cleanExit() }
    }
}

/// Best-effort sweep of temp files / daemon control dirs leaked by helpers that
/// crashed before cleanup. Live daemon dirs are kept fresh by the heartbeat, so
/// only genuinely stale (>5 min untouched) `wifiscan-*` items are removed.
private func sweepStaleTempFiles() {
    let dir = NSTemporaryDirectory()
    guard let items = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
    let cutoff = Date().addingTimeInterval(-300)
    for name in items where name.hasPrefix("wifiscan-") {
        let path = dir + name
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let m = attrs[.modificationDate] as? Date, m < cutoff {
            try? FileManager.default.removeItem(atPath: path)
        }
    }
}

// MARK: - Relaunch in Terminal (for Finder/Spotlight/Dock launches)

/// Open the user's terminal and run this binary there, so a double-click "opens
/// the app". Quitting the TUI closes the window. The in-bundle binary keeps the
/// app's code identity, so Location works.
///
/// Preference order, each gated on being installed (a deliberate third-party
/// terminal is a strong signal it's the user's): Ghostty → iTerm → Terminal.app
/// (always present, so the final fallback).
private func relaunchInTerminal() {
    let exe = Bundle.main.executablePath ?? CommandLine.arguments.first ?? "wifiscan"
    if launchInGhostty(exe: exe) { return }
    relaunchViaAppleScript(exe: exe)
}

/// Ghostty has no AppleScript dictionary, so it's driven the way `ghostty --help`
/// documents: `open -na Ghostty.app --args -e <command>`. With `-e`, Ghostty runs
/// the binary directly as the surface's process and auto-closes (and quits the
/// new instance) when it exits — the same "quit the TUI, window goes away" feel as
/// the `exec`-into-a-shell path below, with no shell wrapper needed. Returns true
/// only if a Ghostty window was actually launched.
private func launchInGhostty(exe: String) -> Bool {
    let home = NSHomeDirectory()
    let installed = ["/Applications/Ghostty.app", "\(home)/Applications/Ghostty.app"]
        .contains { FileManager.default.fileExists(atPath: $0) }
    guard installed else { return false }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    // `exe` is one argv element, so spaces in the path survive untouched.
    p.arguments = ["-na", "Ghostty.app", "--args", "-e", exe]
    do { try p.run() } catch { return false }
    p.waitUntilExit()                 // waits for `open`, which returns once Ghostty launches
    return p.terminationStatus == 0
}

/// AppleScript-driven fallback for iTerm / Terminal.app, which both expose a
/// scripting dictionary. `exec` replaces the spawned shell with wifiscan, so
/// quitting the TUI closes the window.
private func relaunchViaAppleScript(exe: String) {
    let shellSafe = exe.replacingOccurrences(of: "'", with: "'\\''")   // shell single-quote escape
    let shellCmd = "clear; exec '\(shellSafe)'"
    // The command is interpolated into a double-quoted AppleScript string literal,
    // so escape AppleScript metacharacters too (backslash first, then quote) —
    // otherwise a '"' or '\' in the path breaks out of the literal.
    let asSafe = shellCmd
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    let script: String
    if FileManager.default.fileExists(atPath: "/Applications/iTerm.app") {
        script = """
        tell application "iTerm"
            activate
            set w to (create window with default profile)
            tell current session of w to write text "\(asSafe)"
        end tell
        """
    } else {
        script = """
        tell application "Terminal"
            activate
            do script "\(asSafe)"
        end tell
        """
    }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", script]
    try? p.run()
    p.waitUntilExit()
}

// MARK: - Entry

func printHelp() {
    print("""
    wifiscan — WiFi survey & channel planner (macOS, CoreWLAN)

    USAGE:
      wifiscan                   interactive TUI (default)
      wifiscan --once            one scan: table + channel map + recommendations
      wifiscan --json            one scan as JSON on stdout
      wifiscan --diag            print scan/permission diagnostics
      wifiscan --report <file>   aggregate a --log survey: cleanest channel by hour
      wifiscan --help            show this help  (also -h)

    OPTIONS:
      --band 2.4|5|6|all         filter to one band (TUI initial filter / one-shot)
      --sort power|snr|channel|name|band|width|security|load
      --exclude-ssid a[,b]       keep your own network(s) out of the recommendations
                                 (the connected SSID is always excluded)
      --log <file>               append every scan to a JSONL survey log

    Colour is automatic: on in a terminal, off when piped/redirected (or set NO_COLOR).

    TUI KEYS:
      q / Esc / Ctrl-C quit · ? help · r rescan · g / Tab channel-map · a auto-refresh
      p/s/c/n/w/e/l sort (press again to reverse) · b cycle band
      1/2/6 filter band · 0 all bands · j/k u/d scroll · +/- refresh interval
      mouse: wheel scrolls · click a column header to sort

    FILES:
      ~/.config/wifiscan/config.json   last-used view settings (restored at startup)
    """)
}

/// Print a usage error to stderr and exit 2.
func die(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("error: \(msg) (see --help)\n".utf8))
    exit(2)
}

func main() {
    let args = Array(CommandLine.arguments.dropFirst())
    let app = App()

    if args.contains("--help") || args.contains("-h") { printHelp(); return }

    // Internal helper mode — reached only when relaunched via `open`, never typed.
    if let i = args.firstIndex(of: "--scan-daemon") {
        let d = i + 1 < args.count ? args[i + 1] : NSTemporaryDirectory() + "wifiscan-daemon/"
        ScanDaemon(dir: d).run()
        return
    }

    // Parse: bare mode switches plus valued options. Anything unrecognised is a
    // clean error exit (also turns a stray legacy `--scan-json` launch into an
    // error rather than a Terminal pop-up).
    var modes = Set<String>()
    var bandFlag: Band?? = nil          // parsed --band ("all" → .some(nil))
    var sortFlag: SortKey?
    var reportPath: String?
    var i = 0
    while i < args.count {
        let a = args[i]
        func value() -> String? { i += 1; return i < args.count ? args[i] : nil }
        switch a {
        case "--once", "--json", "--diag":
            modes.insert(a)
        case "--band":
            guard let v = value(), let b = bandNames[v] else { die("--band needs 2.4|5|6|all") }
            bandFlag = b
        case "--sort":
            guard let v = value(), let k = sortNames[v] else {
                die("--sort needs power|snr|channel|name|band|width|security|load")
            }
            sortFlag = k
        case "--exclude-ssid":
            guard let v = value(), !v.isEmpty else { die("--exclude-ssid needs a network name") }
            app.excludeSSIDs.formUnion(v.split(separator: ",").map(String.init))
        case "--log":
            guard let v = value(), !v.isEmpty else { die("--log needs a file path") }
            app.logPath = (v as NSString).expandingTildeInPath
        case "--report":
            guard let v = value(), !v.isEmpty else { die("--report needs a file path") }
            reportPath = (v as NSString).expandingTildeInPath
        default:
            die("unknown option '\(a)'")
        }
        i += 1
    }

    // Colour is automatic: on for an interactive terminal, off when piped/redirected
    // (or when NO_COLOR is set). No flag needed.
    Ansi.enabled = ProcessInfo.processInfo.environment["NO_COLOR"] == nil && isatty(STDOUT_FILENO) != 0

    // Report mode reads only the log file — no scan, no daemon, no TTY needed.
    if let path = reportPath { runReport(path: path, app: app); return }

    sweepStaleTempFiles()

    // Restore last-used view settings, then let explicit flags override them.
    loadPrefs(into: app)
    if let b = bandFlag { app.bandFilter = b }
    if let k = sortFlag { app.sortKey = k; app.ascending = false }

    // If launched without a terminal to draw to (Finder/Spotlight/Dock), reopen in
    // Terminal. One-shot/pipe modes are exempt — they run headless.
    let interactive = modes.isEmpty
    if interactive && isatty(STDOUT_FILENO) == 0 {
        relaunchInTerminal()
        return
    }

    // Diagnostics and one-shot modes must run even with the radio off (that's
    // exactly when you reach for --diag), so the power check gates only the TUI.
    if modes.contains("--diag") { runDiag(app: app); return }
    if modes.contains("--json") { runOnce(app: app, json: true); return }
    if modes.contains("--once") { runOnce(app: app, json: false); return }

    if !app.scanner.powerOn {
        FileHandle.standardError.write(Data("Wi-Fi is powered off (interface \(app.scanner.interfaceName)). Turn it on and retry.\n".utf8))
        exit(1)
    }
    runInteractive(app: app)
}

main()
