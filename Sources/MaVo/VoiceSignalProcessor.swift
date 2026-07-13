import Foundation

/// Conditions microphone audio before it is reduced to the modem's 8 kHz
/// telephone channel. The high-pass removes DC/desk rumble; the two cascaded
/// low-pass stages prevent higher-frequency microphone content from aliasing
/// back into the speech band during downsampling.
struct VoiceCaptureConditioner {
    private(set) var sampleRate = 0.0
    private var previousInput: Float = 0
    private var highPassOutput: Float = 0
    private var lowPassStage1: Float = 0
    private var lowPassStage2: Float = 0

    mutating func process(_ samples: [Float], sampleRate: Double) -> [Float] {
        guard sampleRate > 0, !samples.isEmpty else { return [] }
        if self.sampleRate != sampleRate {
            reset(sampleRate: sampleRate)
        }

        let timeStep = 1.0 / sampleRate
        let highPassRC = 1.0 / (2.0 * Double.pi * 80.0)
        let highPassAlpha = Float(highPassRC / (highPassRC + timeStep))
        let lowPassCutoff = min(3_400.0, sampleRate * 0.45)
        let lowPassAlpha = Float(1.0 - exp(-2.0 * Double.pi * lowPassCutoff / sampleRate))

        var output = [Float]()
        output.reserveCapacity(samples.count)
        for sample in samples {
            highPassOutput = highPassAlpha * (highPassOutput + sample - previousInput)
            previousInput = sample
            lowPassStage1 += lowPassAlpha * (highPassOutput - lowPassStage1)
            lowPassStage2 += lowPassAlpha * (lowPassStage1 - lowPassStage2)
            output.append(max(-1, min(1, lowPassStage2)))
        }
        return output
    }

    mutating func reset(sampleRate: Double = 0) {
        self.sampleRate = sampleRate
        previousInput = 0
        highPassOutput = 0
        lowPassStage1 = 0
        lowPassStage2 = 0
    }
}
