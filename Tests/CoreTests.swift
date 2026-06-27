// wifiscan core unit tests — dependency-free so they run under Command Line Tools
// alone (no XCTest/Xcode required). Build & run with `make test`, measure coverage
// with `make coverage`, or directly:
//
//   swiftc -parse-as-library Sources/wifiscan/Core.swift Tests/CoreTests.swift \
//       -o /tmp/wifiscan-tests && /tmp/wifiscan-tests
//
// Exit code is non-zero if any check fails. These tests are kept at 100% region
// coverage of Core.swift (enforced by `make coverage` / CI); when you add code to
// Core.swift, add a check here.

import Foundation

var checks = 0, failures = 0
func ok(_ cond: Bool, _ msg: String) {
    checks += 1
    if !cond { failures += 1; print("FAIL: \(msg)") }
}
func eq<T: Equatable>(_ a: T, _ b: T, _ msg: String) {
    checks += 1
    if a != b { failures += 1; print("FAIL: \(msg) — got \(a), want \(b)") }
}
func mk(_ ssid: String, _ rssi: Int, _ ch: Int, _ band: Band, _ w: Int = 20,
        noise: Int = 0, sec: String = "WPA2", hidden: Bool = false) -> BSS {
    BSS(ssid: ssid, rssi: rssi, noise: noise, channel: ch, band: band,
        widthMHz: w, security: sec, hidden: hidden)
}
/// SSIDs of a sorted result, as one string, for compact ordering assertions.
func order(_ nets: [BSS]) -> String { nets.map { $0.ssid }.joined() }

