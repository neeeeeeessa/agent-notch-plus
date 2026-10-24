import SwiftUI

/// A provider's brand mark, drawn in the current foreground colour so it works on the black notch.
struct ProviderGlyph: View {
    let id: ProviderID

    var body: some View {
        switch id {
        case .claude: ClaudeSparkle()
        case .codex: OpenAIKnot()
        case .grokBuild: GrokMark()
        }
    }
}

/// Grok mark, normalised from Codenotch `GlyphOutline.grok` and filled even-odd.
private struct GrokMark: View {
    var body: some View {
        GrokOutline()
            .fill(style: FillStyle(eoFill: true))
    }
}

private struct GrokOutline: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for loop in Self.loops {
            guard let first = loop.first else { continue }
            path.move(to: map(first, in: rect))
            for point in loop.dropFirst() {
                path.addLine(to: map(point, in: rect))
            }
            path.closeSubpath()
        }
        return path
    }

    private func map(_ point: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + point.x * rect.width, y: rect.minY + point.y * rect.height)
    }

    /// Copied from Codenotch GlyphOutline.grok (unit box).
    private static let loops: [[CGPoint]] = [
        [
            CGPoint(x: 0.3862, y: 0.6419), CGPoint(x: 0.7187, y: 0.3860), CGPoint(x: 0.7212, y: 0.3842),
            CGPoint(x: 0.7237, y: 0.3827), CGPoint(x: 0.7264, y: 0.3815), CGPoint(x: 0.7291, y: 0.3805),
            CGPoint(x: 0.7318, y: 0.3798), CGPoint(x: 0.7346, y: 0.3793), CGPoint(x: 0.7374, y: 0.3791),
            CGPoint(x: 0.7401, y: 0.3791), CGPoint(x: 0.7429, y: 0.3794), CGPoint(x: 0.7455, y: 0.3799),
            CGPoint(x: 0.7482, y: 0.3806), CGPoint(x: 0.7507, y: 0.3816), CGPoint(x: 0.7531, y: 0.3828),
            CGPoint(x: 0.7554, y: 0.3843), CGPoint(x: 0.7576, y: 0.3860), CGPoint(x: 0.7597, y: 0.3879),
            CGPoint(x: 0.7616, y: 0.3900), CGPoint(x: 0.7632, y: 0.3924), CGPoint(x: 0.7647, y: 0.3950),
            CGPoint(x: 0.7660, y: 0.3978), CGPoint(x: 0.7717, y: 0.4134), CGPoint(x: 0.7765, y: 0.4292),
            CGPoint(x: 0.7804, y: 0.4452), CGPoint(x: 0.7834, y: 0.4615), CGPoint(x: 0.7855, y: 0.4778),
            CGPoint(x: 0.7867, y: 0.4943), CGPoint(x: 0.7870, y: 0.5108), CGPoint(x: 0.7864, y: 0.5273),
            CGPoint(x: 0.7849, y: 0.5437), CGPoint(x: 0.7825, y: 0.5601), CGPoint(x: 0.7791, y: 0.5763),
            CGPoint(x: 0.7749, y: 0.5924), CGPoint(x: 0.7697, y: 0.6082), CGPoint(x: 0.7636, y: 0.6237),
            CGPoint(x: 0.7565, y: 0.6390), CGPoint(x: 0.7486, y: 0.6539), CGPoint(x: 0.7397, y: 0.6683),
            CGPoint(x: 0.7298, y: 0.6824), CGPoint(x: 0.7190, y: 0.6959), CGPoint(x: 0.7073, y: 0.7089),
            CGPoint(x: 0.6949, y: 0.7211), CGPoint(x: 0.6820, y: 0.7324), CGPoint(x: 0.6687, y: 0.7426),
            CGPoint(x: 0.6550, y: 0.7519), CGPoint(x: 0.6410, y: 0.7602), CGPoint(x: 0.6267, y: 0.7675),
            CGPoint(x: 0.6120, y: 0.7739), CGPoint(x: 0.5971, y: 0.7792), CGPoint(x: 0.5820, y: 0.7837),
            CGPoint(x: 0.5667, y: 0.7871), CGPoint(x: 0.5512, y: 0.7896), CGPoint(x: 0.5355, y: 0.7912),
            CGPoint(x: 0.5198, y: 0.7918), CGPoint(x: 0.5040, y: 0.7915), CGPoint(x: 0.4882, y: 0.7902),
            CGPoint(x: 0.4723, y: 0.7880), CGPoint(x: 0.4565, y: 0.7849), CGPoint(x: 0.4407, y: 0.7808),
            CGPoint(x: 0.4250, y: 0.7759), CGPoint(x: 0.4094, y: 0.7700), CGPoint(x: 0.2964, y: 0.8245),
            CGPoint(x: 0.3210, y: 0.8408), CGPoint(x: 0.3460, y: 0.8549), CGPoint(x: 0.3713, y: 0.8669),
            CGPoint(x: 0.3970, y: 0.8769), CGPoint(x: 0.4228, y: 0.8848), CGPoint(x: 0.4487, y: 0.8908),
            CGPoint(x: 0.4747, y: 0.8947), CGPoint(x: 0.5006, y: 0.8968), CGPoint(x: 0.5264, y: 0.8970),
            CGPoint(x: 0.5520, y: 0.8953), CGPoint(x: 0.5773, y: 0.8917), CGPoint(x: 0.6022, y: 0.8864),
            CGPoint(x: 0.6266, y: 0.8793), CGPoint(x: 0.6506, y: 0.8705), CGPoint(x: 0.6739, y: 0.8600),
            CGPoint(x: 0.6965, y: 0.8478), CGPoint(x: 0.7183, y: 0.8340), CGPoint(x: 0.7392, y: 0.8186),
            CGPoint(x: 0.7592, y: 0.8016), CGPoint(x: 0.7782, y: 0.7831), CGPoint(x: 0.7923, y: 0.7676),
            CGPoint(x: 0.8055, y: 0.7516), CGPoint(x: 0.8176, y: 0.7350), CGPoint(x: 0.8287, y: 0.7181),
            CGPoint(x: 0.8389, y: 0.7007), CGPoint(x: 0.8481, y: 0.6830), CGPoint(x: 0.8563, y: 0.6649),
            CGPoint(x: 0.8635, y: 0.6466), CGPoint(x: 0.8698, y: 0.6280), CGPoint(x: 0.8751, y: 0.6092),
            CGPoint(x: 0.8795, y: 0.5902), CGPoint(x: 0.8830, y: 0.5711), CGPoint(x: 0.8855, y: 0.5518),
            CGPoint(x: 0.8871, y: 0.5326), CGPoint(x: 0.8878, y: 0.5133), CGPoint(x: 0.8876, y: 0.4940),
            CGPoint(x: 0.8865, y: 0.4747), CGPoint(x: 0.8844, y: 0.4556), CGPoint(x: 0.8815, y: 0.4366),
            CGPoint(x: 0.8777, y: 0.4177), CGPoint(x: 0.8780, y: 0.4180), CGPoint(x: 0.8725, y: 0.3912),
            CGPoint(x: 0.8684, y: 0.3660), CGPoint(x: 0.8656, y: 0.3422), CGPoint(x: 0.8641, y: 0.3195),
            CGPoint(x: 0.8639, y: 0.2980), CGPoint(x: 0.8649, y: 0.2774), CGPoint(x: 0.8671, y: 0.2576),
            CGPoint(x: 0.8705, y: 0.2385), CGPoint(x: 0.8751, y: 0.2200), CGPoint(x: 0.8807, y: 0.2018),
            CGPoint(x: 0.8875, y: 0.1839), CGPoint(x: 0.8953, y: 0.1661), CGPoint(x: 0.9041, y: 0.1482),
            CGPoint(x: 0.9140, y: 0.1302), CGPoint(x: 0.9248, y: 0.1119), CGPoint(x: 0.9366, y: 0.0931),
            CGPoint(x: 0.9493, y: 0.0738), CGPoint(x: 0.9629, y: 0.0537), CGPoint(x: 0.9773, y: 0.0327),
            CGPoint(x: 0.9926, y: 0.0108), CGPoint(x: 0.9929, y: 0.0102), CGPoint(x: 0.9933, y: 0.0097),
            CGPoint(x: 0.9937, y: 0.0092), CGPoint(x: 0.9941, y: 0.0086), CGPoint(x: 0.9944, y: 0.0081),
            CGPoint(x: 0.9948, y: 0.0076), CGPoint(x: 0.9952, y: 0.0070), CGPoint(x: 0.9955, y: 0.0065),
            CGPoint(x: 0.9959, y: 0.0060), CGPoint(x: 0.9963, y: 0.0054), CGPoint(x: 0.9967, y: 0.0049),
            CGPoint(x: 0.9970, y: 0.0043), CGPoint(x: 0.9974, y: 0.0038), CGPoint(x: 0.9978, y: 0.0033),
            CGPoint(x: 0.9981, y: 0.0027), CGPoint(x: 0.9985, y: 0.0022), CGPoint(x: 0.9989, y: 0.0016),
            CGPoint(x: 0.9993, y: 0.0011), CGPoint(x: 0.9996, y: 0.0005), CGPoint(x: 1.0000, y: 0.0000),
            CGPoint(x: 0.8624, y: 0.1435), CGPoint(x: 0.8624, y: 0.1430), CGPoint(x: 0.3861, y: 0.6420),
        ],
        [
            CGPoint(x: 0.3176, y: 0.7041), CGPoint(x: 0.3012, y: 0.6863), CGPoint(x: 0.2867, y: 0.6676),
            CGPoint(x: 0.2743, y: 0.6481), CGPoint(x: 0.2637, y: 0.6281), CGPoint(x: 0.2550, y: 0.6075),
            CGPoint(x: 0.2482, y: 0.5865), CGPoint(x: 0.2431, y: 0.5651), CGPoint(x: 0.2398, y: 0.5435),
            CGPoint(x: 0.2382, y: 0.5218), CGPoint(x: 0.2383, y: 0.5001), CGPoint(x: 0.2399, y: 0.4785),
            CGPoint(x: 0.2432, y: 0.4571), CGPoint(x: 0.2479, y: 0.4360), CGPoint(x: 0.2542, y: 0.4153),
            CGPoint(x: 0.2619, y: 0.3951), CGPoint(x: 0.2710, y: 0.3755), CGPoint(x: 0.2815, y: 0.3567),
            CGPoint(x: 0.2933, y: 0.3387), CGPoint(x: 0.3063, y: 0.3216), CGPoint(x: 0.3206, y: 0.3055),
            CGPoint(x: 0.3319, y: 0.2944), CGPoint(x: 0.3439, y: 0.2839), CGPoint(x: 0.3566, y: 0.2742),
            CGPoint(x: 0.3697, y: 0.2653), CGPoint(x: 0.3834, y: 0.2571), CGPoint(x: 0.3976, y: 0.2497),
            CGPoint(x: 0.4122, y: 0.2432), CGPoint(x: 0.4272, y: 0.2375), CGPoint(x: 0.4425, y: 0.2326),
            CGPoint(x: 0.4580, y: 0.2287), CGPoint(x: 0.4739, y: 0.2256), CGPoint(x: 0.4899, y: 0.2236),
            CGPoint(x: 0.5060, y: 0.2224), CGPoint(x: 0.5223, y: 0.2223), CGPoint(x: 0.5386, y: 0.2232),
            CGPoint(x: 0.5549, y: 0.2251), CGPoint(x: 0.5711, y: 0.2281), CGPoint(x: 0.5873, y: 0.2322),
            CGPoint(x: 0.6033, y: 0.2373), CGPoint(x: 0.6192, y: 0.2437), CGPoint(x: 0.7319, y: 0.1894),
            CGPoint(x: 0.7288, y: 0.1871), CGPoint(x: 0.7256, y: 0.1848), CGPoint(x: 0.7224, y: 0.1824),
            CGPoint(x: 0.7190, y: 0.1801), CGPoint(x: 0.7156, y: 0.1778), CGPoint(x: 0.7121, y: 0.1754),
            CGPoint(x: 0.7085, y: 0.1731), CGPoint(x: 0.7049, y: 0.1708), CGPoint(x: 0.7012, y: 0.1686),
            CGPoint(x: 0.6974, y: 0.1663), CGPoint(x: 0.6935, y: 0.1641), CGPoint(x: 0.6896, y: 0.1619),
            CGPoint(x: 0.6856, y: 0.1597), CGPoint(x: 0.6815, y: 0.1576), CGPoint(x: 0.6773, y: 0.1555),
            CGPoint(x: 0.6731, y: 0.1535), CGPoint(x: 0.6689, y: 0.1516), CGPoint(x: 0.6645, y: 0.1496),
            CGPoint(x: 0.6601, y: 0.1478), CGPoint(x: 0.6557, y: 0.1460), CGPoint(x: 0.6352, y: 0.1380),
            CGPoint(x: 0.6145, y: 0.1313), CGPoint(x: 0.5934, y: 0.1258), CGPoint(x: 0.5721, y: 0.1217),
            CGPoint(x: 0.5507, y: 0.1188), CGPoint(x: 0.5291, y: 0.1173), CGPoint(x: 0.5075, y: 0.1170),
            CGPoint(x: 0.4859, y: 0.1181), CGPoint(x: 0.4644, y: 0.1204), CGPoint(x: 0.4430, y: 0.1241),
            CGPoint(x: 0.4218, y: 0.1290), CGPoint(x: 0.4009, y: 0.1352), CGPoint(x: 0.3803, y: 0.1427),
            CGPoint(x: 0.3600, y: 0.1515), CGPoint(x: 0.3401, y: 0.1616), CGPoint(x: 0.3208, y: 0.1729),
            CGPoint(x: 0.3020, y: 0.1856), CGPoint(x: 0.2837, y: 0.1996), CGPoint(x: 0.2662, y: 0.2148),
            CGPoint(x: 0.2493, y: 0.2313), CGPoint(x: 0.2340, y: 0.2482), CGPoint(x: 0.2199, y: 0.2660),
            CGPoint(x: 0.2068, y: 0.2845), CGPoint(x: 0.1948, y: 0.3038), CGPoint(x: 0.1840, y: 0.3236),
            CGPoint(x: 0.1744, y: 0.3441), CGPoint(x: 0.1659, y: 0.3650), CGPoint(x: 0.1585, y: 0.3864),
            CGPoint(x: 0.1524, y: 0.4082), CGPoint(x: 0.1475, y: 0.4303), CGPoint(x: 0.1438, y: 0.4527),
            CGPoint(x: 0.1413, y: 0.4752), CGPoint(x: 0.1401, y: 0.4979), CGPoint(x: 0.1402, y: 0.5206),
            CGPoint(x: 0.1415, y: 0.5434), CGPoint(x: 0.1441, y: 0.5661), CGPoint(x: 0.1480, y: 0.5887),
            CGPoint(x: 0.1532, y: 0.6111), CGPoint(x: 0.1597, y: 0.6332), CGPoint(x: 0.1676, y: 0.6551),
            CGPoint(x: 0.1731, y: 0.6710), CGPoint(x: 0.1771, y: 0.6865), CGPoint(x: 0.1795, y: 0.7016),
            CGPoint(x: 0.1805, y: 0.7163), CGPoint(x: 0.1802, y: 0.7306), CGPoint(x: 0.1786, y: 0.7446),
            CGPoint(x: 0.1758, y: 0.7582), CGPoint(x: 0.1719, y: 0.7715), CGPoint(x: 0.1670, y: 0.7845),
            CGPoint(x: 0.1612, y: 0.7973), CGPoint(x: 0.1545, y: 0.8099), CGPoint(x: 0.1470, y: 0.8222),
            CGPoint(x: 0.1389, y: 0.8344), CGPoint(x: 0.1302, y: 0.8464), CGPoint(x: 0.1209, y: 0.8583),
            CGPoint(x: 0.1113, y: 0.8700), CGPoint(x: 0.1013, y: 0.8817), CGPoint(x: 0.0910, y: 0.8933),
            CGPoint(x: 0.0806, y: 0.9049), CGPoint(x: 0.0701, y: 0.9164), CGPoint(x: 0.0663, y: 0.9205),
            CGPoint(x: 0.0626, y: 0.9246), CGPoint(x: 0.0589, y: 0.9287), CGPoint(x: 0.0551, y: 0.9328),
            CGPoint(x: 0.0514, y: 0.9370), CGPoint(x: 0.0477, y: 0.9411), CGPoint(x: 0.0441, y: 0.9452),
            CGPoint(x: 0.0404, y: 0.9493), CGPoint(x: 0.0368, y: 0.9535), CGPoint(x: 0.0332, y: 0.9576),
            CGPoint(x: 0.0297, y: 0.9618), CGPoint(x: 0.0262, y: 0.9660), CGPoint(x: 0.0227, y: 0.9702),
            CGPoint(x: 0.0193, y: 0.9744), CGPoint(x: 0.0159, y: 0.9786), CGPoint(x: 0.0126, y: 0.9828),
            CGPoint(x: 0.0094, y: 0.9871), CGPoint(x: 0.0062, y: 0.9914), CGPoint(x: 0.0031, y: 0.9957),
            CGPoint(x: 0.0000, y: 1.0000), CGPoint(x: 0.3175, y: 0.7042),
        ],
    ]
}

