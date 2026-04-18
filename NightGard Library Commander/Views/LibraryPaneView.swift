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
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 10, height: 10)
                    Text(headerCountLabel)
                        .font(.system(size: 18))
                }
                Spacer()
                Button("Refresh") {
                    Task { await library.refreshUploadedTracks() }
                }
                .disabled(library.isWorking)
                Button("Apple Music Scan") {
                    Task { await library.runAppleMusicScan() }
                }
                .disabled(library.isWorking || library.uploadedTracks.isEmpty)
                Button("Shazam Scan (last resort)") {
                    Task { await library.runShazamScan() }
                }
                .disabled(library.isWorking || library.uploadedTracks.isEmpty)
            }
            .padding()

            if !library.statusMessage.isEmpty {
                Text(library.statusMessage)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            }

            #if os(macOS)
            if library.uploadedTracks.isEmpty {
                ContentUnavailableView(
                    "No uploaded tracks loaded",
                    systemImage: "icloud.slash",
                    description: Text("Tap Refresh to load uploaded tracks from your library.")
                )
            } else {
                List(library.uploadedTracks) { row in
                    HStack(alignment: .top, spacing: 10) {
                        Circle()
                            .fill(row.health.color)
                            .frame(width: 10, height: 10)
                            .padding(.top, 6)
                            .help(row.health.label)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.title.isEmpty ? "(no title)" : row.title)
                                .font(.system(size: 18))
                            Text("\(row.artist.isEmpty ? "(no artist)" : row.artist) — \(row.album.isEmpty ? "(no album)" : row.album)\(row.genre.isEmpty ? "" : " · \(row.genre)")")
                                .font(.system(size: 14))
                                .foregroundStyle(.secondary)
                        }
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
        .task {
            #if os(macOS)
            if library.uploadedTracks.isEmpty && !library.isWorking {
                await library.refreshUploadedTracks()
            }
            #endif
        }
    }

    private var headerCountLabel: String {
        let shown = library.uploadedTracks.count
        let total = library.uploadedTracksTotal
        if total == 0 {
            return "Tracks needing Apple Music ID: 0"
        }
        if shown < total {
            return "Tracks needing Apple Music ID: \(total.formatted()) · showing first \(shown.formatted())"
        }
        return "Tracks needing Apple Music ID: \(total.formatted())"
    }
}
