// wifiscan core unit tests — dependency-free so they run under Command Line Tools
// alone (no XCTest/Xcode required). Build & run with `make test`, or directly:
//
//   swiftc -parse-as-library Sources/wifiscan/Core.swift Tests/CoreTests.swift \
//       -o /tmp/wifiscan-tests && /tmp/wifiscan-tests
//
// Exit code is non-zero if any check fails.

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

@main enum CoreTests {
    static func main() {
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

        // coveredChannels (bonding)
        eq(ChannelPlan.coveredChannels(band: .ghz5, control: 36, widthMHz: 20), [36], "5G 20MHz")
        eq(ChannelPlan.coveredChannels(band: .ghz5, control: 36, widthMHz: 40), [36, 40], "5G 40MHz @36")
        eq(ChannelPlan.coveredChannels(band: .ghz5, control: 44, widthMHz: 40), [44, 48], "5G 40MHz @44")
        eq(ChannelPlan.coveredChannels(band: .ghz5, control: 36, widthMHz: 80), [36, 40, 44, 48], "5G 80MHz @36")
        eq(ChannelPlan.coveredChannels(band: .ghz5, control: 149, widthMHz: 80), [149, 153, 157, 161], "5G 80MHz @149")
        eq(ChannelPlan.coveredChannels(band: .ghz5, control: 36, widthMHz: 160),
           [36, 40, 44, 48, 52, 56, 60, 64], "5G 160MHz @36")
        eq(ChannelPlan.coveredChannels(band: .ghz5, control: 165, widthMHz: 80), [165], "5G 80MHz @165 (no group → control)")
        eq(ChannelPlan.coveredChannels(band: .ghz6, control: 1, widthMHz: 40), [1, 5], "6G 40MHz @1")
        eq(ChannelPlan.coveredChannels(band: .ghz6, control: 1, widthMHz: 80), [1, 5, 9, 13], "6G 80MHz @1")
        eq(ChannelPlan.coveredChannels(band: .ghz6, control: 9, widthMHz: 40), [9, 13], "6G 40MHz @9")
        eq(ChannelPlan.coveredChannels(band: .ghz6, control: 2, widthMHz: 80), [2], "6G ch2 never bonded")
        eq(ChannelPlan.coveredChannels(band: .ghz6, control: 2, widthMHz: 20), [2], "6G ch2 20MHz")

        // freqSpan
        let s20 = mk("x", -50, 36, .ghz5, 20).freqSpan
        ok(s20.lo == 5170 && s20.hi == 5190, "freqSpan 5G ch36 20MHz = (5170,5190)")
        let s80 = mk("x", -50, 36, .ghz5, 80).freqSpan
        ok(s80.lo == 5170 && s80.hi == 5250, "freqSpan 5G ch36 80MHz = (5170,5250)")
        let s24 = mk("x", -50, 6, .ghz24, 20).freqSpan
        ok(s24.lo == 2427 && s24.hi == 2447, "freqSpan 2.4 ch6 20MHz = (2427,2447)")

        // congestion loads / recommend
        let busy = [mk("a", -50, 36, .ghz5, 20), mk("b", -52, 36, .ghz5, 20)]
        let l = Analysis.loads(busy, band: .ghz5, candidates: [36, 40])
        eq(l[0].apCount, 2, "two APs overlap ch36")
        eq(l[1].apCount, 0, "adjacent ch40 (non-overlapping 20MHz) has no overlap")
        let rec = Analysis.recommend(busy, band: .ghz5, candidates: ChannelPlan.cand5NonDFS)
        ok(rec.first!.weighted == 0 && rec.first!.apCount == 0, "recommend picks a clean (zero-energy) channel")
        ok(rec.first!.channel != 36, "recommend does not pick the congested channel")
        eq(rec.first!.channel, 40, "recommend tie-breaks to lowest clean channel")

        // sorting
        let three = [mk("bbb", -50, 1, .ghz24), mk("aaa", -40, 6, .ghz24), mk("ccc", -60, 11, .ghz24)]
        eq(sortNets(three, by: .power, ascending: false).first!.ssid, "aaa", "power desc → strongest first")
        eq(sortNets(three, by: .power, ascending: true).first!.ssid, "ccc", "power asc → weakest first")
        eq(sortNets(three, by: .name, ascending: false).first!.ssid, "aaa", "name asc")
        eq(sortNets(three, by: .channel, ascending: false).first!.channel, 1, "channel asc")

        // value maps
        eq(widthCodeToMHz(1), 20, "width 1→20")
        eq(widthCodeToMHz(4), 160, "width 4→160")
        eq(widthCodeToMHz(9), 0, "width unknown→0")
        eq(signalColorCode(-40), 46, "rssi -40 bright green")
        eq(signalColorCode(-50), 46, "rssi -50 boundary")
        eq(signalColorCode(-55), 82, "rssi -55 green")
        eq(signalColorCode(-65), 226, "rssi -65 yellow")
        eq(signalColorCode(-70), 208, "rssi -70 orange")
        eq(signalColorCode(-85), 196, "rssi -85 red")
        ok(ChannelPlan.isDFS(52) && ChannelPlan.isDFS(100), "DFS channels")
        ok(!ChannelPlan.isDFS(36) && !ChannelPlan.isDFS(165), "non-DFS channels")

        // truecolor gradients (tuples use built-in `==`, not generic eq)
        ok(signalRGB(-30).g > signalRGB(-90).g, "strong signal greener than weak")
        ok(signalRGB(-90) == (220, 60, 55), "weak clamps to red stop")
        ok(signalRGB(-30) == (60, 220, 95), "strong clamps to bright-green stop")
        ok(congestionRGB(0) == (70, 200, 90), "quiet → green")
        ok(congestionRGB(1) == (220, 60, 55), "busiest → red")
        eq(congestionRGB(2).r, congestionRGB(1).r, "congestion clamps above 1")
        ok(lerpRGB(0.5, [(0.0, (0, 0, 0)), (1.0, (100, 200, 40))]) == (50, 100, 20), "lerpRGB midpoint")

        // sub-cell bars (⅛-block)
        eq(subCellBar(0, width: 10), "", "zero fraction → empty")
        eq(subCellBar(1.0, width: 6), "██████", "full fraction → width full blocks")
        eq(displayWidth(subCellBar(1.0, width: 6)), 6, "full bar spans exactly width cells")
        eq(subCellBar(0.5, width: 4), "██", "half of 4 → 2 full blocks")
        eq(subCellBar(0.01, width: 10), "▏", "tiny positive → 1/8 sliver")
        eq(subCellBar(0.3125, width: 4), "█▎", "1.25 cells → one full + 2/8 partial")
        ok(displayWidth(subCellBar(0.77, width: 10)) <= 10, "partial bar never exceeds width")

        // sparklines
        eq(sparkline([]), "", "empty samples → empty")
        eq(sparkline([-90]), "▁", "floor sample → lowest glyph")
        eq(sparkline([-30]), "█", "ceiling sample → highest glyph")
        eq(displayWidth(sparkline([-40, -55, -70, -85])), 4, "one cell per sample")
        ok(sparkline([-30]).first! != sparkline([-90]).first!, "strong vs weak differ")

        // band tints distinct per band, with a 256 fallback
        ok(bandRGB(.ghz24) != bandRGB(.ghz5) && bandRGB(.ghz5) != bandRGB(.ghz6), "band tints distinct")
        ok(bandColorCode(.ghz24) != bandColorCode(.ghz6), "band 256 fallback distinct")

        // netKey identity
        eq(netKey(mk("Home", -50, 36, .ghz5)), "Home|36|2", "netKey = ssid|chan|band")
        ok(netKey(mk("Home", -50, 36, .ghz5)) != netKey(mk("Home", -50, 36, .ghz24)),
           "same name, different band → different key")

        // display width / padding
        eq(displayWidth("abc"), 3, "ascii width")
        eq(displayWidth("你好"), 4, "CJK width = 2 cells each")
        eq(displayWidth("a你"), 3, "mixed width")
        eq(padTo("ab", 4), "ab  ", "padTo pads right")
        eq(padTo("hello", 3), "hel", "padTo truncates")
        eq(displayWidth(padTo("你", 3)), 3, "padTo wide char fills to width")
        eq(displayWidth(padTo("你好", 3)), 3, "padTo truncates wide without overflow")
        eq(padLeft("ab", 4), "  ab", "padLeft pads left")
        eq(displayWidth(padLeft("你", 3)), 3, "padLeft wide char fills to width")

        print("\(checks - failures)/\(checks) checks passed")
        exit(failures == 0 ? 0 : 1)
    }
}
