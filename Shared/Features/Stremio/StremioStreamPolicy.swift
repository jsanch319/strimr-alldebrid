import Foundation

/// The installed add-on is queried for an exact IMDb movie/season/episode. Extra metadata
/// can contradict that identity, but an opaque CDN filename is not a contradiction.
@MainActor
enum StremioStreamPolicy {
    static func accepts(_ filename: String?, title: TMDBTitle, episode: TMDBEpisode?) -> Bool {
        guard let filename, !filename.isEmpty else { return true }
        let text = filename.removingPercentEncoding ?? filename
        var matchingID = false
        if let regex = try? NSRegularExpression(pattern: #"(?i)\btt\d{5,12}\b"#) {
            let ids = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
                Range($0.range, in: text).map { String(text[$0]).lowercased() }
            }
            if !ids.isEmpty, ids.contains(where: { $0 != title.matchingIDs.imdb?.lowercased() }) {
                return false
            }
            matchingID = !ids.isEmpty
        }
        if let regex = try? NSRegularExpression(pattern: #"(?i)tmdb[\s:=_{\[-]+(\d+)"#) {
            let ids = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
                Range($0.range(at: 1), in: text).map { String(text[$0]) }
            }
            if ids.contains(where: { $0 != String(title.id) }) {
                return false
            }
            matchingID = matchingID || !ids.isEmpty
        }
        if title.kind == .movie, let year = Int(title.date.prefix(4)),
           let regex = try? NSRegularExpression(pattern: #"\b(?:19|20)\d{2}\b"#)
        {
            let years = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
                Range($0.range, in: text).map { String(text[$0]) }
            }
            if years.contains(where: { $0 != String(year) }) {
                return false
            }
        }
        let hasEpisode = text.range(of: #"(?i)s\d+e\d+|\d+x\d+"#, options: .regularExpression) != nil
        if hasEpisode {
            guard let episode, let found = AllDebridTitleMatcher.episodeNumbers(in: text),
                  found.season == episode.season_number, found.episode == episode.episode_number,
                  text.range(
                      of: #"(?i)s\d+e\d+(?:[ ._-]*e\d+|[ ._-]*-[ ._-]*(?:e)?\d+)|\d+x\d+[ ._-]*-"#,
                      options: .regularExpression,
                  ) == nil else { return false }
        }
        if matchingID {
            return true
        }
        if AuthorizedSourceCandidate.matchesFile(text, title: title, episode: episode) {
            return true
        }
        var prefix = ((text as NSString).lastPathComponent as NSString).deletingPathExtension
        prefix = prefix.replacingOccurrences(of: #"(?i)(?:s\d+e\d+|\d+x\d+).*$"#, with: "", options: .regularExpression)
        prefix = AllDebridLibraryView.cleanTitle(prefix + ".mkv")
        func normalized(_ raw: String) -> String {
            raw.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
        }
        let clean = normalized(prefix)
        if clean.isEmpty || ["video", "stream", "file", "main", "movie", "episode", "playback", "master", "index"]
            .contains(clean)
            || clean.replacingOccurrences(of: " ", with: "")
            .range(of: #"^[a-f0-9]{8,}$"#, options: .regularExpression) != nil
        {
            return true
        }
        let aliases = [title.displayTitle, title.original_title, title.original_name].compactMap(\.self)
            + (title.alternative_titles?.titles ?? title.alternative_titles?.results ?? []).map(\.title)
        return aliases.contains { alias in
            let alternatives = [alias] + alias.components(separatedBy: ":")
                .filter { $0.split(separator: " ").count >= 3 }
            return alternatives.contains { value in
                let expected = normalized(value)
                let names = [expected, expected.hasPrefix("the ") ? String(expected.dropFirst(4)) : expected]
                return names.contains { name in
                    clean == name || clean.range(
                        of: "^" + NSRegularExpression.escapedPattern(for: name) + #" (?:19|20)\d{2}$"#,
                        options: .regularExpression,
                    ) != nil
                }
            }
        }
    }

    static func readyFile(_ file: AllDebridMagnetFile, title: TMDBTitle, episode: TMDBEpisode?) -> Bool {
        guard file.isVideo else { return false }
        if let episode {
            guard let found = AllDebridTitleMatcher.episodeNumbers(in: file.fullPath),
                  found.season == episode.season_number, found.episode == episode.episode_number else { return false }
        }
        return accepts(file.filename, title: title, episode: episode)
    }
}

nonisolated enum StremioAudioHint: Int, Hashable, Sendable {
    case english, multilingual, unknown, other
    var label: String {
        switch self {
        case .english: "Provider reports English (unverified)"
        case .multilingual: "Provider reports multilingual (English unverified)"
        case .unknown: "Audio language unverified"
        case .other: "Provider reports other audio languages"
        }
    }

    static func reported(by stream: StremioStream) -> Self {
        if let languages = stream.languages, !languages.isEmpty {
            let normalized = languages.map { $0.lowercased().replacingOccurrences(of: "_", with: "-") }
            if normalized
                .contains(where: {
                    ["en", "eng", "english"].contains($0.split(separator: "-").first.map(String.init) ?? "")
                })
            {
                return .english
            }
            if normalized.contains(where: { ["multi", "multilingual", "mul"].contains($0) }) {
                return .multilingual
            }
            if !normalized.allSatisfy({ ["und", "unknown", "unk", "zxx", ""].contains($0) }) {
                return .other
            }
        }
        let text = [stream.name, stream.title, stream.displayDetails].compactMap(\.self).joined(separator: " ")
        if text.contains("🇬🇧") || text.contains("🇺🇸") || text.range(
            of: #"(?i)\b(?:audio|language)[ :\-]+(?:en|eng|english)\b"#,
            options: .regularExpression,
        ) != nil {
            return .english
        }
        if text
            .range(
                of: #"(?i:\b(?:multi[ ._-]*(?:audio|language)|dual[ ._-]*audio)\b)|\bMULTI\b"#,
                options: .regularExpression,
            ) !=
            nil
        {
            return .multilingual
        }
        return .unknown // A movie/file title containing the word English is not a language declaration.
    }
}
