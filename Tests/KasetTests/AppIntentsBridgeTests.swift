import Foundation
import Testing
@testable import Kaset

@Suite("App Intents bridge", .serialized, .tags(.service))
@MainActor
struct AppIntentsBridgeTests {
    /// Mutable flags the bridge reads through its closures.
    @MainActor
    private final class Environment {
        var isAuthInitializing = false
        var isSignedIn = false
        var acceptsTransport = true
        var transportPayloads: [RemoteMusicCommandPayload] = []
        var showMainWindowCount = 0
        var publishedLibraries: [AppIntentsLibrary] = []
    }

    init() {
        // Like requests run through the shared status manager; keep tests from leaking into each other.
        SongLikeStatusManager.shared.clearCache()
        SongLikeStatusManager.shared.setActiveAccountID(nil)
    }

    private func makeBridge(
        playerService: PlayerService = PlayerService(),
        client: MockYTMusicClient = MockYTMusicClient(),
        environment: Environment = Environment(),
        startupComplete: Bool = true
    ) -> AppIntentsBridge {
        let bridge = AppIntentsBridge()
        bridge.startupTimeout = .milliseconds(300)
        bridge.configure(
            playerService: playerService,
            client: client,
            isAuthInitializing: { environment.isAuthInitializing },
            hasPersonalAccount: { environment.isSignedIn },
            transportHandler: { payload in
                environment.transportPayloads.append(payload)
                return environment.acceptsTransport
            },
            libraryDidChange: { environment.publishedLibraries.append($0) }
        )
        bridge.setShowMainWindowHandler { environment.showMainWindowCount += 1 }
        if startupComplete {
            bridge.markStartupComplete()
        }
        return bridge
    }

    private func signedInPlayer() -> PlayerService {
        let authService = AuthService(webKitManager: MockWebKitManager())
        authService.completeLogin(sapisid: "test-sapisid")
        let player = PlayerService()
        player.setAuthService(authService)
        return player
    }

    private func resetSingletonPlayer() {
        SingletonPlayerWebView.shared.tearDown()
        SingletonPlayerWebView.shared.currentVideoId = nil
    }

    // MARK: - Readiness

    @Test("Not ready before configuration, startup, or while auth initializes")
    func readinessGate() {
        #expect(!AppIntentsBridge().isReady)

        let environment = Environment()
        let bridge = self.makeBridge(environment: environment, startupComplete: false)
        #expect(!bridge.isReady)

        bridge.markStartupComplete()
        #expect(bridge.isReady)

        environment.isAuthInitializing = true
        #expect(!bridge.isReady)
    }

    @Test("Waiting returns once startup completes")
    func waitResumesWhenStartupCompletes() async {
        let bridge = self.makeBridge(startupComplete: false)
        // Generous: the full suite runs many async tests concurrently.
        bridge.startupTimeout = .seconds(10)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            bridge.markStartupComplete()
        }

