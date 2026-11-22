import Foundation

enum MediaCategory: Equatable {
    case music
    case other
}

struct MediaCandidate: Equatable {
    var clientKey: String
    var pid: Int32
    var bundleID: String?
    var rawBundleID: String?
    var appName: String
    var title: String
    var artist: String
    var album: String
    var duration: Double
    var elapsed: Double
    var timestamp: Date
    var rate: Double
    var isPlaying: Bool
    var lastPlayingDate: Date?
    var mediaType: String?
    var isMusicApp: Bool
    var isGlobal: Bool
    var artworkKey: String?
}

/// Distinguishes dedicated music/audio apps from browsers, social media, and
/// video players, and picks the best active media client across all macOS
/// Now Playing clients.
enum MediaFilter {
    private static let knownMusicBundleIDs: Set<String> = [
        "com.apple.music",
        "com.apple.itunes",
        "com.apple.podcasts",
        "com.spotify.client",
        "-xjemm.youtube-music-player",
        "com.github.th-ch.youtube-music",
        "com.th-ch.youtube-music",
        "app.ytmdesktop.ytmdesktop",
        "ytmdesktop",
        "com.tidal.desktop",
        "com.deezer.deezer-desktop",
        "com.qobuz.qobuz",
        "com.amazon.music",
        "com.soundcloud.desktop",
        "com.plexapp.plexamp",
        "tv.plex.plexamp",
        "sh.cider.cider",
        "com.ciderapp.cider",
        "com.coppertino.vox",
        "com.swinsian.swinsian",
        "com.brushedtype.doppler-macos",
        "com.audirvana.audirvana",
        "com.audirvana.audirvana-origin",
        "com.audirvana.audirvana-studio",
        "com.roon.roon",
        "com.sonos.maccontroller",
        "com.sonos.maccontroller2",
        "org.cogx.cog",
        "org.strawberrymusicplayer.strawberry",
        "org.clementine-player.clementine",
        "com.netease.163music",
        "com.foobar2000.mac",
        "com.bandcamp.bandcamp",
        "com.pandora.desktop",
        "com.overcastfm.overcast",
        "au.com.shiftyjelly.podcasts",
    ]

    /// Known Chromium PWA app IDs for music services (e.g. YouTube Music).
    private static let knownMusicPWASuffixes: [String] = [
        ".app.cinhimbnkkaeohfgghhklpknlkffjgod", // YouTube Music PWA
    ]

    private static let knownNonMusicBundleIDs: Set<String> = [
        // Browsers
        "com.google.chrome",
        "com.google.chrome.canary",
        "com.google.chrome.beta",
        "com.google.chrome.dev",
        "com.brave.browser",
        "com.brave.browser.nightly",
        "com.brave.browser.beta",
        "com.apple.safari",
        "com.apple.safaritechnologypreview",
        "org.mozilla.firefox",
        "org.mozilla.firefoxdeveloperedition",
        "org.mozilla.nightly",
        "app.zen-browser.zen",
        "company.thebrowser.browser",
        "company.thebrowser.dia",
        "ai.perplexity.comet",
        "com.perplexity.comet",
        "com.microsoft.edgemac",
        "com.microsoft.edgemac.canary",
        "com.microsoft.edgemac.beta",
        "com.operasoftware.opera",
        "com.operasoftware.operagx",
        "com.vivaldi.vivaldi",
        "com.kagi.kagimacos",
        "com.sigmaos.sigmaos.macos",
        "org.torproject.torbrowser",
        "com.apple.webkit.gpu",
        "com.apple.webkit.webcontent",
        // Video & streaming players
        "com.apple.quicktimeplayerx",
        "com.apple.tv",
        "com.apple.preview",
        "com.apple.imovieapp",
        "com.apple.finalcut",
        "org.videolan.vlc",
        "com.colliderli.iina",
        "io.mpv",
        "com.elmedia.elmediaplayer",
        "com.firecore.infuse",
        "com.amazon.aiv.aivapp",
        "com.netflix.netflix",
        "tv.twitch.studio",
        // Messaging, social, calls
        "ru.keepcoder.telegram",
        "org.telegram.desktop",
        "net.whatsapp.whatsapp",
        "desktop.whatsapp",
        "com.hnc.discord",
        "us.zoom.xos",
        "com.microsoft.teams2",
        "com.tinyspeck.slackmacgap",
        "com.apple.facetime",
        "com.apple.mobilesms",
        "com.atebits.tweetie2",
        "maccatalyst.com.atebits.tweetie2",
    ]