/// Official marks. Claude comes from Simple Icons, OpenAI from its brand kit, all 24pt view boxes.
private struct ClaudeSparkle: View {
    private static let path = SVGPath(
        viewBox: 24,
        data:
            "m4.7144 15.9555 4.7174-2.6471.079-.2307-.079-.1275h-.2307l-.7893-.0486-2.6956-.0729-2.3375-.0971-2.2646-.1214-.5707-.1215-.5343-.7042.0546-.3522.4797-.3218.686.0608 1.5179.1032 2.2767.1578 1.6514.0972 2.4468.255h.3886l.0546-.1579-.1336-.0971-.1032-.0972L6.973 9.8356l-2.55-1.6879-1.3356-.9714-.7225-.4918-.3643-.4614-.1578-1.0078.6557-.7225.8803.0607.2246.0607.8925.686 1.9064 1.4754 2.4893 1.8336.3643.3035.1457-.1032.0182-.0728-.164-.2733-1.3539-2.4467-1.445-2.4893-.6435-1.032-.17-.6194c-.0607-.255-.1032-.4674-.1032-.7285L6.287.1335 6.6997 0l.9957.1336.419.3642.6192 1.4147 1.0018 2.2282 1.5543 3.0296.4553.8985.2429.8318.091.255h.1579v-.1457l.1275-1.706.2368-2.0947.2307-2.6957.0789-.7589.3764-.9107.7468-.4918.5828.2793.4797.686-.0668.4433-.2853 1.8517-.5586 2.9021-.3643 1.9429h.2125l.2429-.2429.9835-1.3053 1.6514-2.0643.7286-.8196.85-.9046.5464-.4311h1.0321l.759 1.1293-.34 1.1657-1.0625 1.3478-.8804 1.1414-1.2628 1.7-.7893 1.36.0729.1093.1882-.0183 2.8535-.607 1.5421-.2794 1.8396-.3157.8318.3886.091.3946-.3278.8075-1.967.4857-2.3072.4614-3.4364.8136-.0425.0304.0486.0607 1.5482.1457.6618.0364h1.621l3.0175.2247.7892.522.4736.6376-.079.4857-1.2142.6193-1.6393-.3886-3.825-.9107-1.3113-.3279h-.1822v.1093l1.0929 1.0686 2.0035 1.8092 2.5075 2.3314.1275.5768-.3218.4554-.34-.0486-2.2039-1.6575-.85-.7468-1.9246-1.621h-.1275v.17l.4432.6496 2.3436 3.5214.1214 1.0807-.17.3521-.6071.2125-.6679-.1214-1.3721-1.9246L14.38 17.959l-1.1414-1.9428-.1397.079-.674 7.2552-.3156.3703-.7286.2793-.6071-.4614-.3218-.7468.3218-1.4753.3886-1.9246.3157-1.53.2853-1.9004.17-.6314-.0121-.0425-.1397.0182-1.4328 1.9672-2.1796 2.9446-1.7243 1.8456-.4128.164-.7164-.3704.0667-.6618.4008-.5889 2.386-3.0357 1.4389-1.882.929-1.0868-.0062-.1579h-.0546l-6.3385 4.1164-1.1293.1457-.4857-.4554.0608-.7467.2307-.2429 1.9064-1.3114Z"
    )

