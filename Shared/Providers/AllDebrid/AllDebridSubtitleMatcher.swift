import AetherEngine
import Foundation

enum AllDebridSubtitleMatcher {
    private static let supportedExtensions: Set<String> = ["srt", "ass", "ssa", "vtt"]
    private static let languageCodes = [
        "en": "eng", "eng": "eng", "english": "eng",
        "es": "spa", "spa": "spa", "spanish": "spa",
        "fr": "fre", "fre": "fre", "french": "fre",
    ]
    private static let ignoredTokens: Set<String> = [
        "2160p", "1080p", "720p", "4k", "web", "dl", "webdl", "webrip", "bluray", "blu", "ray", "remux",
        "x264", "x265", "h264", "h265", "hevc", "av1", "hdr", "hdr10", "dovi",
        "aac", "dts", "proper", "repack", "forced", "sdh", "hi", "cc",
    ]

    static func isSubtitleFile(_ filename: String) -> Bool {
        supportedExtensions.contains((filename as NSString).pathExtension.lowercased())
    }

    static func subtitles(for video: AllDebridMagnetFile, in files: [AllDebridMagnetFile]) -> [AllDebridMagnetFile] {
        let videoName = comparisonName(video.filename)
        let videoEpisode = episodeIdentifier(in: video.filename)
        let videoFolder = parentPath(of: video.fullPath)

        return files.compactMap { subtitle -> (file: AllDebridMagnetFile, score: Double, sameFolder: Bool)? in
            guard subtitle.magnetID == video.magnetID, subtitle.isSubtitle,
                  let url = URL(string: subtitle.link),
                  ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
                  url.host != nil else { return nil }

            let subtitleEpisode = episodeIdentifier(in: subtitle.filename)
            if let videoEpisode, let subtitleEpisode, videoEpisode != subtitleEpisode {
                return nil
            }

            let name = comparisonName(subtitle.filename)
            let score = filenameSimilarity(videoName, name)
            guard score >= 0.6 else { return nil }
            return (subtitle, score, parentPath(of: subtitle.fullPath) == videoFolder)
        }
        .sorted {
            if $0.score != $1.score {
                return $0.score > $1.score
            }
            if $0.sameFolder != $1.sameFolder {
                return $0.sameFolder
            }
            return $0.file.fullPath < $1.file.fullPath
        }
        .map(\.file)
    }

    static func language(in filename: String) -> String? {
        let stem = (filename as NSString).deletingPathExtension.lowercased()
        let tokens = stem.split { !$0.isLetter && !$0.isNumber }
        return tokens.lazy.compactMap { languageCodes[String($0)] }.first
    }

    static func externalTracks(
        for video: AllDebridMagnetFile,
        in files: [AllDebridMagnetFile],
    ) -> [ExternalSubtitleTrack] {
        subtitles(for: video, in: files).compactMap { subtitle in
            guard let url = URL(string: subtitle.link),
                  ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
                  url.host != nil else { return nil }
            let filename = subtitle.filename as NSString
            let tokens = filename.deletingPathExtension.lowercased()
                .split { !$0.isLetter && !$0.isNumber }
                .map(String.init)
            return ExternalSubtitleTrack(
                url: url,
                name: filename.deletingPathExtension,
                language: language(in: subtitle.filename),
                isForced: tokens.contains("forced"),
                isDefault: false,
                isHearingImpaired: tokens.contains { ["sdh", "hi", "cc"].contains($0) },
                formatHint: filename.pathExtension.lowercased(),
            )
        }
    }

    private static func comparisonName(_ filename: String) -> Set<String> {
        let stem = (filename as NSString).deletingPathExtension.lowercased()
        let tokens = stem.split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
        let withoutLanguage = tokens.filter { languageCodes[$0] == nil }
        let withoutEpisode = withoutLanguage.filter { !isEpisodeToken($0) }
        return Set(withoutEpisode.filter { !ignoredTokens.contains($0) })
    }

    private static func filenameSimilarity(_ lhs: Set<String>, _ rhs: Set<String>) -> Double {
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        let shared = lhs.intersection(rhs).count
        guard shared > 0 else { return 0 }
        return Double(shared) / Double(lhs.union(rhs).count)
    }

    private static func episodeIdentifier(in filename: String) -> String? {
        let stem = (filename as NSString).deletingPathExtension.lowercased()
        let patterns = [
            #"s\d{1,2}e\d{1,3}"#,
            #"\d{1,2}x\d{1,3}"#,
            #"episode[ ._-]*\d{1,3}"#,
        ]
        return patterns.lazy.compactMap { pattern in
            stem.range(of: pattern, options: .regularExpression).map { String(stem[$0]) }
        }.first
    }

    private static func isEpisodeToken(_ token: String) -> Bool {
        token.range(of: #"^(s\d{1,2}e\d{1,3}|\d{1,2}x\d{1,3}|episode\d{1,3})$"#, options: .regularExpression) != nil
    }

    private static func parentPath(of path: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        return parent == "." ? "" : parent.lowercased()
    }
}
