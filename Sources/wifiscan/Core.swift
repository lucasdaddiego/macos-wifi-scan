// wifiscan — pure, framework-free core (channel plan, congestion model, sorting,
// text layout). Deliberately free of CoreWLAN/CoreLocation so it compiles and
// unit-tests standalone with plain `swiftc` (see Tests/CoreTests.swift / `make
// test`). main.swift holds everything that touches the system frameworks, the
// TUI, the out-of-process scan helper, and the entrypoint.

import Foundation

// MARK: - Model

struct BSS {
    var ssid: String
    var rssi: Int          // dBm
    var noise: Int         // dBm (0 == not measured by macOS for this BSS)
    var channel: Int
    var band: Band
    var widthMHz: Int      // 20/40/80/160, 0 == unknown
    var security: String
    var hidden: Bool
    /// QBSS channel utilisation (0…1) from the AP's beacon, when it broadcasts one.
    var utilization: Double? = nil

    var snr: Int? { noise < 0 ? rssi - noise : nil }      // only when noise is real
    var noiseValid: Bool { noise < 0 }

    /// Linear power (relative mW) for energy-weighted congestion scoring.
    var linearPower: Double { pow(10.0, Double(rssi) / 10.0) }

    /// Inclusive [low, high] frequency span (MHz) actually occupied, accounting
    /// for channel bonding.
    var freqSpan: (lo: Double, hi: Double) {
        let w = widthMHz > 0 ? widthMHz : 20
        switch band {
        case .ghz24:
            // 2.4 GHz bonding is rare/discouraged; approximate around control freq.
            let fc = Band.centerFreq(.ghz24, channel)
            return (fc - Double(w) / 2.0, fc + Double(w) / 2.0)
        case .ghz5, .ghz6, .unknown:
            // coveredChannels always yields at least the control channel, so fold the
            // covered 20 MHz slots into the frequency span they occupy; ±10 MHz widens
            // each edge slot to its full 20 MHz. (min/max, not first/last, so the result
            // is independent of the table's channel ordering.)
            let freqs = ChannelPlan.coveredChannels(band: band, control: channel, widthMHz: w)
                .map { Band.centerFreq(band, $0) }
            return (freqs.min()! - 10.0, freqs.max()! + 10.0)
        }
    }
}

enum Band: Int {
    case unknown = 0, ghz24 = 1, ghz5 = 2, ghz6 = 3

    var label: String {
        switch self {
        case .ghz24: return "2.4"
        case .ghz5:  return "5"
        case .ghz6:  return "6"
        case .unknown: return "?"
        }
    }
    var longLabel: String {
        switch self {
        case .ghz24: return "2.4 GHz"
        case .ghz5:  return "5 GHz"
        case .ghz6:  return "6 GHz"
        case .unknown: return "?"
        }
    }

    static func from(_ raw: Int) -> Band { Band(rawValue: raw) ?? .unknown }

    /// Center frequency (MHz) of a 20 MHz control channel.
    static func centerFreq(_ band: Band, _ chan: Int) -> Double {
        switch band {
        case .ghz24:
            if chan == 14 { return 2484 }
            return 2412 + Double(chan - 1) * 5
        case .ghz5:
            return 5000 + Double(chan) * 5
        case .ghz6:
            if chan == 2 { return 5935 }
            return 5950 + Double(chan) * 5
        case .unknown:
            return 0
        }
    }
}

// MARK: - Channel plan (bonding → covered 20 MHz control channels)

enum ChannelPlan {
    // Standard 5 GHz bonded groups (control channels). Irregular due to UNII gaps.
    static let g5_40: [[Int]] = [
        [36,40],[44,48],[52,56],[60,64],
        [100,104],[108,112],[116,120],[124,128],
        [132,136],[140,144],[149,153],[157,161]
    ]
    static let g5_80: [[Int]] = [
        [36,40,44,48],[52,56,60,64],
        [100,104,108,112],[116,120,124,128],
        [132,136,140,144],[149,153,157,161]
    ]
    static let g5_160: [[Int]] = [
        [36,40,44,48,52,56,60,64],
        [100,104,108,112,116,120,124,128],
        [149,153,157,161,165,169,173,177]
    ]

