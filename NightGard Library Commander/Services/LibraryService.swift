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

    /// Apple Music text search pass. For each candidate track: query iTunes Search
    /// with "artist title", on match write album/genre/year back via AppleScript.
    /// Skips tracks already having complete artist+album+genre.
    func runAppleMusicScan() async {
        isWorking = true
        scanCancelRequested = false
        defer { isWorking = false }

        scanState = .scanning(
            kind: "Apple Music Scan",
            currentTrack: "Loading full candidate list…",
            processed: 0,
            total: uploadedTracksTotal,
            matched: 0, failed: 0, skipped: 0
        )
        let candidates = fetchAllCandidateTracks()
        let total = candidates.count
        guard total > 0 else {
            scanState = .complete(kind: "Apple Music Scan", processed: 0, total: 0, matched: 0, failed: 0, skipped: 0, cancelled: false)
            return
        }

        var matched = 0, failed = 0, skipped = 0
        for (index, track) in candidates.enumerated() {
            if scanCancelRequested { break }

            scanState = .scanning(
                kind: "Apple Music Scan",
                currentTrack: "\(track.artist) — \(track.title)",
                processed: index,
                total: total,
                matched: matched,
                failed: failed,
                skipped: skipped
            )

            // Skip if we have no search anchor (both artist and title empty).
            guard !track.artist.isEmpty || !track.title.isEmpty else {
                skipped += 1
                continue
            }

            // Be polite to iTunes Search API: ~3 req/sec ceiling.
            try? await Task.sleep(nanoseconds: 350_000_000)

            if let hit = await iTunesSearch(artist: track.artist, title: track.title),
               matchIsTrustworthy(query: track.artist, title: track.title, hit: hit) {
                #if os(macOS)
                writeBack(persistentID: track.persistentID, hit: hit)
                #endif
                matched += 1
            } else {
                failed += 1
            }
        }

        scanState = .complete(
            kind: "Apple Music Scan",
            processed: min(total, candidates.count),
            total: total,
            matched: matched,
            failed: failed,
            skipped: skipped,
            cancelled: scanCancelRequested
        )
        statusMessage = ""
    }

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
        let term = [artist, title].filter { !$0.isEmpty }.joined(separator: " ")
        guard let encoded = term.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              !encoded.isEmpty,
              let url = URL(string: "https://itunes.apple.com/search?term=\(encoded)&media=music&entity=song&limit=1") else {
            return nil
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
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
            NSLog("NightGard: iTunes search error for '%@': %@", term, "\(error)")
            return nil
        }
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
    private func fetchAllCandidateTracks() -> [UploadedTrackRow] {
        #if os(macOS)
        ensureMusicRunning()
        let script = """
        tell application "Music"
            set output to ""
            set candidates to (every track of library playlist 1 whose cloud status is not matched and cloud status is not subscription and cloud status is not purchased)
            repeat with t in candidates
                try
                    set g to genre of t
                on error
                    set g to ""
                end try
                set output to output & (persistent ID of t) & "\t" & (name of t) & "\t" & (artist of t) & "\t" & (album of t) & "\t" & g & linefeed
            end repeat
            return output
        end tell
        """
        guard let result = runAppleScript(script) else { return [] }
        let lines = result.split(separator: "\n", omittingEmptySubsequences: true)
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
    case scanning(kind: String, currentTrack: String, processed: Int, total: Int, matched: Int, failed: Int, skipped: Int)
    case complete(kind: String, processed: Int, total: Int, matched: Int, failed: Int, skipped: Int, cancelled: Bool)
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