        #expect(await bridge.waitUntilReady())
        #expect(bridge.isReady)
    }

    @Test("Waiting gives up after the startup timeout")
    func waitTimesOut() async {
        let bridge = self.makeBridge(startupComplete: false)
        #expect(await !bridge.waitUntilReady())
    }

    // MARK: - Transport

    @Test("Transport commands report nothing playing before startup completes")
    func transportBeforeStartup() {
        let environment = Environment()
        let bridge = self.makeBridge(environment: environment, startupComplete: false)

        #expect(throws: AppIntentsError.nothingPlaying) {
            try bridge.sendTransportCommand(.pause)
        }
        #expect(environment.transportPayloads.isEmpty)
    }

    @Test("Transport commands go through the media-key handler")
    func transportUsesHandler() throws {
        let environment = Environment()
        let bridge = self.makeBridge(environment: environment)

        try bridge.sendTransportCommand(.togglePlayPause)
        try bridge.sendTransportCommand(.trackNavigation(direction: .forward))

        #expect(environment.transportPayloads == [.togglePlayPause, .trackNavigation(direction: .forward)])
    }

    @Test("A transport handler that cannot route reports nothing playing")
    func transportHandlerRejects() {
        let environment = Environment()
        environment.acceptsTransport = false
        let bridge = self.makeBridge(environment: environment)

        #expect(throws: AppIntentsError.nothingPlaying) {
            try bridge.sendTransportCommand(.play)
        }
    }

    // MARK: - Rating

    @Test("Rating without a current track reports nothing playing")
    func ratingWithoutTrack() {
        let bridge = self.makeBridge(playerService: self.signedInPlayer())

        #expect(throws: AppIntentsError.nothingPlaying) {
            try bridge.rateCurrentSong(.like)
        }
    }

    @Test("Rating requires a personal account")
    func ratingRequiresSignIn() {
        let player = PlayerService()
        player.currentTrack = TestFixtures.makeSong(id: "guest-track")
        let bridge = self.makeBridge(playerService: player)

        #expect(throws: AppIntentsError.signInRequired) {
            try bridge.rateCurrentSong(.like)
        }
    }

    @Test("Liking an already-liked song leaves it liked")
    func likeIsIdempotent() throws {
        let player = self.signedInPlayer()
        player.currentTrack = TestFixtures.makeSong(id: "liked-track")
        player.currentTrackLikeStatus = .like
        let bridge = self.makeBridge(playerService: player)

        let song = try bridge.rateCurrentSong(.like)

        #expect(song.videoId == "liked-track")
        #expect(player.currentTrackLikeStatus == .like)
    }

    @Test("Liking an unrated song likes it, and disliking replaces the like")
    func ratingSetsRequestedStatus() throws {
        let player = self.signedInPlayer()
        player.currentTrack = TestFixtures.makeSong(id: "rated-track")
        player.currentTrackLikeStatus = .indifferent
        let bridge = self.makeBridge(playerService: player)

        try bridge.rateCurrentSong(.like)
        #expect(player.currentTrackLikeStatus == .like)

        try bridge.rateCurrentSong(.dislike)
        #expect(player.currentTrackLikeStatus == .dislike)
    }

    // MARK: - Playback

    @Test("The best song is the first playable result")
    func bestSongSkipsUnplayable() {
        let unplayable = Song(id: "blocked", title: "Blocked", artists: [], videoId: "blocked", isPlayable: false)
        let playable = TestFixtures.makeSong(id: "playable")

        #expect(AppIntentsBridge.bestSong(in: [unplayable, playable])?.videoId == "playable")
        #expect(AppIntentsBridge.bestSong(in: [unplayable]) == nil)
    }

    @Test("Playing a search result shows the window and plays the best match")
    func playSearchResultPlaysBestMatch() async throws {
        self.resetSingletonPlayer()
        defer { self.resetSingletonPlayer() }
        let client = MockYTMusicClient()
        let match = TestFixtures.makeSong(id: "match", title: "Get Lucky")
        client.songsSearchResponse = SearchResponse(songs: [match])
        let player = PlayerService()
        player.setYTMusicClient(client)
        let environment = Environment()
        let bridge = self.makeBridge(playerService: player, client: client, environment: environment)

        let song = try await bridge.playSearchResult(for: "  get lucky  ")

        #expect(song.videoId == "match")
        #expect(client.searchQueries.last == "get lucky")
        #expect(environment.showMainWindowCount == 1)
        #expect(player.currentTrack?.videoId == "match")
    }

    @Test("A search with nothing playable reports no results")
    func playSearchResultWithoutMatches() async {
        let client = MockYTMusicClient()
        client.songsSearchResponse = .empty
        let bridge = self.makeBridge(client: client)

        await #expect(throws: AppIntentsError.noResults(query: "nothing")) {
            try await bridge.playSearchResult(for: "nothing")
        }
    }

    @Test("A blank query reports no results without searching")
    func playSearchResultWithBlankQuery() async {
        let client = MockYTMusicClient()
        let bridge = self.makeBridge(client: client)

        await #expect(throws: AppIntentsError.noResults(query: "   ")) {
            try await bridge.playSearchResult(for: "   ")
        }
        #expect(client.searchQueries.isEmpty)
    }

    @Test("Playback fails with not ready when a cold launch does not finish startup")
    func playbackTimesOutBeforeStartup() async {
        let environment = Environment()
        let bridge = self.makeBridge(environment: environment, startupComplete: false)

        await #expect(throws: AppIntentsError.notReady) {
            try await bridge.play(song: TestFixtures.makeSong(id: "cold"))
        }
        #expect(environment.showMainWindowCount == 0)
    }

    @Test("Liked Music requires a personal account and does not bring the window forward")
    func likedMusicRequiresSignIn() async {
        let environment = Environment()
        let bridge = self.makeBridge(environment: environment)

        await #expect(throws: AppIntentsError.signInRequired) {
            try await bridge.play(playlist: LikedMusicPlaylist.playlist)
        }
        #expect(environment.showMainWindowCount == 0)
    }

    // MARK: - Library

    @Test("Library changes are published once per distinct snapshot")
    func libraryPublishesChanges() {
        let environment = Environment()
        let bridge = self.makeBridge(environment: environment)
        let library = AppIntentsLibrary(playlists: [TestFixtures.makePlaylist()], albums: [])

        // The first snapshot always publishes, even when empty, so a stale index gets cleared.
        bridge.updateLibrary(.empty)
        bridge.updateLibrary(library)
        bridge.updateLibrary(library)

        #expect(environment.publishedLibraries == [.empty, library])
        #expect(bridge.library == library)
    }

    @Test("Only playable Library items are offered")
    func libraryFiltersUnplayableItems() {
        let uploads = TestFixtures.makePlaylist(id: Playlist.uploadedSongsBrowseID, title: "Uploads")
        let playlist = TestFixtures.makePlaylist(id: "PL-mix", title: "Mix")
        let album = TestFixtures.makeAlbum(id: "MPREb_album")
        let inlineAlbum = TestFixtures.makeAlbum(id: UUID().uuidString)
        let library = AppIntentsLibrary(playlists: [uploads, playlist], albums: [album, inlineAlbum])

        #expect(library.playablePlaylists.map(\.id) == ["PL-mix"])
        #expect(library.playableAlbums.map(\.id) == ["MPREb_album"])
    }
}
