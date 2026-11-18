import Foundation
import GroupActivities

struct StrimrWatchActivity: GroupActivity, Hashable, Sendable {
    static let activityIdentifier = "com.github.wunax.strimr.watch"

    let activityID: UUID
    let provider: MediaProvider
    let serverIdentifier: String
    let ratingKey: String
    let mediaKind: MediaKind
    let title: String
    let initialPosition: Double
    let catalog: CatalogSharePlayItem?

    init(
        activityID: UUID,
        provider: MediaProvider,
        serverIdentifier: String,
        ratingKey: String,
        mediaKind: MediaKind,
        title: String,
        initialPosition: Double,
        catalog: CatalogSharePlayItem? = nil,
    ) {
        self.activityID = activityID; self.provider = provider; self.serverIdentifier = serverIdentifier
        self.ratingKey = ratingKey; self.mediaKind = mediaKind; self.title = title
        self.initialPosition = initialPosition; self.catalog = catalog
    }

    var metadata: GroupActivityMetadata {
        get async {
            var metadata = GroupActivityMetadata()
            metadata.type = .watchTogether
            metadata.title = title
            metadata.subtitle = String(localized: "sharePlay.activity.subtitle")
            metadata.supportsContinuationOnTV = catalog == nil
            return metadata
        }
    }
}

extension StrimrWatchActivity: Identifiable { var id: UUID {
    activityID
} }