    /// 20 MHz control channels covered by a (control, width) transmission.
    static func coveredChannels(band: Band, control: Int, widthMHz: Int) -> [Int] {
        if widthMHz <= 20 { return [control] }
        switch band {
        case .ghz5:
            let table: [[Int]]
            switch widthMHz {
            case 40:  table = g5_40
            case 80:  table = g5_80
            case 160: table = g5_160
            default:  table = []
            }
            if let g = table.first(where: { $0.contains(control) }) { return g }
            return [control]
        case .ghz6:
            // 6 GHz is a regular grid: 20 MHz control channels are 1,5,9,...,233.
            // Channel 2 (5935 MHz) is a special low-power 20-MHz-only channel that
            // sits off the (ch-1)/4 grid, so never bond it.
            guard control >= 1, control != 2 else { return [control] }
            let slot = (control - 1) / 4          // 0-based 20 MHz slot
            let groupSize = widthMHz / 20          // # of 20 MHz slots bonded (≥1: widthMHz > 20 above)
            let start = (slot / groupSize) * groupSize
            return (0..<groupSize).map { 1 + (start + $0) * 4 }
        case .ghz24:
            return [control]
        case .unknown:
            return [control]
        }
    }

    // Candidate control channels worth recommending per band.
    static let cand24 = [1, 6, 11]
    // 165 (5825 MHz, UNII-3) is a legal non-DFS 20 MHz channel in essentially
    // every regulatory domain and a very common "spare" — include it.
    static let cand5NonDFS = [36, 40, 44, 48, 149, 153, 157, 161, 165]
    static let cand5DFS = [52,56,60,64,100,104,108,112,116,120,124,128,132,136,140,144]
    static let cand6PSC = [5, 21, 37, 53, 69, 85, 101, 117, 133, 149, 165, 181, 197, 213, 229]

    /// True for 5 GHz channels that require DFS (radar avoidance).
    static func isDFS(_ chan: Int) -> Bool { cand5DFS.contains(chan) }
}

// MARK: - Congestion analysis

struct ChannelLoad {
    let channel: Int
    var apCount: Int = 0
    var weighted: Double = 0      // sum of linear power overlapping this channel
    var strongest: Int = -127     // strongest RSSI overlapping this channel
}

enum Analysis {
    /// Score every candidate 20 MHz control channel by the energy that lands in it.
    /// Each AP's power is spread evenly over its occupied span (PSD model), so only
    /// the overlapping fraction counts — an 80 MHz neighbour costs a 20 MHz slot a
    /// quarter of its energy, and a half-overlapping 2.4 GHz AP costs half. When the
    /// AP broadcasts QBSS airtime, mostly-idle APs are discounted (floored at 10%:
    /// an idle AP still beacons and can wake up any time). `excluding` drops your own
    /// SSIDs — moving YOUR AP moves its energy with it, so it must not repel the
    /// recommendation away from its current channel.
    static func loads(_ nets: [BSS], band: Band, candidates: [Int],
                      excluding: Set<String> = []) -> [ChannelLoad] {
        let inBand = nets.filter { $0.band == band && !excluding.contains($0.ssid) }
        return candidates.map { cand in
            let fc = Band.centerFreq(band, cand)
            let span = (lo: fc - 10.0, hi: fc + 10.0)
            var load = ChannelLoad(channel: cand)
            for ap in inBand {
                let s = ap.freqSpan
                let overlap = min(s.hi, span.hi) - max(s.lo, span.lo)
                guard overlap > 0 else { continue }
                let widthFrac = overlap / (s.hi - s.lo)   // slice of the AP's PSD in this slot
                let airtime = ap.utilization.map { max(0.1, $0) } ?? 1.0
                load.apCount += 1
                load.weighted += ap.linearPower * widthFrac * airtime
                load.strongest = max(load.strongest, ap.rssi)
            }
            return load
        }
    }