    var body: some View { Self.path.fill() }
}

private struct OpenAIKnot: View {
    private static let path = SVGPath(
        viewBox: 24,
        data:
            "M22.2819 9.8211a5.9847 5.9847 0 0 0-.5157-4.9108 6.0462 6.0462 0 0 0-6.5098-2.9A6.0651 6.0651 0 0 0 4.9807 4.1818a5.9847 5.9847 0 0 0-3.9977 2.9 6.0462 6.0462 0 0 0 .7427 7.0966 5.98 5.98 0 0 0 .511 4.9107 6.051 6.051 0 0 0 6.5146 2.9001A5.9847 5.9847 0 0 0 13.2599 24a6.0557 6.0557 0 0 0 5.7718-4.2058 5.9894 5.9894 0 0 0 3.9977-2.9001 6.0557 6.0557 0 0 0-.7475-7.0729zm-9.022 12.6081a4.4755 4.4755 0 0 1-2.8764-1.0408l.1419-.0804 4.7783-2.7582a.7948.7948 0 0 0 .3927-.6813v-6.7369l2.02 1.1686a.071.071 0 0 1 .038.052v5.5826a4.504 4.504 0 0 1-4.4945 4.4944zm-9.6607-4.1254a4.4708 4.4708 0 0 1-.5346-3.0137l.142.0852 4.783 2.7582a.7712.7712 0 0 0 .7806 0l5.8428-3.3685v2.3324a.0804.0804 0 0 1-.0332.0615L9.74 19.9502a4.4992 4.4992 0 0 1-6.1408-1.6464zM2.3408 7.8956a4.485 4.485 0 0 1 2.3655-1.9728V11.6a.7664.7664 0 0 0 .3879.6765l5.8144 3.3543-2.0201 1.1685a.0757.0757 0 0 1-.071 0l-4.8303-2.7865A4.504 4.504 0 0 1 2.3408 7.872zm16.5963 3.8558L13.1038 8.364 15.1192 7.2a.0757.0757 0 0 1 .071 0l4.8303 2.7913a4.4944 4.4944 0 0 1-.6765 8.1042v-5.6772a.79.79 0 0 0-.407-.667zm2.0107-3.0231l-.142-.0852-4.7735-2.7818a.7759.7759 0 0 0-.7854 0L9.409 9.2297V6.8974a.0662.0662 0 0 1 .0284-.0615l4.8303-2.7866a4.4992 4.4992 0 0 1 6.6802 4.66zM8.3065 12.863l-2.02-1.1638a.0804.0804 0 0 1-.038-.0567V6.0742a4.4992 4.4992 0 0 1 7.3757-3.4537l-.142.0805L8.704 5.459a.7948.7948 0 0 0-.3927.6813zm1.0976-2.3654l2.602-1.4998 2.6069 1.4998v2.9994l-2.5974 1.4997-2.6067-1.4997Z"
    )

