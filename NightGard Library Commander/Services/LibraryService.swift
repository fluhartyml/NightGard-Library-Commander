//
//  LibraryService.swift
//  NightGard Library Commander
//
//  Wraps MusicKit for cross-platform work, falls back to AppleScript
//  on macOS for fields MusicKit doesn't expose (cloud status, per-track
//  metadata gap queries).
//

import Foundation
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
    var isWorking = false
    var statusMessage = ""

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
        let script = """
        tell application "Music"
            set output to ""
            set uploadedList to (every track of library playlist 1 whose cloud status is uploaded)
            set maxRows to 200
            set n to count of uploadedList
            if n > maxRows then set n to maxRows
            repeat with i from 1 to n
                set t to item i of uploadedList
                set output to output & (persistent ID of t) & "\t" & (name of t) & "\t" & (artist of t) & "\t" & (album of t) & linefeed
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
                album: cols[3]
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

struct UploadedTrackRow: Identifiable, Hashable {
    let persistentID: String
    let title: String
    let artist: String
    let album: String
    var id: String { persistentID }
}