    /// Order two channel loads cleanest-first: least overlapping energy, then fewest
    /// APs, then lowest channel (a deterministic tie-break). Extracted from `recommend`
    /// so the ordering policy is unit-testable on its own.
    static func cleaner(_ a: ChannelLoad, _ b: ChannelLoad) -> Bool {
        if a.weighted != b.weighted { return a.weighted < b.weighted }
        if a.apCount != b.apCount { return a.apCount < b.apCount }
        return a.channel < b.channel
    }

    /// Cleanest candidates first (least overlapping energy, then fewest APs).
    static func recommend(_ nets: [BSS], band: Band, candidates: [Int],
                          excluding: Set<String> = []) -> [ChannelLoad] {
        loads(nets, band: band, candidates: candidates, excluding: excluding).sorted(by: cleaner)
    }
}

/// Tag for how much busier a candidate is than the cleanest one (`best`), both
/// ChannelLoad.weighted energy sums:
///  - nil when the candidate is clean, or within rounding of best (nothing to say)
///  - "+N dB" above a non-silent best (+3dB ≈ double the interfering energy)
///  - absolute "N dBm" when best is silent (a relative margin would be infinite)
func loadMarginLabel(_ w: Double, best: Double) -> String? {
    guard w > 0 else { return nil }
    if best > 0 {
        let db = max(0, Int((10 * log10(w / best)).rounded()))
        return db == 0 ? nil : "+\(db)dB"
    }
    return "\(Int((10 * log10(w)).rounded()))dBm"
}

// MARK: - Survey log (channel quality over time; --log / --report)

/// One network as logged to a survey JSONL file — just the fields scoring needs.
struct SurveyNet: Codable {
    let ssid: String
    let rssi: Int
    let channel: Int
    let band: Int
    let widthMHz: Int
    let utilization: Double?

    init(_ b: BSS) {
        ssid = b.ssid; rssi = b.rssi; channel = b.channel
        band = b.band.rawValue; widthMHz = b.widthMHz; utilization = b.utilization
    }
    /// Back to a BSS for scoring (fields not logged get inert defaults).
    var bss: BSS {
        BSS(ssid: ssid, rssi: rssi, noise: 0, channel: channel, band: Band.from(band),
            widthMHz: widthMHz, security: "", hidden: false, utilization: utilization)
    }
}

/// One logged scan: epoch seconds + what was in the air.
struct SurveyScan: Codable {
    let ts: Double
    let nets: [SurveyNet]
}

enum Survey {
    /// Average load per candidate over several scans — each scan scored independently
    /// then averaged, so the result is per-scan energy, comparable between hours with
    /// different scan counts. apCount/strongest report the peak seen, not the mean.
    static func averageLoads(_ scans: [[BSS]], band: Band, candidates: [Int],
                             excluding: Set<String> = []) -> [ChannelLoad] {
        var acc = candidates.map { ChannelLoad(channel: $0) }
        guard !scans.isEmpty else { return acc }
        for scan in scans {
            let loads = Analysis.loads(scan, band: band, candidates: candidates, excluding: excluding)
            for i in acc.indices {
                acc[i].weighted += loads[i].weighted
                acc[i].apCount = max(acc[i].apCount, loads[i].apCount)
                acc[i].strongest = max(acc[i].strongest, loads[i].strongest)
            }
        }
        for i in acc.indices { acc[i].weighted /= Double(scans.count) }
        return acc
    }

