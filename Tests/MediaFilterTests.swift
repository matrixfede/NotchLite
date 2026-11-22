import Foundation

private func makeCandidate(
    clientKey: String? = nil,
    pid: Int32 = 100,
    bundleID: String?,
    rawBundleID: String? = nil,
    appName: String = "",
    title: String = "Track",
    artist: String = "Artist",
    duration: Double = 180,
    isPlaying: Bool = false,
    lastPlayingDate: Date? = nil,
    mediaType: String? = nil,
    isMusicApp: Bool = false,
    isGlobal: Bool = false,
    artworkKey: String? = "art"
) -> MediaCandidate {
    MediaCandidate(
        clientKey: clientKey ?? "\(pid)|\(rawBundleID ?? bundleID ?? "")",
        pid: pid,
        bundleID: bundleID,
        rawBundleID: rawBundleID ?? bundleID,
        appName: appName,
        title: title,
        artist: artist,
        album: "",
        duration: duration,
        elapsed: 0,
        timestamp: Date(timeIntervalSince1970: 1_700_000_000),
        rate: isPlaying ? 1 : 0,
        isPlaying: isPlaying,
        lastPlayingDate: lastPlayingDate,
        mediaType: mediaType,
        isMusicApp: isMusicApp,
        isGlobal: isGlobal,
        artworkKey: artworkKey
    )
}