@main enum CoreTests {
    static func main() {
        testBSS()
        testBands()
        testChannelPlan()
        testCongestion()
        testSorting()
        testValueMaps()
        testGradients()
        testBars()
        testLayout()
        testSanitize()

        print("\(checks - failures)/\(checks) checks passed")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: BSS model

    static func testBSS() {
        // snr / noiseValid: only meaningful when macOS actually measured noise (<0).
        let measured = mk("x", -50, 36, .ghz5, noise: -90)
        ok(measured.snr == 40, "snr = rssi - noise when noise measured")
        ok(measured.noiseValid, "noiseValid true when noise < 0")
        let unmeasured = mk("x", -50, 36, .ghz5, noise: 0)
        ok(unmeasured.snr == nil, "snr nil when noise not measured (== 0)")
        ok(!unmeasured.noiseValid, "noiseValid false when noise == 0")

        // linearPower = 10^(rssi/10): monotonic in rssi, exact at a round value.
        ok(mk("a", -40, 1, .ghz24).linearPower > mk("b", -50, 1, .ghz24).linearPower,
           "linearPower rises with rssi")
        ok(abs(mk("a", -40, 1, .ghz24).linearPower - 1e-4) < 1e-12, "linearPower = 10^(rssi/10)")

        // freqSpan across bands / widths.
        let s20 = mk("x", -50, 36, .ghz5, 20).freqSpan
        ok(s20.lo == 5170 && s20.hi == 5190, "freqSpan 5G ch36 20MHz = (5170,5190)")
        let s80 = mk("x", -50, 36, .ghz5, 80).freqSpan
        ok(s80.lo == 5170 && s80.hi == 5250, "freqSpan 5G ch36 80MHz = (5170,5250)")
        let s24 = mk("x", -50, 6, .ghz24, 20).freqSpan
        ok(s24.lo == 2427 && s24.hi == 2447, "freqSpan 2.4 ch6 20MHz = (2427,2447)")
        let s24b = mk("x", -50, 6, .ghz24, 40).freqSpan   // 2.4 approximates ±w/2 around control
        ok(s24b.lo == 2417 && s24b.hi == 2457, "freqSpan 2.4 ch6 40MHz approximates ±20")
        let s6 = mk("x", -50, 1, .ghz6, 80).freqSpan       // covers 6G ch [1,5,9,13]
        ok(s6.lo == 5945 && s6.hi == 6025, "freqSpan 6G ch1 80MHz = (5945,6025)")
        let s0 = mk("x", -50, 36, .ghz5, 0).freqSpan        // width 0 (unknown) → treated as 20
        ok(s0.lo == 5170 && s0.hi == 5190, "freqSpan unknown width treated as 20 MHz")
        let su = mk("x", -50, 0, .unknown, 20).freqSpan      // unknown band folds around centerFreq 0
        ok(su.lo == -10 && su.hi == 10, "freqSpan unknown band folds around 0")
    }

    // MARK: Band

    static func testBands() {
        // centerFreq
        eq(Band.centerFreq(.ghz24, 1), 2412, "2.4 ch1")
        eq(Band.centerFreq(.ghz24, 6), 2437, "2.4 ch6")
        eq(Band.centerFreq(.ghz24, 14), 2484, "2.4 ch14 (special)")
        eq(Band.centerFreq(.ghz5, 36), 5180, "5 ch36")
        eq(Band.centerFreq(.ghz5, 149), 5745, "5 ch149")
        eq(Band.centerFreq(.ghz5, 165), 5825, "5 ch165")
        eq(Band.centerFreq(.ghz6, 1), 5955, "6 ch1")
        eq(Band.centerFreq(.ghz6, 2), 5935, "6 ch2 (special low channel)")
        eq(Band.centerFreq(.ghz6, 5), 5975, "6 ch5")
        eq(Band.centerFreq(.unknown, 5), 0, "unknown band centerFreq = 0")

        // labels
        eq(Band.ghz24.label, "2.4", "label 2.4")
        eq(Band.ghz5.label, "5", "label 5")
        eq(Band.ghz6.label, "6", "label 6")
        eq(Band.unknown.label, "?", "label unknown")
        eq(Band.ghz24.longLabel, "2.4 GHz", "longLabel 2.4")
        eq(Band.ghz5.longLabel, "5 GHz", "longLabel 5")
        eq(Band.ghz6.longLabel, "6 GHz", "longLabel 6")
        eq(Band.unknown.longLabel, "?", "longLabel unknown")

        // from(raw)
        eq(Band.from(1), .ghz24, "from 1 → 2.4")
        eq(Band.from(2), .ghz5, "from 2 → 5")
        eq(Band.from(3), .ghz6, "from 3 → 6")
        eq(Band.from(0), .unknown, "from 0 → unknown")
        eq(Band.from(99), .unknown, "from invalid raw → unknown")
    }

    // MARK: ChannelPlan

    static func testChannelPlan() {
        // coveredChannels (bonding)
        eq(ChannelPlan.coveredChannels(band: .ghz5, control: 36, widthMHz: 20), [36], "5G 20MHz")
        eq(ChannelPlan.coveredChannels(band: .ghz5, control: 36, widthMHz: 40), [36, 40], "5G 40MHz @36")
        eq(ChannelPlan.coveredChannels(band: .ghz5, control: 44, widthMHz: 40), [44, 48], "5G 40MHz @44")
        eq(ChannelPlan.coveredChannels(band: .ghz5, control: 36, widthMHz: 80), [36, 40, 44, 48], "5G 80MHz @36")
        eq(ChannelPlan.coveredChannels(band: .ghz5, control: 149, widthMHz: 80), [149, 153, 157, 161], "5G 80MHz @149")
        eq(ChannelPlan.coveredChannels(band: .ghz5, control: 36, widthMHz: 160),
           [36, 40, 44, 48, 52, 56, 60, 64], "5G 160MHz @36")
        eq(ChannelPlan.coveredChannels(band: .ghz5, control: 165, widthMHz: 80), [165], "5G 80MHz @165 (no group → control)")
        eq(ChannelPlan.coveredChannels(band: .ghz5, control: 36, widthMHz: 240), [36], "5G unknown width → control only")
        eq(ChannelPlan.coveredChannels(band: .ghz6, control: 1, widthMHz: 40), [1, 5], "6G 40MHz @1")
        eq(ChannelPlan.coveredChannels(band: .ghz6, control: 1, widthMHz: 80), [1, 5, 9, 13], "6G 80MHz @1")
        eq(ChannelPlan.coveredChannels(band: .ghz6, control: 9, widthMHz: 40), [9, 13], "6G 40MHz @9")
        eq(ChannelPlan.coveredChannels(band: .ghz6, control: 2, widthMHz: 80), [2], "6G ch2 never bonded")
        eq(ChannelPlan.coveredChannels(band: .ghz6, control: 2, widthMHz: 20), [2], "6G ch2 20MHz")
        eq(ChannelPlan.coveredChannels(band: .ghz6, control: 0, widthMHz: 80), [0], "6G control < 1 → control only")
        eq(ChannelPlan.coveredChannels(band: .ghz24, control: 6, widthMHz: 40), [6], "2.4 GHz never bonded → control only")
        eq(ChannelPlan.coveredChannels(band: .unknown, control: 7, widthMHz: 80), [7], "unknown band → control only")

        // DFS classification
        ok(ChannelPlan.isDFS(52) && ChannelPlan.isDFS(100), "DFS channels")
        ok(!ChannelPlan.isDFS(36) && !ChannelPlan.isDFS(165), "non-DFS channels")
    }

    // MARK: Congestion analysis

    static func testCongestion() {
        // loads: overlap counting + energy weighting.
        let busy = [mk("a", -50, 36, .ghz5, 20), mk("b", -52, 36, .ghz5, 20)]
        let l = Analysis.loads(busy, band: .ghz5, candidates: [36, 40])
        eq(l[0].apCount, 2, "two APs overlap ch36")
        eq(l[1].apCount, 0, "adjacent ch40 (non-overlapping 20MHz) has no overlap")
        ok(l[0].strongest == -50, "strongest tracks the loudest overlapping AP")

        // An AP well above the candidate's span is excluded (overlap's lower-edge test).
        let mixed = [mk("low", -50, 36, .ghz5, 20), mk("high", -50, 161, .ghz5, 20)]
        eq(Analysis.loads(mixed, band: .ghz5, candidates: [36])[0].apCount, 1, "far AP excluded from ch36")

        // recommend: cleanest first.
        let rec = Analysis.recommend(busy, band: .ghz5, candidates: ChannelPlan.cand5NonDFS)
        ok(rec.first!.weighted == 0 && rec.first!.apCount == 0, "recommend picks a clean (zero-energy) channel")
        ok(rec.first!.channel != 36, "recommend does not pick the congested channel")
        eq(rec.first!.channel, 40, "recommend tie-breaks to lowest clean channel")

        // cleaner() ordering policy, exercised directly (so all three tie-break tiers
        // are covered — equal-energy/different-AP ties can't arise from integer dBm).
        let energetic = ChannelLoad(channel: 1, apCount: 1, weighted: 0.2, strongest: -50)
        let quiet = ChannelLoad(channel: 1, apCount: 1, weighted: 0.1, strongest: -60)
        ok(Analysis.cleaner(quiet, energetic), "less overlapping energy is cleaner")
        let oneAP = ChannelLoad(channel: 40, apCount: 1, weighted: 0.5, strongest: -50)
        let threeAP = ChannelLoad(channel: 36, apCount: 3, weighted: 0.5, strongest: -50)
        ok(Analysis.cleaner(oneAP, threeAP), "equal energy → fewer APs is cleaner")
        let chHi = ChannelLoad(channel: 44, apCount: 1, weighted: 0.5, strongest: -50)
        let chLo = ChannelLoad(channel: 36, apCount: 1, weighted: 0.5, strongest: -50)
        ok(!Analysis.cleaner(chHi, chLo), "equal energy & APs → lower channel is cleaner")
    }

    // MARK: Sorting

    static func testSorting() {
        // power: desc by rssi, tie-break by ssid asc; asc reverses.
        let pw = [mk("b", -50, 1, .ghz24), mk("a", -40, 6, .ghz24),
                  mk("c", -60, 11, .ghz24), mk("d", -40, 2, .ghz24)]
        eq(order(sortNets(pw, by: .power, ascending: false)), "adbc", "power desc, ties by ssid asc")
        eq(sortNets(pw, by: .power, ascending: true).first!.ssid, "c", "power asc → weakest first")

        // snr: desc, tie-break by rssi, nil (unmeasured) last.
        let sn = [mk("a", -50, 36, .ghz5, noise: -90),  // snr 40
                  mk("b", -40, 36, .ghz5, noise: -80),  // snr 40 (tie → stronger rssi first)
                  mk("c", -50, 36, .ghz5, noise: -60),  // snr 10
                  mk("d", -50, 36, .ghz5, noise: 0)]    // snr nil
        eq(order(sortNets(sn, by: .snr, ascending: false)), "bacd", "snr desc, tie by rssi, nil last")
        // Drive netBefore in both argument orders so every SNR nil-coalescing path runs
        // deterministically (a single sort pass can't guarantee both orders for one pair).
        let measured = mk("m", -50, 36, .ghz5, noise: -90)   // snr 40
        let nilSnr = mk("z", -50, 36, .ghz5, noise: 0)       // snr nil → -999 sentinel
        ok(netBefore(measured, nilSnr, by: .snr), "measured SNR sorts before unmeasured")
        ok(!netBefore(nilSnr, measured, by: .snr), "unmeasured SNR sorts after measured")
        ok(netBefore(mk("a", -40, 36, .ghz5, noise: 0), mk("b", -50, 36, .ghz5, noise: 0), by: .snr),
           "equal (unmeasured) SNR → stronger RSSI first")

        // channel: asc, tie-break by rssi.
        let ch = [mk("a", -50, 11, .ghz24), mk("b", -40, 1, .ghz24), mk("c", -60, 1, .ghz24)]
        eq(order(sortNets(ch, by: .channel, ascending: false)), "bca", "channel asc, tie by rssi")
        eq(sortNets(ch, by: .channel, ascending: true).first!.channel, 11, "channel desc → highest first")

        // name: case-insensitive asc, tie-break by rssi.
        let nm = [mk("Bravo", -50, 1, .ghz24), mk("alpha", -40, 1, .ghz24), mk("ALPHA", -60, 1, .ghz24)]
        eq(order(sortNets(nm, by: .name, ascending: false)), "alphaALPHABravo", "name asc case-insensitive, tie by rssi")

        // band: asc by raw value, tie-break by rssi.
        let bd = [mk("a", -50, 36, .ghz5), mk("b", -40, 1, .ghz24), mk("c", -60, 1, .ghz24)]
        eq(order(sortNets(bd, by: .band, ascending: false)), "bca", "band asc, tie by rssi")

        // width: desc, tie-break by rssi.
        let wd = [mk("a", -50, 36, .ghz5, 80), mk("b", -40, 36, .ghz5, 160), mk("c", -60, 36, .ghz5, 160)]
        eq(order(sortNets(wd, by: .width, ascending: false)), "bca", "width desc, tie by rssi")

        // security: asc by label, tie-break by rssi.
        let se = [mk("a", -50, 1, .ghz24, sec: "WPA3"), mk("b", -40, 1, .ghz24, sec: "Open"),
                  mk("c", -60, 1, .ghz24, sec: "Open")]
        eq(order(sortNets(se, by: .security, ascending: false)), "bca", "security asc, tie by rssi")

        // SortKey labels
        eq(SortKey.power.label, "Power", "sortkey power label")
        eq(SortKey.snr.label, "SNR", "sortkey snr label")
        eq(SortKey.channel.label, "Channel", "sortkey channel label")
        eq(SortKey.name.label, "Name", "sortkey name label")
        eq(SortKey.band.label, "Band", "sortkey band label")
        eq(SortKey.width.label, "Width", "sortkey width label")
        eq(SortKey.security.label, "Security", "sortkey security label")
    }

    // MARK: CoreWLAN value maps

    static func testValueMaps() {
        eq(widthCodeToMHz(1), 20, "width 1→20")
        eq(widthCodeToMHz(2), 40, "width 2→40")
        eq(widthCodeToMHz(3), 80, "width 3→80")
        eq(widthCodeToMHz(4), 160, "width 4→160")
        eq(widthCodeToMHz(9), 0, "width unknown→0")

        eq(signalColorCode(-40), 46, "rssi -40 bright green")
        eq(signalColorCode(-50), 46, "rssi -50 boundary")
        eq(signalColorCode(-55), 82, "rssi -55 green")
        eq(signalColorCode(-65), 226, "rssi -65 yellow")
        eq(signalColorCode(-70), 208, "rssi -70 orange")
        eq(signalColorCode(-85), 196, "rssi -85 red")
    }

    // MARK: Truecolor gradients / band tints

    static func testGradients() {
        // lerpRGB (tuples use built-in `==`, not generic eq)
        ok(lerpRGB(0.5, [(0.0, (0, 0, 0)), (1.0, (100, 200, 40))]) == (50, 100, 20), "lerpRGB midpoint")
        ok(lerpRGB(0.5, []) == (255, 255, 255), "lerpRGB empty stops → white")
        ok(lerpRGB(-1.0, [(0.0, (10, 20, 30)), (1.0, (90, 90, 90))]) == (10, 20, 30), "lerpRGB below first → first stop")
        ok(lerpRGB(2.0, [(0.0, (10, 20, 30)), (1.0, (90, 90, 90))]) == (90, 90, 90), "lerpRGB above last → last stop")

        ok(signalRGB(-30).g > signalRGB(-90).g, "strong signal greener than weak")
        ok(signalRGB(-90) == (220, 60, 55), "weak clamps to red stop")
        ok(signalRGB(-30) == (60, 220, 95), "strong clamps to bright-green stop")
        ok(congestionRGB(0) == (70, 200, 90), "quiet → green")
        ok(congestionRGB(1) == (220, 60, 55), "busiest → red")
        eq(congestionRGB(2).r, congestionRGB(1).r, "congestion clamps above 1")

        // band tints distinct per band, plus the unknown fallback, with a 256 fallback.
        ok(bandRGB(.ghz24) != bandRGB(.ghz5) && bandRGB(.ghz5) != bandRGB(.ghz6), "band tints distinct")
        ok(bandRGB(.unknown) == (170, 170, 170), "unknown band tint = grey")
        eq(bandColorCode(.ghz24), 222, "band 256 fallback 2.4")
        eq(bandColorCode(.ghz5), 75, "band 256 fallback 5")
        eq(bandColorCode(.ghz6), 141, "band 256 fallback 6")
        eq(bandColorCode(.unknown), 245, "band 256 fallback unknown")
    }

    // MARK: Sub-cell bars / sparklines

    static func testBars() {
        // sub-cell bars (⅛-block)
        eq(subCellBar(0, width: 10), "", "zero fraction → empty")
        eq(subCellBar(0.5, width: 0), "", "zero width → empty")
        eq(subCellBar(1.0, width: 6), "██████", "full fraction → width full blocks")
        eq(displayWidth(subCellBar(1.0, width: 6)), 6, "full bar spans exactly width cells")
        eq(subCellBar(0.5, width: 4), "██", "half of 4 → 2 full blocks")
        eq(subCellBar(0.01, width: 10), "▏", "tiny positive → 1/8 sliver")
        eq(subCellBar(0.3125, width: 4), "█▎", "1.25 cells → one full + 2/8 partial")
        ok(displayWidth(subCellBar(0.77, width: 10)) <= 10, "partial bar never exceeds width")

        // sparklines
        eq(sparkline([]), "", "empty samples → empty")
        eq(sparkline([-50], lo: -30, hi: -90), "", "degenerate scale (hi<=lo) → empty")
        eq(sparkline([-90]), "▁", "floor sample → lowest glyph")
        eq(sparkline([-30]), "█", "ceiling sample → highest glyph")
        eq(displayWidth(sparkline([-40, -55, -70, -85])), 4, "one cell per sample")
        ok(sparkline([-30]).first! != sparkline([-90]).first!, "strong vs weak differ")

        // netKey identity
        eq(netKey(mk("Home", -50, 36, .ghz5)), "Home|36|2", "netKey = ssid|chan|band")
        ok(netKey(mk("Home", -50, 36, .ghz5)) != netKey(mk("Home", -50, 36, .ghz24)),
           "same name, different band → different key")
    }

    // MARK: Display-width-aware text layout

    static func testLayout() {
        // charDisplayWidth: zero-width classes, normal, and wide.
        eq(charDisplayWidth("\u{0}"), 0, "null scalar → 0 width")
        eq(charDisplayWidth("\u{0301}"), 0, "combining acute → 0 width")     // 0x0300…0x036F
        eq(charDisplayWidth("\u{200B}"), 0, "zero-width space → 0 width")     // 0x200B…0x200F
        eq(charDisplayWidth("\u{FEFF}"), 0, "BOM / zero-width no-break → 0")
        eq(charDisplayWidth("A"), 1, "ascii → 1 width")
        eq(charDisplayWidth("你"), 2, "CJK → 2 width")
        eq(charDisplayWidth("😀"), 2, "emoji → 2 width")

        eq(displayWidth("abc"), 3, "ascii width")
        eq(displayWidth("你好"), 4, "CJK width = 2 cells each")
        eq(displayWidth("a你"), 3, "mixed width")

        eq(padTo("ab", 4), "ab  ", "padTo pads right")
        eq(padTo("hello", 3), "hel", "padTo truncates")
        eq(displayWidth(padTo("你", 3)), 3, "padTo wide char fills to width")
        eq(displayWidth(padTo("你好", 3)), 3, "padTo truncates wide without overflow")

        eq(padLeft("ab", 4), "  ab", "padLeft pads left")
        eq(padLeft("hello", 3), "hel", "padLeft truncates over-long to width")
        eq(displayWidth(padLeft("你", 3)), 3, "padLeft wide char fills to width")
        eq(displayWidth(padLeft("你好", 3)), 3, "padLeft truncates wide without overflow")
    }

    // MARK: Terminal-safe SSID display

    static func testSanitize() {
        eq(sanitizeSSID("home-wifi"), "home-wifi", "printable name unchanged")
        eq(sanitizeSSID(""), "", "empty name stays empty")
        eq(sanitizeSSID("café 你好 😀"), "café 你好 😀", "Unicode printable names pass through")
        eq(sanitizeSSID("‹hidden›"), "‹hidden›", "the hidden marker is left intact")
        // An ANSI-escape attack: the ESC (C0) is replaced; the now-inert "[31m" stays
        // as plain text and can no longer recolour the terminal.
        eq(sanitizeSSID("evil\u{1B}[31mAP"), "evil·[31mAP", "ESC neutralised to placeholder")
        eq(sanitizeSSID("a\tb\nc\rd"), "a·b·c·d", "TAB / LF / CR neutralised")    // C0 < 0x20
        eq(sanitizeSSID("x\u{7F}y"), "x·y", "DEL (0x7F) neutralised")
        eq(sanitizeSSID("x\u{85}y"), "x·y", "C1 control (NEL, 0x85) neutralised")  // 0x80…0x9F
        // Width preservation keeps table columns aligned regardless of escapes.
        eq(displayWidth(sanitizeSSID("a\u{1B}\u{7F}b")), 4, "sanitised name keeps display width")
    }
}