    /// Group logged scans by hour of day. `hourOf` maps epoch seconds → 0…23 and is
    /// injected so callers pick the calendar/timezone (and tests stay deterministic).
    static func byHour(_ scans: [SurveyScan], hourOf: (Double) -> Int) -> [Int: [[BSS]]] {
        var out: [Int: [[BSS]]] = [:]
        for s in scans { out[hourOf(s.ts), default: []].append(s.nets.map { $0.bss }) }
        return out
    }

    /// The all-day pick: the channel whose WORST hour is cleanest (minimax). A channel
    /// that's pristine at 4am but slammed at 9pm loses to one that's merely OK all day.
    static func allDayPick(_ hourlyLoads: [[ChannelLoad]]) -> ChannelLoad? {
        var worst: [Int: ChannelLoad] = [:]
        for loads in hourlyLoads {
            for l in loads {
                if let w = worst[l.channel] {
                    if l.weighted > w.weighted { worst[l.channel] = l }
                } else {
                    worst[l.channel] = l
                }
            }
        }
        return worst.values.min(by: Analysis.cleaner)
    }
}

// MARK: - Sorting

enum SortKey {
    case power, snr, channel, name, band, width, security, util
    var label: String {
        switch self {
        case .power: return "Power"
        case .snr: return "SNR"
        case .channel: return "Channel"
        case .name: return "Name"
        case .band: return "Band"
        case .width: return "Width"
        case .security: return "Security"
        case .util: return "Load"
        }
    }
}

/// Three-way compare with a direction flag: -1 ⇒ x first, 0 ⇒ tie, +1 ⇒ y first.
/// `desc: true` puts the larger value first (most keys' default direction).
func cmpDir(_ x: Int, _ y: Int, desc: Bool) -> Int {
    if x == y { return 0 }
    return (x < y) != desc ? -1 : 1
}
/// Double overload (QBSS utilization sorting).
func cmpDir(_ x: Double, _ y: Double, desc: Bool) -> Int {
    if x == y { return 0 }
    return (x < y) != desc ? -1 : 1
}
/// Ascending three-way string compare.
func cmpAsc(_ x: String, _ y: String) -> Int {
    if x == y { return 0 }
    return x < y ? -1 : 1
}

/// Primary comparison for `key` in its default (descending-ish) direction; 0 ⇒ the
/// pair ties on this key. Kept separate from the tie-break so an ascending sort can
/// flip ONLY the primary direction — reversing a fully sorted array would flip the
/// tie-breaks too. Unmeasured SNR/utilization sort below any measured value via
/// sentinels (-999 / -1).
func netPrimary(_ a: BSS, _ b: BSS, by key: SortKey) -> Int {
    switch key {
    case .power:    return cmpDir(a.rssi, b.rssi, desc: true)
    case .snr:      return cmpDir(a.snr ?? -999, b.snr ?? -999, desc: true)
    case .channel:  return cmpDir(a.channel, b.channel, desc: false)
    case .name:     return cmpAsc(a.ssid.lowercased(), b.ssid.lowercased())
    case .band:     return cmpDir(a.band.rawValue, b.band.rawValue, desc: false)
    case .width:    return cmpDir(a.widthMHz, b.widthMHz, desc: true)
    case .security: return cmpAsc(a.security, b.security)
    case .util:     return cmpDir(a.utilization ?? -1, b.utilization ?? -1, desc: true)
    }
}

/// Tie-break for primary-equal pairs: strongest RSSI first (name A→Z for power,
/// whose primary IS the RSSI). Direction-independent, so ties read identically
/// whichever way the primary is flipped.
func netTieBreak(_ a: BSS, _ b: BSS, by key: SortKey) -> Bool {
    key == .power ? a.ssid < b.ssid : a.rssi > b.rssi
}

/// Strict "a before b" for `key`'s default direction — primary, then tie-break.
func netBefore(_ a: BSS, _ b: BSS, by key: SortKey) -> Bool {
    let p = netPrimary(a, b, by: key)
    return p != 0 ? p < 0 : netTieBreak(a, b, by: key)
}