    var body: some View {
        Self.path.fill()
    }
}

/// Minimal SVG path parser covering M L H V C A Z and their relative forms, scaled to fill the view.
nonisolated struct SVGPath: Shape {
    let viewBox: CGFloat
    let commands: [Command]

    enum Command {
        case move(CGPoint)
        case line(CGPoint)
        case curve(CGPoint, CGPoint, CGPoint)
        case close
    }

    init(viewBox: CGFloat, data: String) {
        self.viewBox = viewBox
        commands = Self.parse(data)
    }

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / viewBox
        let offset = CGPoint(
            x: rect.midX - viewBox * scale / 2,
            y: rect.midY - viewBox * scale / 2
        )
        let map = { (point: CGPoint) in
            CGPoint(x: offset.x + point.x * scale, y: offset.y + point.y * scale)
        }
        var path = Path()
        for command in commands {
            switch command {
            case .move(let point): path.move(to: map(point))
            case .line(let point): path.addLine(to: map(point))
            case .curve(let c1, let c2, let end):
                path.addCurve(to: map(end), control1: map(c1), control2: map(c2))
            case .close: path.closeSubpath()
            }
        }
        return path
    }

    private static func parse(_ data: String) -> [Command] {
        var commands: [Command] = []
        var tokens = Tokenizer(data)
        var current = CGPoint.zero
        var subpathStart = CGPoint.zero
        var letter: Character = "M"

        while let token = tokens.next() {
            if case .letter(let next) = token {
                letter = next
            } else {
                tokens.pushBack(token)
            }
            let relative = letter.isLowercase
            let base = { relative ? current : .zero }

            switch letter.uppercased() {
            case "M":
                let point = tokens.point(base())
                commands.append(.move(point))
                current = point
                subpathStart = point
                letter = relative ? "l" : "L"
            case "L":
                let point = tokens.point(base())
                commands.append(.line(point))
                current = point
            case "H":
                let x = tokens.number() + (relative ? current.x : 0)
                current = CGPoint(x: x, y: current.y)
                commands.append(.line(current))
            case "V":
                let y = tokens.number() + (relative ? current.y : 0)
                current = CGPoint(x: current.x, y: y)
                commands.append(.line(current))
            case "C":
                let c1 = tokens.point(base())
                let c2 = tokens.point(base())
                let end = tokens.point(base())
                commands.append(.curve(c1, c2, end))
                current = end
            case "A":
                let rx = tokens.number()
                let ry = tokens.number()
                let rotation = tokens.number()
                let largeArc = tokens.number() != 0
                let sweep = tokens.number() != 0
                let end = tokens.point(base())
                commands.append(
                    contentsOf: arc(
                        from: current, to: end, rx: rx, ry: ry, rotation: rotation,
                        largeArc: largeArc, sweep: sweep))
                current = end
            case "Z":
                commands.append(.close)
                current = subpathStart
            default:
                return commands
            }
        }
        return commands
    }

    /// Converts an SVG elliptical arc into cubic curves (W3C implementation notes, F.6.5).
    private static func arc(
        from start: CGPoint, to end: CGPoint, rx: CGFloat, ry: CGFloat, rotation: CGFloat,
        largeArc: Bool, sweep: Bool
    ) -> [Command] {
        guard rx > 0, ry > 0, start != end else { return [.line(end)] }
        var rx = abs(rx)
        var ry = abs(ry)
        let phi = rotation * .pi / 180
        let cosPhi = cos(phi)
        let sinPhi = sin(phi)
        let dx = (start.x - end.x) / 2
        let dy = (start.y - end.y) / 2
        let x1 = cosPhi * dx + sinPhi * dy
        let y1 = -sinPhi * dx + cosPhi * dy
        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lambda > 1 {
            rx *= sqrt(lambda)
            ry *= sqrt(lambda)
        }
        let numerator = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let denominator = rx * rx * y1 * y1 + ry * ry * x1 * x1
        var factor = sqrt(max(0, numerator / denominator))
        if largeArc == sweep { factor = -factor }
        let cx1 = factor * rx * y1 / ry
        let cy1 = -factor * ry * x1 / rx
        let cx = cosPhi * cx1 - sinPhi * cy1 + (start.x + end.x) / 2
        let cy = sinPhi * cx1 + cosPhi * cy1 + (start.y + end.y) / 2

        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let dot = ux * vx + uy * vy
            let length = sqrt(ux * ux + uy * uy) * sqrt(vx * vx + vy * vy)
            var value = acos(max(-1, min(1, dot / length)))
            if ux * vy - uy * vx < 0 { value = -value }
            return value
        }
        let theta1 = angle(1, 0, (x1 - cx1) / rx, (y1 - cy1) / ry)
        var delta = angle((x1 - cx1) / rx, (y1 - cy1) / ry, (-x1 - cx1) / rx, (-y1 - cy1) / ry)
        if !sweep, delta > 0 { delta -= 2 * .pi }
        if sweep, delta < 0 { delta += 2 * .pi }

        let segments = Int(ceil(abs(delta) / (.pi / 2)))
        let step = delta / CGFloat(segments)
        let t = 4 / 3 * tan(step / 4)
        var commands: [Command] = []
        var theta = theta1
        for _ in 0..<segments {
            let cos1 = cos(theta)
            let sin1 = sin(theta)
            let cos2 = cos(theta + step)
            let sin2 = sin(theta + step)
            let p1 = CGPoint(x: cos1 - t * sin1, y: sin1 + t * cos1)
            let p2 = CGPoint(x: cos2 + t * sin2, y: sin2 - t * cos2)
            let p3 = CGPoint(x: cos2, y: sin2)
            let map = { (p: CGPoint) in
                CGPoint(
                    x: cx + cosPhi * rx * p.x - sinPhi * ry * p.y,
                    y: cy + sinPhi * rx * p.x + cosPhi * ry * p.y
                )
            }
            commands.append(.curve(map(p1), map(p2), map(p3)))
            theta += step
        }
        return commands
    }

    private struct Tokenizer {
        enum Token {
            case letter(Character)
            case number(CGFloat)
        }

        private let scalars: [Character]
        private var index = 0
        private var buffer: [Token] = []

        init(_ data: String) {
            scalars = Array(data)
        }

        mutating func pushBack(_ token: Token) {
            buffer.append(token)
        }

        mutating func next() -> Token? {
            if let token = buffer.popLast() { return token }
            while index < scalars.count,
                scalars[index] == " " || scalars[index] == "," || scalars[index] == "\n"
            {
                index += 1
            }
            guard index < scalars.count else { return nil }
            let character = scalars[index]
            if character.isLetter {
                index += 1
                return .letter(character)
            }
            var text = ""
            var seenDot = false
            var seenExponent = false
            while index < scalars.count {
                let c = scalars[index]
                if c.isNumber {
                    text.append(c)
                } else if c == ".", !seenDot, !seenExponent {
                    seenDot = true
                    text.append(c)
                } else if c == "-" || c == "+", text.isEmpty || text.last == "e" {
                    text.append(c)
                } else if c == "e" || c == "E", !seenExponent, !text.isEmpty {
                    seenExponent = true
                    text.append("e")
                } else {
                    break
                }
                index += 1
            }
            return .number(CGFloat(Double(text) ?? 0))
        }

        mutating func number() -> CGFloat {
            if case .number(let value)? = next() { return value }
            return 0
        }

        mutating func point(_ base: CGPoint) -> CGPoint {
            CGPoint(x: base.x + number(), y: base.y + number())
        }
    }
}
