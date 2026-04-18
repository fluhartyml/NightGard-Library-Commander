//
//  LibraryPaneView.swift
//  NightGard Library Commander
//
//  v1: shows uploaded tracks (cloud status = uploaded) on macOS.
//  iOS/iPadOS shows a Mac-only note for v1 — MusicKit on iOS doesn't
//  expose cloud status per track.
//

import SwiftUI

struct LibraryPaneView: View {
    @Environment(LibraryService.self) private var library

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Uploaded tracks: \(library.uploadedTracks.count)")
                    .font(.system(size: 18))
                Spacer()
                Button("Refresh") {
                    Task { await library.refreshUploadedTracks() }
                }
            }
            .padding()

            #if os(macOS)
            if library.uploadedTracks.isEmpty {
                ContentUnavailableView(
                    "No uploaded tracks loaded",
                    systemImage: "icloud.slash",
                    description: Text("Tap Refresh to load uploaded tracks from your library.")
                )
            } else {
                List(library.uploadedTracks) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.title.isEmpty ? "(no title)" : row.title)
                            .font(.system(size: 18))
                        Text("\(row.artist.isEmpty ? "(no artist)" : row.artist) — \(row.album.isEmpty ? "(no album)" : row.album)")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            #else
            ContentUnavailableView(
                "Mac Only in v1",
                systemImage: "macbook",
                description: Text("Cloud status per track isn't exposed by MusicKit on iOS/iPadOS. Coming in v1.1 via MediaPlayer framework.")
            )
            #endif
        }
    }
}
