#if os(iOS)
    import SwiftUI

    struct HeroTrailerPresentation {
        let preview: DirectTrailerPreview?
        let selection: TrailerSelection?
        let watch: () -> Void
    }

    extension EnvironmentValues {
        @Entry var heroTrailerPresentation: HeroTrailerPresentation? = nil
    }
#endif