    private static let musicKeywords: [String] = [
        "youtube music",
        "yt music",
        "ytmusic",
        "youtube-music",
        "spotify",
        "apple music",
        "soundcloud",
        "tidal",
        "deezer",
        "qobuz",
        "bandcamp",
        "amazon music",
        "plexamp",
        "pandora",
        "audiomack",
        "mixcloud",
        "pocket casts",
        "overcast",
        "tunein",
        "music",
        "podcast",
        "radio",
    ]

    private static let videoKeywords: [String] = [
        "video",
        "movie",
        "cinema",
        "tv",
    ]

    static func classify(_ candidate: MediaCandidate) -> MediaCategory {
        let mtype = (candidate.mediaType ?? "").lowercased()
        if mtype.contains("video") { return .other }

        if let category = classifyApp(bundleID: candidate.bundleID, appName: candidate.appName) {
            return category
        }

        if candidate.isMusicApp || mtype.contains("music") || mtype.contains("audio") {
            return .music
        }

        return matchesMusicHeuristic(bundleID: candidate.bundleID, appName: candidate.appName) ? .music : .other
    }

    static func isMusicSource(bundleID: String?, appName: String = "") -> Bool {
        if let category = classifyApp(bundleID: bundleID, appName: appName) {
            return category == .music
        }
        return matchesMusicHeuristic(bundleID: bundleID, appName: appName)
    }

