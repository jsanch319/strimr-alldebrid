import Foundation

/// Only available saved links and ready magnet files are eligible. Matching never acquires content.
enum AllDebridTitleMatcher {
    enum Source: Identifiable, Hashable {
        case magnet(AllDebridMagnetFile)
        case saved(AllDebridSavedLink)
        var id: String {
            switch self { case let .magnet(file): "magnet:\(file.id)"; case let .saved(link): "saved:\(link.id)" }
        }

        var filename: String {
            switch self { case let .magnet(file): file.filename; case let .saved(link): link.filename }
        }

        var link: String {
            switch self { case let .magnet(file): file.link; case let .saved(link): link.link }
        }

        var details: String {
            switch self { case let .magnet(file): AllDebridLibraryView.sourceDetails(file); case .saved: "Saved link" }
        }
    }

    static func sources(
        title: TMDBTitle,
        episode: TMDBEpisode?,
        files: [AllDebridMagnetFile],
        links: [AllDebridSavedLink],
        magnetNames: [String: String] = [:],
    ) -> [Source] {
        let magnets = files.filter { file in
            file.isVideo && matches(
                title: title,
                episode: episode,
                filename: file.filename,
                context: [magnetNames[file.magnetID], file.fullPath].compactMap(\.self)
                    .joined(separator: "/"),
            )
        }.map(Source.magnet)
        let saved = links.filter { $0.isVideo && matches(title: title, episode: episode, filename: $0.filename) }
            .map(Source.saved)
        return (magnets + saved).sorted { $0.filename.localizedStandardCompare($1.filename) == .orderedAscending }
    }

    static func matches(title: TMDBTitle, episode: TMDBEpisode?, filename: String, context: String = "") -> Bool {
        let text = context + "/" + filename
        let marker = episodeNumbers(in: text)
        if title.kind == .tv {
            guard let episode, let marker, marker.season == episode.season_number,
                  marker.episode == episode.episode_number else { return false }
        } else if episode != nil || marker != nil {
            return false
        }

        // Explicit IDs beat title spelling, but still must agree with the episode above.
        let tmdbPattern = #"(?i)tmdb[\s:=_{\[-]+(\d+)"#
        if let id = capture(tmdbPattern, in: text, group: 1) {
            return id == String(title.id)
        }
        if let imdb = capture(#"(?i)\btt\d{5,}\b"#, in: text, group: 0), let expected = title.matchingIDs.imdb {
            return imdb.lowercased() == expected.lowercased()
        }
        let normalizedTitle = normalized(title.displayTitle)
        guard !normalizedTitle.isEmpty else { return false }
        let clean = normalized(AllDebridLibraryView.cleanTitle(filename))
        if title.kind == .movie {
            if clean == normalizedTitle {
                return true
            }
            guard clean.hasPrefix(normalizedTitle + " ") else { return false }
            let suffix = String(clean.dropFirst(normalizedTitle.count)).trimmingCharacters(in: .whitespaces)
            guard suffix.range(of: #"^(?:19|20)\d{2}$"#, options: .regularExpression) != nil else { return false }
            return Int(title.date.prefix(4)).map { String($0) == suffix } ?? true
        }
        // Exact show name before an episode token or as a folder/pack name. No substring/fuzzy matching.
        let components = text.components(separatedBy: "/")
        return components.contains { component in
            let beforeEpisode = component.replacingOccurrences(
                of: #"(?i)[ ._-]*(?:s\d+e\d+|\d+x\d+).*$"#,
                with: "",
                options: .regularExpression,
            )
            let cleaned = normalized(beforeEpisode)
                .replacingOccurrences(of: #"\s+(?:19|20)\d{2}$"#, with: "", options: .regularExpression)
            return cleaned == normalizedTitle
        }
    }

    static func episodeNumbers(in text: String) -> (season: Int, episode: Int)? {
        let pattern = #"(?i)(?:\b|_)s(\d{1,3})e(\d{1,4})(?!\d|e\d)|(?:\b|_)(\d{1,3})x(\d{1,4})(?!\d)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        let values = matches.compactMap { match -> [Int]? in
            for offset in [1, 3] {
                if let sr = Range(match.range(at: offset), in: text), let er = Range(
                    match.range(at: offset + 1),
                    in: text,
                ), let s = Int(text[sr]), let e = Int(text[er]) {
                    return [s, e]
                }
            }
            return nil
        }
        guard let first = values.first, values.allSatisfy({ $0 == first }) else { return nil }
        return (first[0], first[1])
    }

    private static func capture(_ pattern: String, in text: String, group: Int) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern), let match = regex.firstMatch(
            in: text,
            range: NSRange(text.startIndex..., in: text),
        ), let range = Range(match.range(at: group), in: text) else { return nil }
        return String(text[range])
    }

    private static func normalized(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}
