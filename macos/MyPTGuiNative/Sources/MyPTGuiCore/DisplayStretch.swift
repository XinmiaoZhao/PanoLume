import Foundation

public enum DisplayStretch {
    public static func computeParams(
        rgb: [Float],
        blackPercentile: Double = 0.5,
        whitePercentile: Double = 99.7,
        gamma: Double = 0.45,
        ignoreZeros: Bool = true
    ) -> StretchParams? {
        guard !rgb.isEmpty else {
            return nil
        }
        var luminance: [Double] = []
        luminance.reserveCapacity(rgb.count / 3)
        var index = 0
        while index + 2 < rgb.count {
            let value =
                0.2126 * Double(rgb[index])
                + 0.7152 * Double(rgb[index + 1])
                + 0.0722 * Double(rgb[index + 2])
            if value.isFinite && (!ignoreZeros || value > 1e-7) {
                luminance.append(value)
            }
            index += 3
        }
        guard !luminance.isEmpty else {
            return nil
        }
        luminance.sort()
        let black = percentile(luminance, blackPercentile)
        let white = percentile(luminance, whitePercentile)
        guard black.isFinite, white.isFinite, white > black + 1e-8 else {
            return nil
        }
        return StretchParams(black: black, white: white, gamma: gamma)
    }

    public static func apply(rgb: [Float], params: StretchParams?, strength: Double = 1.0) -> [Float] {
        guard !rgb.isEmpty else {
            return rgb
        }
        let linear = rgb.map { min(1.0, max(0.0, $0)) }
        guard let params, strength > 0, params.white > params.black + 1e-8 else {
            return linear
        }
        return zip(rgb, linear).map { raw, clipped in
            var stretched = min(1.0, max(0.0, (Double(raw) - params.black) / (params.white - params.black)))
            if params.gamma > 0, abs(params.gamma - 1.0) > 1e-6 {
                stretched = pow(stretched, params.gamma)
            }
            let result: Double
            if strength < 1.0 {
                result = Double(clipped) * (1.0 - strength) + stretched * strength
            } else if strength > 1.0 {
                result = pow(stretched, 1.0 / min(strength, 4.0))
            } else {
                result = stretched
            }
            return Float(min(1.0, max(0.0, result)))
        }
    }

    public static func autoStretch(
        rgb: [Float],
        blackPercentile: Double = 0.5,
        whitePercentile: Double = 99.7,
        gamma: Double = 0.45,
        ignoreZeros: Bool = true,
        strength: Double = 1.0
    ) -> [Float] {
        let params = computeParams(
            rgb: rgb,
            blackPercentile: blackPercentile,
            whitePercentile: whitePercentile,
            gamma: gamma,
            ignoreZeros: ignoreZeros
        )
        return apply(rgb: rgb, params: params, strength: strength)
    }

    private static func percentile(_ sorted: [Double], _ percentile: Double) -> Double {
        guard !sorted.isEmpty else {
            return 0
        }
        let clipped = min(100.0, max(0.0, percentile))
        let position = (Double(sorted.count) - 1.0) * clipped / 100.0
        let lower = Int(floor(position))
        let upper = Int(ceil(position))
        if lower == upper {
            return sorted[lower]
        }
        let alpha = position - Double(lower)
        return sorted[lower] * (1.0 - alpha) + sorted[upper] * alpha
    }
}