    private static func classifyApp(bundleID: String?, appName: String) -> MediaCategory? {
        let bid = (bundleID ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let name = appName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if !bid.isEmpty {
            if knownMusicBundleIDs.contains(bid) { return .music }

            // Browser-hosted PWAs / Safari Web Apps are classified by their PWA ID or app name
            // rather than treated as generic browser tabs.
            if isWebApp(bundleID: bid) {
                if knownMusicPWASuffixes.contains(where: { bid.hasSuffix($0) }) { return .music }
                return matchesMusicHeuristic(bundleID: nil, appName: name) ? .music : .other
            }

            if knownNonMusicBundleIDs.contains(bid) { return .other }

            // Helper processes of known browsers (e.g. com.google.Chrome.helper)
            if knownNonMusicBundleIDs.contains(where: { bid.hasPrefix($0 + ".") }) {
                return .other
            }
        }
        return nil
    }

    private static func isWebApp(bundleID: String) -> Bool {
        bundleID.contains(".app.") || bundleID.hasPrefix("com.apple.safari.webapp.")
    }

    private static func matchesMusicHeuristic(bundleID: String?, appName: String) -> Bool {
        let haystack = [bundleID ?? "", appName].joined(separator: " ").lowercased()
        guard !haystack.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if videoKeywords.contains(where: { haystack.contains($0) }) { return false }
        return musicKeywords.contains(where: { haystack.contains($0) })
    }

    /// Merges helper clients (e.g. com.apple.WebKit.GPU) that share an effective
    /// app bundle ID with their host app, preferring the client with the active
    /// playback timeline (duration/elapsed) and inheriting any missing metadata
    /// such as artwork from its sibling.
    static func deduplicate(_ candidates: [MediaCandidate]) -> [MediaCandidate] {
        var bestByKey: [String: MediaCandidate] = [:]
        var order: [String] = []

        for candidate in candidates {
            let groupKey: String
            if let bid = candidate.bundleID?.trimmingCharacters(in: .whitespacesAndNewlines), !bid.isEmpty {
                groupKey = "bid:" + bid.lowercased()
            } else {
                groupKey = "key:" + candidate.clientKey
            }

            if let existing = bestByKey[groupKey] {
                if isBetterDuplicate(candidate, than: existing) {
                    bestByKey[groupKey] = mergeMissingMetadata(into: candidate, from: existing)
                } else {
                    bestByKey[groupKey] = mergeMissingMetadata(into: existing, from: candidate)
                }
            } else {
                bestByKey[groupKey] = candidate
                order.append(groupKey)
            }
        }

        return order.compactMap { bestByKey[$0] }
    }

    private static func mergeMissingMetadata(into primary: MediaCandidate, from secondary: MediaCandidate) -> MediaCandidate {
        var merged = primary
        if merged.artworkKey == nil { merged.artworkKey = secondary.artworkKey }
        if merged.artist.isEmpty { merged.artist = secondary.artist }
        if merged.album.isEmpty { merged.album = secondary.album }
        if merged.duration <= 0, secondary.duration > 0 {
            merged.duration = secondary.duration
            merged.elapsed = secondary.elapsed
        }
        if merged.lastPlayingDate == nil { merged.lastPlayingDate = secondary.lastPlayingDate }
        if !merged.isGlobal && secondary.isGlobal { merged.isGlobal = true }
        return merged
    }

    private static func isBetterDuplicate(_ lhs: MediaCandidate, than rhs: MediaCandidate) -> Bool {
        if lhs.isPlaying != rhs.isPlaying { return lhs.isPlaying }
        let lhsHasDuration = lhs.duration > 0
        let rhsHasDuration = rhs.duration > 0
        if lhsHasDuration != rhsHasDuration { return lhsHasDuration }
        if lhs.isGlobal != rhs.isGlobal { return lhs.isGlobal }
        let lhsHasArt = lhs.artworkKey != nil
        let rhsHasArt = rhs.artworkKey != nil
        if lhsHasArt != rhsHasArt { return lhsHasArt }
        let lhsPrimary = isPrimaryProcess(lhs)
        let rhsPrimary = isPrimaryProcess(rhs)
        if lhsPrimary != rhsPrimary { return lhsPrimary }
        let lhsDate = lhs.lastPlayingDate ?? lhs.timestamp
        let rhsDate = rhs.lastPlayingDate ?? rhs.timestamp
        return lhsDate > rhsDate
    }

    private static func isPrimaryProcess(_ candidate: MediaCandidate) -> Bool {
        guard let bid = candidate.bundleID?.lowercased(), !bid.isEmpty else { return true }
        guard let raw = candidate.rawBundleID?.lowercased(), !raw.isEmpty else { return true }
        return raw == bid
    }

    /// Selects the active media track to show in the notch.
    /// - When `musicOnly` is true, non-music clients (browsers, video players, social apps)
    ///   are excluded completely.
    /// - When `musicOnly` is false, playing music still beats playing non-music, and paused
    ///   music beats paused non-music (so stopping a video immediately returns to the music app).
    static func select(from candidates: [MediaCandidate], musicOnly: Bool) -> MediaCandidate? {
        let unique = deduplicate(candidates).filter { !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let eligible = musicOnly ? unique.filter { classify($0) == .music } : unique
        return eligible.max(by: { rank($0) < rank($1) })
    }

    private static func rank(_ candidate: MediaCandidate) -> (Int, Double, Int, Double, Int32) {
        let isMusic = classify(candidate) == .music
        let tier: Int
        switch (isMusic, candidate.isPlaying) {
        case (true, true): tier = 3
        case (false, true): tier = 2
        case (true, false): tier = 1
        case (false, false): tier = 0
        }
        let recency = candidate.lastPlayingDate?.timeIntervalSince1970 ?? 0
        let globalBoost = candidate.isGlobal ? 1 : 0
        let updated = candidate.timestamp.timeIntervalSince1970
        return (tier, recency, globalBoost, updated, candidate.pid)
    }
}
