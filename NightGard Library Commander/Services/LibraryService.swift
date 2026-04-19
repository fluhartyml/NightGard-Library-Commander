//
//  LibraryService.swift
//  NightGard Library Commander
//
//  Wraps MusicKit for cross-platform work, falls back to AppleScript
//  on macOS for fields MusicKit doesn't expose (cloud status, per-track
//  metadata gap queries).
//

import Foundation
import SwiftUI
import MusicKit
#if os(macOS)
import AppKit
#endif

@Observable
@MainActor
final class LibraryService {

    var authorizationStatus: MusicAuthorization.Status = .notDetermined
    var playlists: [Playlist] = []
    var stats: LibraryStats = .empty
    var uploadedTracks: [UploadedTrackRow] = []
    var uploadedTracksTotal: Int = 0
    var isWorking = false
    var statusMessage = ""

    // Scan state (Apple Music Scan / Shazam Scan)
    var scanState: ScanState = .idle
    var scanCancelRequested = false
    private var activeMediaFolderAccess: URL?

    // MARK: - Authorization

    func authorize() async {
        authorizationStatus = await MusicAuthorization.request()
    }

    // MARK: - Playlists (MusicKit, cross-platform)

    func refreshPlaylists() async {
        guard authorizationStatus == .authorized else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            var request = MusicLibraryRequest<Playlist>()
            request.limit = 500
            let response = try await request.response()
            playlists = Array(response.items)
        } catch {
            statusMessage = "Playlists error: \(error.localizedDescription)"
        }
    }

    func deletePlaylist(_ playlist: Playlist) async {
        #if os(macOS)
        let name = playlist.name.replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Music"
            try
                delete (first user playlist whose name is "\(name)")
                return "ok"
            on error errMsg
                return "err: " & errMsg
            end try
        end tell
        """
        _ = runAppleScript(script)
        await refreshPlaylists()
        #else
        statusMessage = "Delete requires macOS for v1"
        #endif
    }

    func renamePlaylist(oldName: String, newName: String) async {
        #if os(macOS)
        let safeOld = oldName.replacingOccurrences(of: "\"", with: "\\\"")
        let safeNew = newName.replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Music"
            try
                set name of (first user playlist whose name is "\(safeOld)") to "\(safeNew)"
                return "ok"
            on error errMsg
                return "err: " & errMsg
            end try
        end tell
        """
        let result = runAppleScript(script) ?? ""
        if result.hasPrefix("err") {
            statusMessage = result
        }
        await refreshPlaylists()
        #else
        statusMessage = "Rename requires macOS for v1"
        #endif
    }

    // MARK: - Stats

    func refreshStats() async {
        isWorking = true
        defer { isWorking = false }
        #if os(macOS)
        stats = runAppleScriptStats()
        #else
        stats = LibraryStats(
            totalTracks: 0,
            totalPlaylists: playlists.count,
            matched: 0, purchased: 0, uploaded: 0, subscription: 0,
            missingArtist: 0, missingAlbum: 0, missingGenre: 0,
            macOnly: true
        )
        #endif
    }

    // MARK: - Uploaded Tracks (macOS only for v1)

    func refreshUploadedTracks() async {
        isWorking = true
        defer { isWorking = false }
        #if os(macOS)
        uploadedTracks = runAppleScriptUploadedTracks()
        #else
        uploadedTracks = []
        #endif
    }

    // MARK: - Scan Buttons (port pending from NightGard Commander)

    /// Apple Music text search pass. Copy-clean-delete-reimport workflow:
    /// 1. For each candidate track, iTunes Search → if trusted match:
    ///    a. Write Apple's canonical metadata onto the library track (Music writes through to the file)
    ///    b. Copy the file to the holding folder renamed "{Artist} {Album} {Track Title}.mp3"
    ///    c. Delete the original track from the library
    /// 2. After all tracks processed, create playlist "Cleaned NightGard Library Commander"
    ///    and add every file from the holding folder — Apple's matching picks up the clean
    ///    metadata on re-import.
    func runAppleMusicScan() async {
        isWorking = true
        scanCancelRequested = false
        defer {
            isWorking = false
            #if os(macOS)
            releaseMediaFolderAccess()
            #endif
        }

        #if os(macOS)
        let holdingFolder: URL
        do {
            holdingFolder = try createHoldingFolder()
        } catch {
            statusMessage = "Could not create holding folder: \(error.localizedDescription)"
            scanState = .complete(kind: "Apple Music Scan", processed: 0, total: 0, matched: 0, failed: 0, skipped: 0, needsDownload: 0, cancelled: false)
            return
        }
        NSLog("NightGard: holding folder = %@", holdingFolder.path)
        #endif

        scanState = .scanning(
            kind: "Apple Music Scan",
            currentTrack: "Loading full candidate list…",
            processed: 0,
            total: uploadedTracksTotal,
            matched: 0, failed: 0, skipped: 0, needsDownload: 0
        )
        let candidates = fetchAllCandidateTracks()
        let total = candidates.count
        guard total > 0 else {
            scanState = .complete(kind: "Apple Music Scan", processed: 0, total: 0, matched: 0, failed: 0, skipped: 0, needsDownload: 0, cancelled: false)
            return
        }

        var matched = 0, failed = 0, skipped = 0, needsDownload = 0
        for (index, track) in candidates.enumerated() {
            if scanCancelRequested { break }

            scanState = .scanning(
                kind: "Apple Music Scan",
                currentTrack: "\(track.artist) — \(track.title)",
                processed: index,
                total: total,
                matched: matched,
                failed: failed,
                skipped: skipped,
                needsDownload: needsDownload
            )

            // Skip if we have no search anchor (both artist and title empty).
            guard !track.artist.isEmpty || !track.title.isEmpty else {
                skipped += 1
                continue
            }

            #if os(macOS)
            // Cheap check FIRST: does this track even have a local file? iCloud-only
            // tracks return empty location → skip without hitting iTunes at all.
            guard let sourceURL = trackLocation(persistentID: track.persistentID) else {
                needsDownload += 1
                continue
            }
            #endif

            // Be polite to iTunes Search API: ~3 req/sec ceiling.
            try? await Task.sleep(nanoseconds: 350_000_000)

            guard let hit = await iTunesSearch(artist: track.artist, title: track.title),
                  matchIsTrustworthy(query: track.artist, title: track.title, hit: hit) else {
                failed += 1
                continue
            }

            #if os(macOS)
            // 1a. Write Apple's canonical metadata to the live library track — Music
            //     writes these through to the underlying audio file.
            writeBack(persistentID: track.persistentID, hit: hit)
            // 1b. Copy the file into the holding folder with canonical name.
            let filename = canonicalFilename(hit: hit, sourceExtension: sourceURL.pathExtension)
            let destURL = holdingFolder.appendingPathComponent(filename)
            do {
                if !FileManager.default.fileExists(atPath: destURL.path) {
                    try FileManager.default.copyItem(at: sourceURL, to: destURL)
                }
            } catch {
                NSLog("NightGard: copy failed for %@: %@", sourceURL.path, "\(error)")
                failed += 1
                continue
            }
            // 1c. Remove the original track (and its file) from the library.
            deleteTrackFromLibrary(persistentID: track.persistentID)
            #endif
            matched += 1
        }

        // 2. Post-scan: create the cleaned playlist and re-import every holding file.
        #if os(macOS)
        if matched > 0 && !scanCancelRequested {
            let playlistName = "Cleaned NightGard Library Commander"
            scanState = .scanning(
                kind: "Apple Music Scan",
                currentTrack: "Creating playlist \(playlistName)…",
                processed: total,
                total: total,
                matched: matched,
                failed: failed,
                skipped: skipped,
                needsDownload: needsDownload
            )
            createPlaylistIfNeeded(name: playlistName)

            scanState = .scanning(
                kind: "Apple Music Scan",
                currentTrack: "Re-importing cleaned files into \(playlistName)…",
                processed: total,
                total: total,
                matched: matched,
                failed: failed,
                skipped: skipped,
                needsDownload: needsDownload
            )
            addFilesInFolderToPlaylist(folder: holdingFolder, playlist: playlistName)
        }
        #endif

        scanState = .complete(
            kind: "Apple Music Scan",
            processed: min(total, candidates.count),
            total: total,
            matched: matched,
            failed: failed,
            skipped: skipped,
            needsDownload: needsDownload,
            cancelled: scanCancelRequested
        )
        statusMessage = ""
    }

    // MARK: - Holding folder + file operations

    #if os(macOS)
    private static let mediaFolderBookmarkKey = "mediaFolderBookmark"

    /// Resolves (or prompts the user for) the media folder where Holding/ and
    /// Quarantine/ subfolders live. Uses a security-scoped bookmark so the app
    /// keeps read-write access across launches under the sandbox.
    private func resolveMediaFolder() throws -> URL {
        if let data = UserDefaults.standard.data(forKey: Self.mediaFolderBookmarkKey) {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale) {
                if stale {
                    // Refresh the bookmark so it keeps resolving on future launches.
                    if url.startAccessingSecurityScopedResource() {
                        defer { url.stopAccessingSecurityScopedResource() }
                        if let refreshed = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
                            UserDefaults.standard.set(refreshed, forKey: Self.mediaFolderBookmarkKey)
                        }
                    }
                }
                return url
            }
        }
        // No bookmark (or it failed to resolve) — prompt the user.
        let panel = NSOpenPanel()
        panel.title = "Choose NightGard Library Commander working folder"
        panel.prompt = "Choose This Folder"
        panel.message = """
        NightGard Library Commander needs a working folder on a drive you own. Two subfolders will be created inside whatever you pick:

        • Holding/ — temporary home for audio files after Library Commander copies them from Music and before re-importing into the "Cleaned NightGard Library Commander" playlist. Also an archive you can browse in Finder afterward.

        • Quarantine/ — final resting place for tracks that neither Apple Music Scan nor Shazam Scan could identify. Your call later on what to do with them.

        Suggested: your ~/Music folder, or a folder on an external drive with plenty of free space. You grant this access once; the app remembers it.
        """
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let picked = panel.url else {
            throw LockerError.noiCloud  // reusing — just signals "couldn't get a folder"
        }
        let bookmark = try picked.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        UserDefaults.standard.set(bookmark, forKey: Self.mediaFolderBookmarkKey)
        return picked
    }

    private func createHoldingFolder() throws -> URL {
        let mediaFolder = try resolveMediaFolder()
        guard mediaFolder.startAccessingSecurityScopedResource() else {
            throw LockerError.noiCloud
        }
        activeMediaFolderAccess = mediaFolder
        let root = mediaFolder.appendingPathComponent("NightGard Library Commander - Cleaned", isDirectory: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        let dated = root.appendingPathComponent(formatter.string(from: Date()), isDirectory: true)
        try FileManager.default.createDirectory(at: dated, withIntermediateDirectories: true)
        return dated
    }

    private func releaseMediaFolderAccess() {
        activeMediaFolderAccess?.stopAccessingSecurityScopedResource()
        activeMediaFolderAccess = nil
    }

    func forgetMediaFolder() {
        UserDefaults.standard.removeObject(forKey: Self.mediaFolderBookmarkKey)
    }

    private func trackLocation(persistentID: String) -> URL? {
        let script = """
        tell application "Music"
            try
                set t to (first track of library playlist 1 whose persistent ID is "\(persistentID)")
                return POSIX path of (location of t)
            on error
                return ""
            end try
        end tell
        """
        guard let result = runAppleScript(script), !result.isEmpty else { return nil }
        return URL(fileURLWithPath: result)
    }

    private func canonicalFilename(hit: iTunesHit, sourceExtension: String) -> String {
        let components = [hit.artist, hit.album ?? "", hit.title].filter { !$0.isEmpty }
        let raw = components.joined(separator: " ")
        let ext = sourceExtension.isEmpty ? "mp3" : sourceExtension
        return sanitize(raw) + "." + ext
    }

    private func sanitize(_ s: String) -> String {
        let illegal = CharacterSet(charactersIn: "/:\\\"<>|?*")
        let cleaned = s.components(separatedBy: illegal).joined(separator: "")
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(200))  // keep well under the 255-byte filesystem limit
    }

    private func deleteTrackFromLibrary(persistentID: String) {
        let script = """
        tell application "Music"
            try
                delete (first track of library playlist 1 whose persistent ID is "\(persistentID)")
            end try
        end tell
        """
        _ = runAppleScript(script)
    }

    private func createPlaylistIfNeeded(name: String) {
        let safe = escape(name)
        let script = """
        tell application "Music"
            if not (exists user playlist "\(safe)") then
                make new user playlist with properties {name:"\(safe)"}
            end if
        end tell
        """
        _ = runAppleScript(script)
    }

    private func addFilesInFolderToPlaylist(folder: URL, playlist: String) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
        let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "wav", "aiff", "flac"]
        let audioFiles = entries.filter { audioExtensions.contains($0.pathExtension.lowercased()) }
        let safePlaylist = escape(playlist)
        for file in audioFiles {
            let safePath = escape(file.path)
            let script = """
            tell application "Music"
                try
                    add POSIX file "\(safePath)" to user playlist "\(safePlaylist)"
                end try
            end tell
            """
            _ = runAppleScript(script)
        }
    }
    #endif

    /// Last-resort Shazam fingerprint. NOT YET IMPLEMENTED — needs file-URL access
    /// via AppleScript + SHSession integration + ShazamQueue/Database port from
    /// NightGard Commander. Do NOT advertise as working.
    func runShazamScan() async {
        statusMessage = "Shazam Scan is not yet implemented. Port of ShazamService + SHSession audio fingerprinting from NightGard Commander is scheduled after Apple Music Scan stabilizes."
    }

    func cancelScan() {
        scanCancelRequested = true
    }

    // MARK: - iTunes Search API

    struct iTunesHit {
        let appleMusicID: String
        let artist: String
        let title: String
        let album: String?
        let genre: String?
        let year: String?
    }

    private func iTunesSearch(artist: String, title: String) async -> iTunesHit? {
        let cleanArtist = sanitizeSearchTerm(artist)
        let cleanTitle = sanitizeSearchTerm(title)
        let term = [cleanArtist, cleanTitle].filter { !$0.isEmpty }.joined(separator: " ")
        let capped = String(term.prefix(120))  // iTunes Search tolerates about this much
        guard let encoded = capped.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              !encoded.isEmpty,
              let url = URL(string: "https://itunes.apple.com/search?term=\(encoded)&media=music&entity=song&limit=1") else {
            return nil
        }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                NSLog("NightGard: iTunes HTTP %d for '%@' (body %d bytes)", http.statusCode, capped, data.count)
                return nil
            }
            guard !data.isEmpty else {
                NSLog("NightGard: iTunes empty body for '%@'", capped)
                return nil
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]],
                  let first = results.first else { return nil }
            guard let trackId = first["trackId"] as? Int else { return nil }
            let artistName = first["artistName"] as? String ?? ""
            let trackName = first["trackName"] as? String ?? ""
            let album = first["collectionName"] as? String
            let genre = first["primaryGenreName"] as? String
            var year: String?
            if let releaseDate = first["releaseDate"] as? String, releaseDate.count >= 4 {
                year = String(releaseDate.prefix(4))
            }
            return iTunesHit(
                appleMusicID: String(trackId),
                artist: artistName,
                title: trackName,
                album: album,
                genre: genre,
                year: year
            )
        } catch {
            NSLog("NightGard: iTunes search error for '%@': %@", capped, "\(error)")
            return nil
        }
    }

    /// Scrubs decade-old tag cruft from search terms before sending to iTunes Search:
    /// strip parentheticals and brackets (often contain remix tags, ripper notes),
    /// collapse whitespace, strip leading track numbers, remove disallowed chars.
    private func sanitizeSearchTerm(_ s: String) -> String {
        var t = s
        // Strip anything in ( ) or [ ] or { }
        t = t.replacingOccurrences(of: "\\([^)]*\\)", with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\[[^\\]]*\\]", with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\{[^}]*\\}", with: " ", options: .regularExpression)
        // Strip leading "NNN " / "NN - " track number prefixes
        t = t.replacingOccurrences(of: "^\\d{1,3}\\s*[-_.]?\\s*", with: "", options: .regularExpression)
        // Strip file extensions if someone crammed them into the tag
        t = t.replacingOccurrences(of: "\\.(mp3|m4a|wav|aac|aiff|flac)\\b", with: "", options: [.regularExpression, .caseInsensitive])
        // Collapse whitespace
        t = t.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - AppleScript write-back

    #if os(macOS)
    /// Bring the library track into compliance with Apple Music's canonical values.
    /// Overwrites artist/title/album/genre/year when they differ from Apple's truth,
    /// wipes ripper/encoder cruft from comment and grouping, leaves user-owned
    /// fields alone (composer, description, rating, play count, date added).
    /// Never writes the Apple Music ID — Apple assigns that during its own matching.
    private func writeBack(persistentID: String, hit: iTunesHit) {
        var setters: [String] = []

        if !hit.artist.isEmpty {
            setters.append("if (artist of t) is not \"\(escape(hit.artist))\" then set artist of t to \"\(escape(hit.artist))\"")
        }
        if !hit.title.isEmpty {
            setters.append("if (name of t) is not \"\(escape(hit.title))\" then set name of t to \"\(escape(hit.title))\"")
        }
        if let album = hit.album, !album.isEmpty {
            setters.append("if (album of t) is not \"\(escape(album))\" then set album of t to \"\(escape(album))\"")
        }
        if let genre = hit.genre, !genre.isEmpty {
            setters.append("if (genre of t) is not \"\(escape(genre))\" then set genre of t to \"\(escape(genre))\"")
        }
        if let year = hit.year, let y = Int(year) {
            setters.append("if (year of t) is not \(y) then set year of t to \(y)")
        }
        // Wipe ripper / encoder cruft
        setters.append("if (comment of t) is not \"\" then set comment of t to \"\"")
        setters.append("if (grouping of t) is not \"\" then set grouping of t to \"\"")

        let body = setters.joined(separator: "\n            ")
        let script = """
        tell application "Music"
            set t to (first track of library playlist 1 whose persistent ID is "\(persistentID)")
            \(body)
        end tell
        """
        _ = runAppleScript(script)
    }

    private func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }
    #endif

    // MARK: - Match-confidence gate

    /// Rough similarity check — are the artist+title Apple returned close enough to
    /// what we searched for that we trust the match? Guards against catastrophic
    /// overwrites when iTunes Search returns an unrelated top hit.
    private func matchIsTrustworthy(query artist: String, title: String, hit: iTunesHit) -> Bool {
        let q = normalize("\(artist) \(title)")
        let r = normalize("\(hit.artist) \(hit.title)")
        guard !q.isEmpty, !r.isEmpty else { return false }
        // Simple containment check in either direction is good enough here —
        // avoids pulling in a full Levenshtein dependency.
        return q.contains(r) || r.contains(q) || sharedTokenRatio(q, r) >= 0.6
    }

    private func normalize(_ s: String) -> String {
        s.lowercased()
         .components(separatedBy: CharacterSet.alphanumerics.union(.whitespaces).inverted)
         .joined(separator: " ")
         .components(separatedBy: .whitespaces)
         .filter { !$0.isEmpty }
         .joined(separator: " ")
    }

    private func sharedTokenRatio(_ a: String, _ b: String) -> Double {
        let aTokens = Set(a.split(separator: " ").map(String.init))
        let bTokens = Set(b.split(separator: " ").map(String.init))
        guard !aTokens.isEmpty, !bTokens.isEmpty else { return 0 }
        let shared = aTokens.intersection(bTokens).count
        return Double(shared) / Double(min(aTokens.count, bTokens.count))
    }

    /// Full list of tracks missing Apple Music ID, no display cap. Used by scans.
    /// Uses AppleScript's `property of every X whose Y` bulk syntax — one round trip
    /// per property, cleanly handles ghost track references per-try.
    private func fetchAllCandidateTracks() -> [UploadedTrackRow] {
        #if os(macOS)
        ensureMusicRunning()
        let sep = "‖"  // double vertical bar — unlikely in track metadata
        let filter = "cloud status is not matched and cloud status is not subscription and cloud status is not purchased"
        let script = """
        tell application "Music"
            set AppleScript's text item delimiters to "\(sep)"
            set idBlob to ""
            set nameBlob to ""
            set artistBlob to ""
            set albumBlob to ""
            set genreBlob to ""
            try
                set idBlob to ((persistent ID of every track of library playlist 1 whose \(filter)) as text)
            end try
            try
                set nameBlob to ((name of every track of library playlist 1 whose \(filter)) as text)
            end try
            try
                set artistBlob to ((artist of every track of library playlist 1 whose \(filter)) as text)
            end try
            try
                set albumBlob to ((album of every track of library playlist 1 whose \(filter)) as text)
            end try
            try
                set genreBlob to ((genre of every track of library playlist 1 whose \(filter)) as text)
            end try
            set AppleScript's text item delimiters to ""
            return idBlob & "§" & nameBlob & "§" & artistBlob & "§" & albumBlob & "§" & genreBlob
        end tell
        """
        guard let result = runAppleScript(script) else { return [] }
        let columns = result.components(separatedBy: "§")
        guard columns.count >= 5 else { return [] }
        let ids = columns[0].isEmpty ? [] : columns[0].components(separatedBy: sep)
        guard !ids.isEmpty else { return [] }
        let names = columns[1].components(separatedBy: sep)
        let artists = columns[2].components(separatedBy: sep)
        let albums = columns[3].components(separatedBy: sep)
        let genres = columns[4].components(separatedBy: sep)
        var rows: [UploadedTrackRow] = []
        rows.reserveCapacity(ids.count)
        for i in 0..<ids.count {
            rows.append(UploadedTrackRow(
                persistentID: ids[i],
                title: i < names.count ? names[i] : "",
                artist: i < artists.count ? artists[i] : "",
                album: i < albums.count ? albums[i] : "",
                genre: i < genres.count ? genres[i] : ""
            ))
        }
        return rows
        #else
        return []
        #endif
    }

    // MARK: - AppleScript implementations

    #if os(macOS)
    private func ensureMusicRunning() {
        let bundleID = "com.apple.Music"
        if !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty {
            return
        }
        NSLog("NightGard: Music not running, launching…")
        let musicURL = URL(fileURLWithPath: "/System/Applications/Music.app")
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        NSWorkspace.shared.openApplication(at: musicURL, configuration: config) { _, err in
            if let err { NSLog("NightGard: Music launch error: %@", "\(err)") }
        }
        for _ in 0..<20 {
            Thread.sleep(forTimeInterval: 0.25)
            if !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty {
                NSLog("NightGard: Music is now running")
                return
            }
        }
        NSLog("NightGard: Music failed to launch within 5s")
    }

    private func runAppleScriptStats() -> LibraryStats {
        NSLog("NightGard: runAppleScriptStats start")
        ensureMusicRunning()
        let script = """
        launch application "Music"
        delay 0.5
        tell application id "com.apple.Music"
            activate
            set t to count of tracks
            set p to count of playlists
            set noArtist to count of (every track of library playlist 1 whose artist is "")
            set noAlbum to count of (every track of library playlist 1 whose album is "")
            set noGenre to count of (every track of library playlist 1 whose genre is "")
            set m to count of (every track of library playlist 1 whose cloud status is matched)
            set pp to count of (every track of library playlist 1 whose cloud status is purchased)
            set u to count of (every track of library playlist 1 whose cloud status is uploaded)
            set sub to count of (every track of library playlist 1 whose cloud status is subscription)
            return (t as text) & "," & (p as text) & "," & (m as text) & "," & (pp as text) & "," & (u as text) & "," & (sub as text) & "," & (noArtist as text) & "," & (noAlbum as text) & "," & (noGenre as text)
        end tell
        """
        guard let result = runAppleScript(script) else {
            NSLog("NightGard: runAppleScriptStats -> runAppleScript returned nil")
            return .empty
        }
        NSLog("NightGard: AppleScript result: '%@'", result)
        let parts = result.split(separator: ",").map { Int($0.trimmingCharacters(in: .whitespaces)) ?? 0 }
        NSLog("NightGard: parsed parts count=%d values=%@", parts.count, parts)
        guard parts.count >= 9 else {
            statusMessage = "AppleScript returned \(parts.count) fields, expected 9. Raw: '\(result)'"
            return .empty
        }
        return LibraryStats(
            totalTracks: parts[0],
            totalPlaylists: parts[1],
            matched: parts[2],
            purchased: parts[3],
            uploaded: parts[4],
            subscription: parts[5],
            missingArtist: parts[6],
            missingAlbum: parts[7],
            missingGenre: parts[8],
            macOnly: false
        )
    }

    private func runAppleScriptUploadedTracks() -> [UploadedTrackRow] {
        ensureMusicRunning()
        // Pull tracks with no Apple Music ID (uploaded, error, or other problem states).
        // Matched / subscription / purchased tracks are excluded (they have Apple Music IDs).
        let script = """
        tell application "Music"
            set output to ""
            set candidates to (every track of library playlist 1 whose cloud status is not matched and cloud status is not subscription and cloud status is not purchased)
            set totalCount to count of candidates
            set maxRows to 200
            set n to totalCount
            if n > maxRows then set n to maxRows
            repeat with i from 1 to n
                set t to item i of candidates
                try
                    set g to genre of t
                on error
                    set g to ""
                end try
                set output to output & (persistent ID of t) & "\t" & (name of t) & "\t" & (artist of t) & "\t" & (album of t) & "\t" & g & linefeed
            end repeat
            return (totalCount as text) & "||" & output
        end tell
        """
        guard let result = runAppleScript(script) else { return [] }
        let parts = result.split(separator: "||", maxSplits: 1).map(String.init)
        let totalCount = parts.count >= 1 ? Int(parts[0].trimmingCharacters(in: .whitespaces)) ?? 0 : 0
        self.uploadedTracksTotal = totalCount
        let rowsBlob = parts.count >= 2 ? parts[1] : ""
        let lines = rowsBlob.split(separator: "\n", omittingEmptySubsequences: true)
        return lines.compactMap { line -> UploadedTrackRow? in
            let cols = line.components(separatedBy: "\t")
            guard cols.count >= 4 else { return nil }
            return UploadedTrackRow(
                persistentID: cols[0],
                title: cols[1],
                artist: cols[2],
                album: cols[3],
                genre: cols.count >= 5 ? cols[4] : ""
            )
        }
    }

    private func runAppleScript(_ source: String) -> String? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            NSLog("NightGard: NSAppleScript init failed")
            statusMessage = "NSAppleScript init failed"
            return nil
        }
        NSLog("NightGard: executing AppleScript…")
        let descriptor = script.executeAndReturnError(&error)
        if let err = error {
            let num = err[NSAppleScript.errorNumber] ?? "?"
            let msg = err[NSAppleScript.errorMessage] ?? "(no message)"
            NSLog("NightGard: AppleScript error %@: %@", "\(num)", "\(msg)")
            statusMessage = "AppleScript error \(num): \(msg)"
            return nil
        }
        NSLog("NightGard: AppleScript descriptor type=%u stringValue=%@", descriptor.descriptorType, descriptor.stringValue ?? "nil")
        if let result = descriptor.stringValue {
            statusMessage = ""
            return result
        }
        statusMessage = "AppleScript returned no string. Descriptor type: \(descriptor.descriptorType). Likely sandbox/TCC silently dropped the event — check System Settings → Privacy & Security → Automation."
        return nil
    }
    #endif
}