func sortNets(_ nets: [BSS], by key: SortKey, ascending: Bool) -> [BSS] {
    nets.sorted { a, b in
        let p = netPrimary(a, b, by: key)
        if p != 0 { return ascending ? p > 0 : p < 0 }
        return netTieBreak(a, b, by: key)
    }
}

// MARK: - CoreWLAN value mappings (kept here so they're unit-testable without the framework)

/// Map a CWChannelWidth raw value to MHz (0 == unknown). 5 is speculative — CoreWLAN
/// has no public 320 MHz case yet, but Wi-Fi 7 APs exist; if Apple adds it, this stops
/// a 320 MHz neighbour from being scored as a 20 MHz one.
func widthCodeToMHz(_ raw: Int) -> Int {
    switch raw {
    case 1: return 20
    case 2: return 40
    case 3: return 80
    case 4: return 160
    case 5: return 320
    default: return 0
    }
}

/// Channel utilisation (0…1) from an AP's raw 802.11 information elements, when it
/// broadcasts a QBSS Load element (id 11: station count u16, channel utilisation u8
/// in 255ths, admission capacity u16). nil when absent or malformed. This is the
/// AP's own measure of how busy its channel actually is — a better congestion signal
/// than RSSI, which only says "loud", not "busy".
func qbssUtilization(_ ies: Data?) -> Double? {
    guard let ies = ies else { return nil }
    let b = [UInt8](ies)
    var i = 0
    while i + 2 <= b.count {                              // need id + length
        let id = Int(b[i]), len = Int(b[i + 1])
        let body = i + 2
        guard body + len <= b.count else { return nil }   // truncated stream
        if id == 11, len >= 3 { return Double(b[body + 2]) / 255.0 }
        i = body + len
    }
    return nil
}

/// Signal → 256-colour palette index. The fallback for terminals without truecolor
/// (see signalRGB for the 24-bit gradient used on Ghostty et al.).
func signalColorCode(_ rssi: Int) -> Int {
    switch rssi {
    case let r where r >= -50: return 46    // bright green
    case let r where r >= -60: return 82    // green
    case let r where r >= -67: return 226   // yellow
    case let r where r >= -75: return 208   // orange
    default: return 196                      // red
    }
}

// MARK: - Truecolor gradients (24-bit; used when the terminal advertises COLORTERM)

typealias RGB = (r: Int, g: Int, b: Int)

/// Linear interpolation across an ascending list of (position, colour) stops.
/// Clamps below the first / above the last stop.
func lerpRGB(_ x: Double, _ stops: [(at: Double, rgb: RGB)]) -> RGB {
    guard let first = stops.first else { return (255, 255, 255) }
    if x <= first.at { return first.rgb }
    for i in 1..<stops.count {
        let lo = stops[i - 1], hi = stops[i]
        if x <= hi.at {
            // We only reach segment i once x has cleared every earlier stop, so
            // lo.at < x ≤ hi.at here ⇒ hi.at > lo.at strictly ⇒ the divide is safe.
            let t = (x - lo.at) / (hi.at - lo.at)
            return (Int((Double(lo.rgb.r) + t * Double(hi.rgb.r - lo.rgb.r)).rounded()),
                    Int((Double(lo.rgb.g) + t * Double(hi.rgb.g - lo.rgb.g)).rounded()),
                    Int((Double(lo.rgb.b) + t * Double(hi.rgb.b - lo.rgb.b)).rounded()))
        }
    }
    return stops.last!.rgb
}

/// Signal → smooth 24-bit colour by dBm: red (weak) → amber → green (strong).
/// The stop positions mirror signalColorCode's buckets so the two paths agree.
func signalRGB(_ rssi: Int) -> RGB {
    lerpRGB(Double(rssi), [
        (-85, (220,  60,  55)),   // red
        (-75, (235, 140,  45)),   // orange
        (-67, (228, 210,  70)),   // yellow
        (-60, (120, 205,  80)),   // green
        (-50, ( 60, 220,  95)),   // bright green
    ])
}