@main
struct MediaFilterTests {
    @MainActor static func main() {
        let now = Date(timeIntervalSince1970: 1_700_000_100)
        let earlier = Date(timeIntervalSince1970: 1_700_000_000)

        // 1. Classification of dedicated music apps, music PWAs, browsers, video and social apps.
        let ytmApp = makeCandidate(pid: 10840, bundleID: "-xjemm.youtube-music-player", appName: "YouTube Music", title: "You Had Me", artist: "Joss Stone", isPlaying: true, lastPlayingDate: now)
        let ytmPWA = makeCandidate(pid: 10900, bundleID: "com.google.Chrome.app.cinhimbnkkaeohfgghhklpknlkffjgod", appName: "YouTube Music", title: "Song", artist: "Artist")
        let safariPWA = makeCandidate(pid: 10901, bundleID: "com.apple.Safari.WebApp.12345", appName: "Spotify", title: "Song", artist: "Artist")
        let spotify = makeCandidate(pid: 10902, bundleID: "com.spotify.client", appName: "Spotify", title: "Song", artist: "Artist")
        let appleMusic = makeCandidate(pid: 10903, bundleID: "com.apple.Music", appName: "Music", title: "Song", artist: "Artist", isMusicApp: true)
        let chromeX = makeCandidate(pid: 17060, bundleID: "com.google.Chrome", appName: "Google Chrome", title: "AI Video Post on X", artist: "TechVerser", isPlaying: true, lastPlayingDate: now, isGlobal: true)
        let braveX = makeCandidate(pid: 17061, bundleID: "com.brave.Browser", appName: "Brave Browser", title: "X Clip", artist: "handle", isPlaying: true)
        let cometX = makeCandidate(pid: 17062, bundleID: "ai.perplexity.comet", appName: "Comet", title: "X Clip", artist: "handle", isPlaying: true)
        let primeVideo = makeCandidate(pid: 17063, bundleID: "com.amazon.aiv.AIVApp", appName: "Prime Video", title: "Episode 1", isPlaying: true)
        let telegram = makeCandidate(pid: 17064, bundleID: "ru.keepcoder.Telegram", appName: "Telegram", title: "Voice Note", isPlaying: true)
        let genericWebApp = makeCandidate(pid: 17065, bundleID: "com.google.Chrome.app.aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", appName: "X", title: "Video", isPlaying: true)

        precondition(MediaFilter.classify(ytmApp) == .music)
        precondition(MediaFilter.classify(ytmPWA) == .music)
        precondition(MediaFilter.classify(safariPWA) == .music)
        precondition(MediaFilter.classify(spotify) == .music)
        precondition(MediaFilter.classify(appleMusic) == .music)
        precondition(MediaFilter.classify(chromeX) == .other)
        precondition(MediaFilter.classify(braveX) == .other)
        precondition(MediaFilter.classify(cometX) == .other)
        precondition(MediaFilter.classify(primeVideo) == .other)
        precondition(MediaFilter.classify(telegram) == .other)
        precondition(MediaFilter.classify(genericWebApp) == .other)

        // 2. Deduplication prefers the client with real timeline (e.g. WebKit GPU owning
        //    <audio> duration/elapsed) while inheriting missing artwork from the host process.
        let ytmHostNoTimeline = makeCandidate(pid: 10840, bundleID: "-xjemm.youtube-music-player", rawBundleID: "-xjemm.youtube-music-player", appName: "YouTube Music", title: "Spoiled", artist: "Joss Stone", duration: 0, isPlaying: true, lastPlayingDate: now, artworkKey: "cover-key")
        let ytmGPUWithTimeline = makeCandidate(pid: 20726, bundleID: "-xjemm.youtube-music-player", rawBundleID: "com.apple.WebKit.GPU", appName: "YouTube Music", title: "Spoiled", artist: "Joss Stone", duration: 240, isPlaying: true, lastPlayingDate: now, isGlobal: true, artworkKey: nil)
        let deduped = MediaFilter.deduplicate([ytmHostNoTimeline, ytmGPUWithTimeline])
        precondition(deduped.count == 1 && deduped.first?.pid == 20726 && deduped.first?.duration == 240 && deduped.first?.artworkKey == "cover-key")

        // 3. musicOnly = true: playing video on X never hijacks paused or playing YouTube Music.
        let ytmPaused = makeCandidate(pid: 10840, bundleID: "-xjemm.youtube-music-player", appName: "YouTube Music", title: "You Had Me", artist: "Joss Stone", isPlaying: false, lastPlayingDate: earlier)
        let chosenMusicOnly = MediaFilter.select(from: [ytmPaused, chromeX], musicOnly: true)
        precondition(chosenMusicOnly?.pid == 10840)

        // When only Chrome X exists in musicOnly mode, nothing is shown.
        precondition(MediaFilter.select(from: [chromeX], musicOnly: true) == nil)

        // 4. musicOnly = false:
        //    - While X video plays and YouTube Music is paused, X video shows.
        let chosenAllWhileXPlays = MediaFilter.select(from: [ytmPaused, chromeX], musicOnly: false)
        precondition(chosenAllWhileXPlays?.pid == 17060)

        //    - The moment X video is stopped/paused, selection snaps back to YouTube Music
        //      even if Chrome is still the global macOS Now Playing app with a newer timestamp.
        let chromeXPaused = makeCandidate(pid: 17060, bundleID: "com.google.Chrome", appName: "Google Chrome", title: "AI Video Post on X", artist: "TechVerser", isPlaying: false, lastPlayingDate: now, isGlobal: true)
        let chosenAllAfterXStops = MediaFilter.select(from: [ytmPaused, chromeXPaused], musicOnly: false)
        precondition(chosenAllAfterXStops?.pid == 10840)

        //    - If YouTube Music is playing AND X video is playing, music wins.
        let chosenBothPlaying = MediaFilter.select(from: [ytmApp, chromeX], musicOnly: false)
        precondition(chosenBothPlaying?.pid == 10840)

        // 5. Two paused music apps: most recently played wins.
        let spotifyPaused = makeCandidate(pid: 10902, bundleID: "com.spotify.client", appName: "Spotify", title: "Recent Song", isPlaying: false, lastPlayingDate: now)
        let chosenRecentPaused = MediaFilter.select(from: [ytmPaused, spotifyPaused], musicOnly: true)
        precondition(chosenRecentPaused?.pid == 10902)

        // 6. Settings.musicOnly defaults to true and persists.
        let suite = "NotchLiteMediaTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = Settings(defaults: defaults)
        precondition(settings.musicOnly == true)
        settings.musicOnly = false
        precondition(Settings(defaults: defaults).musicOnly == false)

        // 7. isMusicSource filters stale non-music stored lastTrack entries.
        precondition(MediaFilter.isMusicSource(bundleID: "-xjemm.youtube-music-player", appName: "YouTube Music"))
        precondition(MediaFilter.isMusicSource(bundleID: "com.google.Chrome.app.cinhimbnkkaeohfgghhklpknlkffjgod", appName: "YouTube Music"))
        precondition(!MediaFilter.isMusicSource(bundleID: "com.google.Chrome", appName: "Google Chrome"))

        print("Media filter and selection checks passed")
    }
}
