import Foundation
import Testing
@testable import Kaset

// MARK: - SpotlightLibraryIndexerTests

@Suite("Spotlight Library indexer", .serialized, .tags(.service))
@MainActor
struct SpotlightLibraryIndexerTests {
    /// Records replacements instead of touching the user's Spotlight index.
    private actor RecordingIndex: LibrarySpotlightIndex {
        private(set) var replacements: [(playlists: [String], albums: [String])] = []

        func replaceAll(playlists: [PlaylistEntity], albums: [AlbumEntity]) async throws {
            self.replacements.append((playlists.map(\.id), albums.map(\.id)))
        }
    }

    private func makeLibrary(playlistIDs: [String], albumIDs: [String] = []) -> AppIntentsLibrary {
        AppIntentsLibrary(
            playlists: playlistIDs.map { TestFixtures.makePlaylist(id: $0, title: $0) },
            albums: albumIDs.map { TestFixtures.makeAlbum(id: $0, title: $0) }
        )
    }

    @Test("Quick successive snapshots coalesce into one replacement with the latest")
    func coalescesUpdates() async {
        let index = RecordingIndex()
        let indexer = SpotlightLibraryIndexer(index: index, debounce: .milliseconds(30))

        indexer.update(self.makeLibrary(playlistIDs: ["PL-first"]))
        indexer.update(self.makeLibrary(playlistIDs: ["PL-first", "PL-second"], albumIDs: ["MPREb_album"]))
        await indexer.waitForPendingUpdate()

        let replacements = await index.replacements
        #expect(replacements.count == 1)
        #expect(replacements.first?.playlists == ["PL-first", "PL-second"])
        #expect(replacements.first?.albums == ["MPREb_album"])
    }

    @Test("An unchanged snapshot does not reindex")
    func skipsUnchangedLibrary() async {
        let index = RecordingIndex()
        let indexer = SpotlightLibraryIndexer(index: index, debounce: .milliseconds(10))
        let library = self.makeLibrary(playlistIDs: ["PL-same"])

        indexer.update(library)
        await indexer.waitForPendingUpdate()
        indexer.update(library)
        await indexer.waitForPendingUpdate()

        #expect(await index.replacements.count == 1)
    }

    @Test("Uploads and albums without a playable ID are not indexed")
    func indexesOnlyPlayableItems() async {
        let index = RecordingIndex()
        let indexer = SpotlightLibraryIndexer(index: index, debounce: .milliseconds(10))

        indexer.update(self.makeLibrary(
            playlistIDs: [Playlist.uploadedSongsBrowseID, "PL-kept"],
            albumIDs: ["MPREb_kept", UUID().uuidString]
        ))
        await indexer.waitForPendingUpdate()

        let replacement = await index.replacements.first
        #expect(replacement?.playlists == ["PL-kept"])
        #expect(replacement?.albums == ["MPREb_kept"])
    }

    @Test("Signing out clears the index")
    func emptyLibraryClearsIndex() async {
        let index = RecordingIndex()
        let indexer = SpotlightLibraryIndexer(index: index, debounce: .milliseconds(10))

        indexer.update(self.makeLibrary(playlistIDs: ["PL-signed-in"]))
        await indexer.waitForPendingUpdate()
        indexer.update(.empty)
        await indexer.waitForPendingUpdate()

        let replacements = await index.replacements
        #expect(replacements.count == 2)
        #expect(replacements.last?.playlists.isEmpty == true)
        #expect(replacements.last?.albums.isEmpty == true)
    }
}

// MARK: - AppIntentsEntityTests

@Suite("App Intents entities", .tags(.service))
@MainActor
struct AppIntentsEntityTests {
    @Test("A song entity carries the song's display metadata")
    func songEntityMapsSong() {
        let song = Song(
            id: "song-id",
            title: "Get Lucky",
            artists: [Artist(id: "UC1", name: "Daft Punk"), Artist(id: "UC2", name: "Pharrell Williams")],
            album: TestFixtures.makeAlbum(title: "Random Access Memories"),
            thumbnailURL: URL(string: "https://example.com/art.jpg"),
            videoId: "video-id"
        )

        let entity = SongEntity(song: song)

        #expect(entity.id == "video-id")
        #expect(entity.title == "Get Lucky")
        #expect(entity.artist == "Daft Punk, Pharrell Williams")
        #expect(entity.album == "Random Access Memories")
        #expect(entity.song.videoId == "video-id")
        #expect(entity.song.title == "Get Lucky")
    }

    @Test("Title matching ignores case, diacritics, and blank queries")
    func titleMatching() {
        #expect(AppIntentsSearch.title("Beyoncé Essentials", matches: "beyonce"))
        #expect(AppIntentsSearch.title("Road Trip", matches: "  TRIP "))
        #expect(!AppIntentsSearch.title("Road Trip", matches: "   "))
        #expect(!AppIntentsSearch.title("Road Trip", matches: "workout"))
    }

    @Test("Merging keeps preferred items first and drops duplicate IDs")
    func mergeDeduplicates() {
        let merged = AppIntentsSearch.merge(["a", "b"], ["b", "c", "a", "d"]) { $0 }
        #expect(merged == ["a", "b", "c", "d"])
    }
}
