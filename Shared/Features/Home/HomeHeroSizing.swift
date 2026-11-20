import Foundation

nonisolated enum HomeHeroSizing {
    static func iPhoneHeight(availableHeight: Double) -> Double {
        guard availableHeight.isFinite, availableHeight > 0 else { return 0 }
        // Tiny landscape viewports reserve enough height for title/actions, capped at the actual viewport.
        return min(availableHeight, max(availableHeight * 0.7, 200))
    }
}
