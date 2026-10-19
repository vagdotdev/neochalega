import Foundation

/// Hard clamp onto 6 cores. Steps the full error in one sample.
/// It does not ease, decay, or keep a residual burn after demand drops.
enum Clamp {
    static let targetCores = 6.0

    static func nextBurn(other: Double, saturated: Bool, holding: Double, maxBurn: Double) -> Double {
        let hold = min(max(0, holding), maxBurn)
        let next: Double
        if !saturated {
            next = other <= targetCores + 0.15 ? 0 : (other - targetCores)
        } else if other > targetCores + 0.4 {
            next = hold + (other - targetCores)
        } else if other < targetCores - 0.8 {
            next = hold - (targetCores - other)
        } else {
            next = hold
        }
        return min(max(0, next), maxBurn)
    }
}
