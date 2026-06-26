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
            let chans = ChannelPlan.coveredChannels(band: band, control: channel, widthMHz: w)
            guard let first = chans.first, let last = chans.last else {
                let fc = Band.centerFreq(band, channel)
                return (fc - Double(w) / 2.0, fc + Double(w) / 2.0)
            }
            let lo = Band.centerFreq(band, first) - 10.0
            let hi = Band.centerFreq(band, last) + 10.0
            return (lo, hi)
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
            let groupSize = widthMHz / 20          // # of 20 MHz slots bonded
            guard groupSize > 0 else { return [control] }
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
    /// Score every candidate control channel by the energy that overlaps it.
    static func loads(_ nets: [BSS], band: Band, candidates: [Int]) -> [ChannelLoad] {
        let inBand = nets.filter { $0.band == band }
        return candidates.map { cand in
            let span = (Band.centerFreq(band, cand) - 10.0, Band.centerFreq(band, cand) + 10.0)
            var load = ChannelLoad(channel: cand)
            for ap in inBand {
                let s = ap.freqSpan
                if s.lo < span.1 && s.hi > span.0 {     // intervals overlap
                    load.apCount += 1
                    load.weighted += ap.linearPower
                    load.strongest = max(load.strongest, ap.rssi)
                }
            }
            return load
        }
    }

    /// Cleanest candidates first (least overlapping energy, then fewest APs).
    static func recommend(_ nets: [BSS], band: Band, candidates: [Int]) -> [ChannelLoad] {
        loads(nets, band: band, candidates: candidates)
            .sorted { a, b in
                if a.weighted != b.weighted { return a.weighted < b.weighted }
                if a.apCount != b.apCount { return a.apCount < b.apCount }
                return a.channel < b.channel        // stable, deterministic tie-break
            }
    }
}

// MARK: - Sorting

enum SortKey {
    case power, snr, channel, name, band, width, security
    var label: String {
        switch self {
        case .power: return "Power"
        case .snr: return "SNR"
        case .channel: return "Channel"
        case .name: return "Name"
        case .band: return "Band"
        case .width: return "Width"
        case .security: return "Security"
        }
    }
}

func sortNets(_ nets: [BSS], by key: SortKey, ascending: Bool) -> [BSS] {
    let sorted = nets.sorted { a, b in
        switch key {
        case .power:    return a.rssi != b.rssi ? a.rssi > b.rssi : a.ssid < b.ssid
        case .snr:      return (a.snr ?? -999) != (b.snr ?? -999) ? (a.snr ?? -999) > (b.snr ?? -999) : a.rssi > b.rssi
        case .channel:  return a.channel != b.channel ? a.channel < b.channel : a.rssi > b.rssi
        case .name:     return a.ssid.lowercased() != b.ssid.lowercased() ? a.ssid.lowercased() < b.ssid.lowercased() : a.rssi > b.rssi
        case .band:     return a.band.rawValue != b.band.rawValue ? a.band.rawValue < b.band.rawValue : a.rssi > b.rssi
        case .width:    return a.widthMHz != b.widthMHz ? a.widthMHz > b.widthMHz : a.rssi > b.rssi
        case .security: return a.security != b.security ? a.security < b.security : a.rssi > b.rssi
        }
    }
    return ascending ? sorted.reversed() : sorted
}

// MARK: - CoreWLAN value mappings (kept here so they're unit-testable without the framework)

/// Map a CWChannelWidth raw value to MHz (0 == unknown).
func widthCodeToMHz(_ raw: Int) -> Int {
    switch raw {
    case 1: return 20
    case 2: return 40
    case 3: return 80
    case 4: return 160
    default: return 0
    }
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
            let t = hi.at == lo.at ? 0 : (x - lo.at) / (hi.at - lo.at)
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
    guard let s = c.unicodeScalars.first else { return 0 }
    let v = s.value
    if v == 0 { return 0 }
    // Combining marks / zero-width.
    if (0x0300...0x036F).contains(v) || (0x200B...0x200F).contains(v) || v == 0xFEFF { return 0 }
    // Wide / fullwidth ranges (CJK, Hangul, fullwidth forms, emoji planes).
    let wide: [ClosedRange<UInt32>] = [
        0x1100...0x115F, 0x2329...0x232A, 0x2E80...0x303E, 0x3041...0x33FF,
        0x3400...0x4DBF, 0x4E00...0x9FFF, 0xA000...0xA4CF, 0xAC00...0xD7A3,
        0xF900...0xFAFF, 0xFE10...0xFE19, 0xFE30...0xFE6F, 0xFF00...0xFF60,
        0xFFE0...0xFFE6, 0x1F300...0x1FAFF, 0x1F900...0x1F9FF, 0x20000...0x3FFFD,
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
