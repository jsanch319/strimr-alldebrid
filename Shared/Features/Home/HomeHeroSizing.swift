import Foundation

nonisolated enum HomeHeroSizing {
    static func iPhoneHeight(availableHeight: Double) -> Double {
        max(0, availableHeight) * 0.5
    }
}
