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
        return ranked(magnets + saved, magnetNames: magnetNames)
    }

    /// Deterministic quality preference, without discarding lower-resolution fallback candidates.
    static func ranked(_ sources: [Source], magnetNames: [String: String] = [:]) -> [Source] {
        func quality(_ source: Source) -> Int {
            if case let .magnet(file) = source {
                let filenameQuality = resolution(file.filename)
                return filenameQuality > 0 ? filenameQuality :
                    resolution(file.fullPath + " " + (magnetNames[file.magnetID] ?? ""))
            }
            return resolution(source.filename)
        }
        return sources.sorted {
            let left = quality($0), right = quality($1)
            if left != right {
                return left > right
            }
            return $0.filename == $1.filename ? $0.id < $1.id : $0.filename
                .localizedStandardCompare($1.filename) == .orderedAscending
        }
    }

    static func resolution(_ filename: String) -> Int {
        let text = filename.lowercased().replacingOccurrences(of: "_", with: " ")
        if text.range(of: #"\b(?:2160p|4k|uhd)\b"#, options: .regularExpression) != nil {
            return 2160
        }
        if text.range(of: #"\b1080[pi]\b"#, options: .regularExpression) != nil {
            return 1080
        }
        if text.range(of: #"\b720p\b"#, options: .regularExpression) != nil {
            return 720
        }
        return 0
    }

    static func matches(title: TMDBTitle, episode: TMDBEpisode?, filename: String, context: String = "") -> Bool {
        let text = (context + "/" + filename).replacingOccurrences(of: "_", with: " ")
        // A combined/ranged episode file cannot safely map to one episode's resume identity.
        if text.range(
            of: #"(?i)(?:s\d+e\d+(?:[ ._-]*e\d+|[ ._-]*-[ ._-]*(?:e)?\d+)|\d+x\d+[ ._-]*-[ ._-]*\d+)"#,
            options: .regularExpression,
        ) != nil {
            return false
        }
        if title.kind == .tv {
            guard let episode,
                  let marker = episodeNumbers(in: text) ?? folderEpisode(filename: filename, context: context),
                  marker.season == episode.season_number, marker.episode == episode.episode_number else { return false }
        } else if episode != nil || episodeNumbers(in: text) != nil {
            return false
        }

        let tmdbIDs = captures(#"(?i)tmdb[\s:=_{\[-]+(\d+)"#, in: text, group: 1)
        if !tmdbIDs.isEmpty {
            return tmdbIDs.allSatisfy { $0 == String(title.id) }
        }
        let imdbIDs = captures(#"(?i)\btt\d{5,}\b"#, in: text, group: 0)
        if !imdbIDs.isEmpty, let expected = title.matchingIDs.imdb {
            return imdbIDs.allSatisfy { $0.lowercased() == expected.lowercased() }
        }
        let verifiedAliases = (title.alternative_titles?.titles ?? title.alternative_titles?.results ?? []).map(\.title)
        let aliases = ([title.displayTitle, title.original_title, title.original_name]
            .compactMap(\.self) + verifiedAliases)
            .map(normalized).filter { !$0.isEmpty }
        guard !aliases.isEmpty else { return false }
        let clean = normalized(AllDebridLibraryView.cleanTitle(filename))
        if title.kind == .movie {
            if nameMatches(clean, aliases: aliases, year: Int(title.date.prefix(4))) {
                return true
            }
            // Generic/hash file names need an exact title/year folder or magnet name, never a fuzzy substring.
            guard ["video", "movie", "film", "main", "feature"].contains(clean) ||
                clean.range(of: #"^[a-f0-9]{8,}$"#, options: .regularExpression) != nil else { return false }
            return context.components(separatedBy: "/").contains {
                nameMatches(
                    normalized(AllDebridLibraryView.cleanTitle($0 + ".mkv")),
                    aliases: aliases,
                    year: Int(title.date.prefix(4)),
                )
            }
        }
        func showPrefix(_ value: String) -> String {
            let clean = AllDebridLibraryView.cleanTitle(value + ".mkv").replacingOccurrences(
                of: #"(?i)[ ._-]*(?:s\d+(?:e\d+)?|\d+x\d+|season[ ._-]*\d+).*$"#, with: "", options: .regularExpression,
            )
            return normalized(clean)
        }
        let prefix = showPrefix((filename as NSString).deletingPathExtension)
        if nameMatches(prefix, aliases: aliases, year: Int(title.date.prefix(4))) {
            return true
        }
        let bareEpisode = filename.replacingOccurrences(of: "_", with: " ").range(
            of: #"(?i)^(?:s\d+e\d+|\d+x\d+|(?:episode|ep|e)[ .-]*\d+|\d{1,3}[ .-])"#,
            options: .regularExpression,
        ) != nil
        guard prefix.isEmpty || bareEpisode else { return false }
        return context.components(separatedBy: "/").contains {
            nameMatches(showPrefix($0), aliases: aliases, year: Int(title.date.prefix(4)))
        }
    }

    private static func nameMatches(_ candidate: String, aliases: [String], year: Int?) -> Bool {
        aliases.contains { alias in
            if candidate == alias {
                return true
            }
            guard candidate.hasPrefix(alias + " ") else { return false }
            let suffix = String(candidate.dropFirst(alias.count)).trimmingCharacters(in: .whitespaces)
            guard suffix.range(of: #"^(?:19|20)\d{2}$"#, options: .regularExpression) != nil else { return false }
            return year.map { String($0) == suffix } ?? true
        }
    }

    /// Episode-only files are eligible only with an explicit, unambiguous season folder/pack.
    private static func folderEpisode(filename: String, context: String) -> (season: Int, episode: Int)? {
        let seasons = captures(#"(?i)(?:\b|_)(?:season[ ._-]*|s)(\d{1,3})(?!\d)"#, in: context, group: 1)
            .compactMap(Int.init)
        guard let season = seasons.first, seasons.allSatisfy({ $0 == season }),
              let raw = capture(
                  #"(?i)^(?:episode|ep|e)?[ ._-]*(\d{1,3})(?=[ ._-]|\.[a-z0-9]+$)"#,
                  in: filename,
                  group: 1,
              ),
              let episode = Int(raw) else { return nil }
        return (season, episode)
    }

    static func episodeNumbers(in text: String) -> (season: Int, episode: Int)? {
        guard text.range(of: #"(?i)s\d+e\d+(?:[ ._-]*e\d+|-\d+)"#, options: .regularExpression) == nil
        else { return nil }
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

    private static func captures(_ pattern: String, in text: String, group: Int) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            guard let range = Range($0.range(at: group), in: text) else { return nil }
            return String(text[range])
        }
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
            .replacingOccurrences(of: "’", with: "").replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "&", with: " and ")
            .replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}
