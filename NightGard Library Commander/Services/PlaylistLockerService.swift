//
//  PlaylistLockerService.swift
//  NightGard Library Commander
//
//  Ported from TngrnGrvWr — Apple Music only.
//  Backs up library playlists to iCloud Drive as M3U files in datestamped folders.
//

import Foundation
import MusicKit

@Observable
@MainActor
final class PlaylistLockerService {

    var lockerFiles: [LockerFile] = []
    var isBackingUp = false
    var backupProgress: String = ""

    private let fileManager = FileManager.default

    var lockerURL: URL? {
        fileManager
            .url(forUbiquityContainerIdentifier: nil)?
            .appendingPathComponent("Documents/Playlist Locker", isDirectory: true)
    }

    private var dateStamp: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy MMM dd"
        return formatter.string(from: Date()).uppercased()
    }

    private var backupFolderURL: URL? {
        lockerURL?.appendingPathComponent("\(dateStamp) Backup.AppleMusic", isDirectory: true)
    }

    // MARK: - Scan Locker

    func scanLocker() {
        guard let url = lockerURL else {
            lockerFiles = []
            return
        }

        if !fileManager.fileExists(atPath: url.path) {
            try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }

        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.creationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            lockerFiles = []
            return
        }

        var files: [LockerFile] = []
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension.lowercased() == "m3u" else { continue }
            let attrs = try? fileManager.attributesOfItem(atPath: fileURL.path)
            let created = attrs?[.creationDate] as? Date ?? Date()
            let size = attrs?[.size] as? Int ?? 0

            let folder = fileURL.deletingLastPathComponent().lastPathComponent
            let name = fileURL.deletingPathExtension().lastPathComponent

            files.append(LockerFile(
                url: fileURL,
                name: name,
                folder: folder,
                createdAt: created,
                fileSize: size
            ))
        }

        lockerFiles = files.sorted { $0.createdAt > $1.createdAt }
    }

    // MARK: - Backup

    func backupAllPlaylists() async throws {
        isBackingUp = true
        defer { isBackingUp = false }

        backupProgress = "Fetching Apple Music playlists…"
        var request = MusicLibraryRequest<Playlist>()
        request.limit = 500
        let response = try await request.response()
        let playlists = response.items

        for (index, playlist) in playlists.enumerated() {
            backupProgress = "\(index + 1)/\(playlists.count): \(playlist.name)"
            let detailed = try await playlist.with([.tracks])
            let tracks = detailed.tracks ?? []
            let m3u = buildM3U(playlistName: playlist.name, tracks: Array(tracks))
            try writeM3U(name: playlist.name, content: m3u)
        }

        backupProgress = "Done — \(playlists.count) playlists backed up"
        scanLocker()
    }

    // MARK: - Delete

    func deleteFile(_ file: LockerFile) {
        try? fileManager.removeItem(at: file.url)
        scanLocker()
    }

    // MARK: - M3U Builder

    private func buildM3U(playlistName: String, tracks: [Track]) -> String {
        var lines: [String] = []
        lines.append("#EXTM3U")
        lines.append("#PLAYLIST:\(playlistName)")
        lines.append("#EXTSOURCE:apple_music")
        lines.append("")

        for track in tracks {
            let duration = Int(track.duration ?? 0)
            lines.append("#EXTINF:\(duration),\(track.artistName) - \(track.title)")

            if !track.albumTitle.isEmpty {
                lines.append("#EXTALB:\(track.albumTitle)")
            }
            lines.append("#EXT-APPLE-ID:\(track.id.rawValue)")
            lines.append("apple-music:track:\(track.id.rawValue)")
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - File I/O

    private func writeM3U(name: String, content: String) throws {
        guard let backupURL = backupFolderURL else {
            throw LockerError.noiCloud
        }

        if !fileManager.fileExists(atPath: backupURL.path) {
            try fileManager.createDirectory(at: backupURL, withIntermediateDirectories: true)
        }

        let safeName = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let fileURL = backupURL.appendingPathComponent("\(safeName).m3u")

        try content.write(to: fileURL, atomically: true, encoding: .utf8)
    }
}

// MARK: - LockerFile

struct LockerFile: Identifiable {
    let url: URL
    let name: String
    let folder: String
    let createdAt: Date
    let fileSize: Int

    var id: URL { url }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file)
    }
}

// MARK: - Errors

enum LockerError: LocalizedError {
    case noiCloud

    var errorDescription: String? {
        switch self {
        case .noiCloud: "iCloud Drive is not available. Sign into iCloud in System Settings."
        }
    }
}

private extension Track {
    var albumTitle: String {
        switch self {
        case .song(let song): return song.albumTitle ?? ""
        case .musicVideo(let video): return video.albumTitle ?? ""
        @unknown default: return ""
        }
    }
}
