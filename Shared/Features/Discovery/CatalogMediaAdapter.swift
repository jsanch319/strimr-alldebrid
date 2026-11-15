import Foundation

enum CatalogMediaAdapter {
    static func selectionID(_ media: MediaItem) -> String? {
        media.guid.hasPrefix("tmdb://") || media.guid.hasPrefix("alldebrid://") ? media.id : nil
    }

    static func artworkURL(_ path: String?) -> URL? {
        guard let path, let url = URL(string: path), url.scheme == "https",
              url.host == "image.tmdb.org" else { return nil }
        return url
    }

    static func raw(id: String, filename: String) -> MediaItem {
        let title = TMDBTitle.reference(id: 0, kind: .movie, title: AllDebridLibraryView.cleanTitle(filename))
        return make(title: title, episode: nil, resume: nil, identifier: id, guid: "alldebrid://\(id)")
    }

    static func make(
        title: TMDBTitle,
        episode: TMDBEpisode?,
        resume: Double?,
        duration: Double? = nil,
        completed: Bool = false,
        identifier: String? = nil,
        guid: String? = nil,
    ) -> MediaItem {
        MediaItem(
            id: identifier ?? CatalogProgress.key(title: title, episode: episode),
            guid: guid ?? "tmdb://\(title.catalogID)",
            summary: episode?.overview ?? title.overview,
            title: episode?.name ?? title.displayTitle,
            type: episode == nil ? (title.kind == .tv ? .series : .movie) : .episode,
            parentRatingKey: nil,
            grandparentRatingKey: nil,
            genres: title.genres?.map(\.name) ?? [],
            year: Int(title.date.prefix(4)),
            duration: duration ?? (episode?.runtime ?? title.runtime).map { Double($0) * 60 },
            videoResolution: nil,
            rating: title.vote_average,
            ratings: [],
            contentRating: nil,
            studio: nil,
            tagline: nil,
            thumbPath: TMDBImageService.imageURL(path: episode?.still_path ?? title.poster_path, size: .w500)?
                .absoluteString,
            artPath: TMDBImageService.imageURL(path: episode?.still_path ?? title.backdrop_path, size: .w1280)?
                .absoluteString,
            artworkCornerColors: nil,
            viewOffset: resume,
            viewCount: completed ? 1 : nil,
            childCount: nil,
            leafCount: nil,
            viewedLeafCount: nil,
            grandparentTitle: episode == nil ? nil : title.displayTitle,
            parentTitle: nil,
            parentIndex: episode?.season_number,
            index: episode?.episode_number,
            grandparentThumbPath: TMDBImageService.imageURL(path: title.poster_path, size: .w500)?.absoluteString,
            grandparentArtPath: TMDBImageService.imageURL(path: title.backdrop_path, size: .w1280)?.absoluteString,
            parentThumbPath: TMDBImageService.imageURL(path: title.poster_path, size: .w500)?.absoluteString,
            externalIDs: title.matchingIDs,
        )
    }
}