/// Congestion fraction (0 = quiet → 1 = busiest in band) → green → red, matching
/// loadColor's buckets.
func congestionRGB(_ frac: Double) -> RGB {
    lerpRGB(max(0, min(1, frac)), [
        (0.00, ( 70, 200,  90)),   // green — quiet
        (0.45, (228, 210,  70)),   // yellow
        (0.70, (235, 140,  45)),   // orange
        (1.00, (220,  60,  55)),   // red — most congested
    ])
}

// MARK: - Sub-cell bars (Unicode eighth-blocks)

/// Eighth-block partial cells, index 1…7 = 1/8…7/8 of a cell filled from the left.
private let eighthBlocks = ["", "▏", "▎", "▍", "▌", "▋", "▊", "▉"]

/// A horizontal bar with sub-cell precision: the *filled* portion only (no track),
/// `fraction` of `width` full cells, the final partial cell drawn with an eighth-
/// block glyph. Any positive fraction shows at least a 1/8 sliver so faint signals
/// stay visible. Each glyph is one display column wide, so callers can pad/clip by
/// display width as usual.
func subCellBar(_ fraction: Double, width: Int) -> String {
    guard width > 0 else { return "" }
    let f = max(0.0, min(1.0, fraction))
    if f <= 0 { return "" }
    let eighths = max(1, Int((f * Double(width) * 8).rounded()))
    let full = eighths / 8, rem = eighths % 8
    return String(repeating: "█", count: full) + eighthBlocks[rem]
}

/// Vertical-bar sparkline glyphs (▁ lowest … █ highest), one display cell each.
private let sparkGlyphs = ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]

/// Render a run of RSSI samples as a sparkline, each value mapped onto the
/// [lo,hi] dBm scale (the same -90…-30 window the signal bar uses). Empty in →
/// empty out, so callers can pad/clip by display width.
func sparkline(_ samples: [Int], lo: Int = -90, hi: Int = -30) -> String {
    guard !samples.isEmpty, hi > lo else { return "" }
    let span = Double(hi - lo), top = Double(sparkGlyphs.count - 1)
    return samples.map { v in
        let f = max(0.0, min(1.0, (Double(v) - Double(lo)) / span))
        return sparkGlyphs[Int((f * top).rounded())]
    }.joined()
}

/// Stable per-network identity for history tracking. macOS denies third parties the
/// BSSID, so we key on name+channel+band — good enough except for multiple cloaked
/// APs sharing a channel (they alias, which is acceptable for a trend sparkline).
func netKey(_ b: BSS) -> String { "\(b.ssid)|\(b.channel)|\(b.band.rawValue)" }

// MARK: - Per-band accent colours (quick visual grouping of the Band column)

/// 24-bit band tint: 2.4 amber · 5 sky-blue · 6 violet.
func bandRGB(_ b: Band) -> RGB {
    switch b {
    case .ghz24:   return (240, 185,  95)
    case .ghz5:    return ( 95, 190, 240)
    case .ghz6:    return (195, 145, 240)
    case .unknown: return (170, 170, 170)
    }
}

/// 256-palette fallback for bandRGB.
func bandColorCode(_ b: Band) -> Int {
    switch b {
    case .ghz24:   return 222   // amber
    case .ghz5:    return 75    // blue
    case .ghz6:    return 141   // violet
    case .unknown: return 245
    }
}

// MARK: - Display-width-aware text layout
//
// Terminal cells, not grapheme counts: CJK/emoji glyphs occupy two columns but
// count as one Character, so padding by `.count` misaligns the table. These
// helpers measure and truncate by display width instead.

