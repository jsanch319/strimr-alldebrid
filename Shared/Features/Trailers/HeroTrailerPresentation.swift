#if os(iOS)
    import SwiftUI

    struct HeroTrailerPresentation {
        let preview: DirectTrailerPreview?
    }

    extension EnvironmentValues {
        @Entry var heroTrailerPresentation: HeroTrailerPresentation? = nil
    }
#endif