// MARK: - Data Types

struct LibraryStats: Equatable {
    var totalTracks: Int
    var totalPlaylists: Int
    var matched: Int
    var purchased: Int
    var uploaded: Int
    var subscription: Int
    var missingArtist: Int
    var missingAlbum: Int
    var missingGenre: Int
    var macOnly: Bool

    static let empty = LibraryStats(
        totalTracks: 0, totalPlaylists: 0,
        matched: 0, purchased: 0, uploaded: 0, subscription: 0,
        missingArtist: 0, missingAlbum: 0, missingGenre: 0,
        macOnly: false
    )
}

enum ScanState: Equatable {
    case idle
    case scanning(kind: String, currentTrack: String, processed: Int, total: Int, matched: Int, failed: Int, skipped: Int, needsDownload: Int)
    case complete(kind: String, processed: Int, total: Int, matched: Int, failed: Int, skipped: Int, needsDownload: Int, cancelled: Bool)
}

struct UploadedTrackRow: Identifiable, Hashable {
    let persistentID: String
    let title: String
    let artist: String
    let album: String
    let genre: String
    var id: String { persistentID }

    /// All rows from this query lack Apple Music ID by definition → red.
    /// Future pass will introduce yellow (has ID, missing metadata) and green (complete).
    var health: TrackHealth { .red }
}

enum TrackHealth {
    case red, yellow, green

    var color: Color { switch self { case .red: .red; case .yellow: .yellow; case .green: .green } }
    var label: String { switch self { case .red: "No Apple Music ID"; case .yellow: "Partial metadata"; case .green: "OK" } }
}