/// Approximate East-Asian display width of a single Character (0/1/2 cells).
func charDisplayWidth(_ c: Character) -> Int {
    // A Character is a grapheme cluster of ≥1 scalar, so .first is never nil; the
    // base (first) scalar decides the cell width.
    let s = c.unicodeScalars.first!
    let v = s.value
    if v == 0 { return 0 }
    // Zero-width: combining marks of ANY script (Mn/Me — accents, Hebrew/Arabic
    // points, variation selectors, …) plus the zero-width format scalars.
    let cat = s.properties.generalCategory
    if cat == .nonspacingMark || cat == .enclosingMark { return 0 }
    if (0x200B...0x200F).contains(v) || v == 0xFEFF { return 0 }
    // Wide / fullwidth ranges (CJK, Hangul, fullwidth forms, emoji planes, flags).
    let wide: [ClosedRange<UInt32>] = [
        0x1100...0x115F, 0x2329...0x232A, 0x2E80...0x303E, 0x3041...0x33FF,
        0x3400...0x4DBF, 0x4E00...0x9FFF, 0xA000...0xA4CF, 0xAC00...0xD7A3,
        0xF900...0xFAFF, 0xFE10...0xFE19, 0xFE30...0xFE6F, 0xFF00...0xFF60,
        0xFFE0...0xFFE6, 0x1F1E6...0x1F1FF, 0x1F300...0x1FAFF, 0x1F900...0x1F9FF,
        0x20000...0x3FFFD,
    ]
    for r in wide where r.contains(v) { return 2 }
    return 1
}

func displayWidth(_ s: String) -> Int { s.reduce(0) { $0 + charDisplayWidth($1) } }

/// Truncate to at most `n` display columns without splitting a grapheme.
func truncateToWidth(_ s: String, _ n: Int) -> String {
    var w = 0, out = ""
    for ch in s {
        let cw = charDisplayWidth(ch)
        if w + cw > n { break }
        out.append(ch); w += cw
    }
    return out
}

/// Left-justify to `n` display columns (pad right with spaces, truncate if longer).
func padTo(_ s: String, _ n: Int) -> String {
    let w = displayWidth(s)
    if w <= n { return s + String(repeating: " ", count: n - w) }
    let t = truncateToWidth(s, n)
    return t + String(repeating: " ", count: max(0, n - displayWidth(t)))
}

/// Right-justify to `n` display columns (pad left with spaces, truncate if longer).
func padLeft(_ s: String, _ n: Int) -> String {
    let w = displayWidth(s)
    if w <= n { return String(repeating: " ", count: n - w) + s }
    let t = truncateToWidth(s, n)
    return String(repeating: " ", count: max(0, n - displayWidth(t))) + t
}

// MARK: - Terminal-safe SSID display
//
// SSIDs arrive from the radio as arbitrary bytes — a hostile access point can name
// itself with ANSI escape sequences, carriage returns, etc. Printing such a name raw
// would let it move the cursor, recolour or clear the terminal, or corrupt the table
// layout. So every SSID is run through sanitizeSSID before it reaches the screen.
// (One-shot JSON output keeps the raw name: JSONEncoder escapes control bytes, so the
// JSON stays valid and inert until a consumer chooses to render it.)

/// Replace C0 control characters (incl. ESC, CR, LF, TAB), DEL, and C1 controls with a
/// visible middle-dot placeholder. Width-preserving — one display cell per replaced
/// scalar — so table columns stay aligned. Printable text (including the `‹hidden›`
/// marker and CJK/emoji names) passes through untouched.
func sanitizeSSID(_ s: String) -> String {
    let placeholder: Unicode.Scalar = "\u{00B7}"      // · — unambiguously one cell wide
    var out = String.UnicodeScalarView()
    for scalar in s.unicodeScalars {
        let v = scalar.value
        if v < 0x20 || v == 0x7F || (0x80...0x9F).contains(v) {
            out.append(placeholder)
        } else {
            out.append(scalar)
        }
    }
    return String(out)
}
