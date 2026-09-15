import Foundation

/// Precomputed piecewise-linear tempo conversion for playback and large MIDI imports.
public struct Timeline: Sendable {
    private var tempos: [Tempo]
    private var times: [Double]
    public init(_ score: Score) {
        tempos = score.tempoMap; times = []
        var time = 0.0, beat = 0.0, rate = score.bpm
        for tempo in tempos { time += (tempo.beat - beat) * 60 / rate; times.append(time); beat = tempo.beat; rate = tempo.bpm }
    }
    private func floorIndex(_ value: Double, _ valueAt: (Int) -> Double) -> Int {
        var low = 0, high = tempos.count
        while low < high { let mid = (low + high) / 2; if valueAt(mid) <= value { low = mid + 1 } else { high = mid } }
        return max(0, low - 1)
    }
    public func seconds(at beat: Double) -> Double {
        let i = floorIndex(beat) { tempos[$0].beat }
        return times[i] + (beat - tempos[i].beat) * 60 / tempos[i].bpm
    }
    public func beat(at time: Double) -> Double {
        let i = floorIndex(time) { times[$0] }
        return tempos[i].beat + (time - times[i]) * tempos[i].bpm / 60
    }
}
