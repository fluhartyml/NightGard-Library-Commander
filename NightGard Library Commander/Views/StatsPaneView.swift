//
//  StatsPaneView.swift
//  NightGard Library Commander
//

import SwiftUI

struct StatsPaneView: View {
    @Environment(LibraryService.self) private var library

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Library Health")
                        .font(.system(size: 24, weight: .bold))
                    Spacer()
                    Button("Refresh") {
                        Task { await library.refreshStats() }
                    }
                }

                if library.stats.macOnly {
                    ContentUnavailableView(
                        "Mac Only in v1",
                        systemImage: "macbook",
                        description: Text("Detailed cloud/metadata stats use AppleScript (macOS only).")
                    )
                } else {
                    card("Totals") {
                        row("Tracks", library.stats.totalTracks)
                        row("Playlists", library.stats.totalPlaylists)
                    }

                    card("Cloud Status") {
                        row("Matched", library.stats.matched)
                        row("Subscription", library.stats.subscription)
                        row("Purchased", library.stats.purchased)
                        row("Uploaded", library.stats.uploaded)
                        let accounted = library.stats.matched + library.stats.subscription + library.stats.purchased + library.stats.uploaded
                        let remainder = max(0, library.stats.totalTracks - accounted)
                        row("Problem state", remainder)
                    }

                    card("Metadata Gaps") {
                        row("Missing artist", library.stats.missingArtist)
                        row("Missing album", library.stats.missingAlbum)
                        row("Missing genre", library.stats.missingGenre)
                    }
                }

                if !library.statusMessage.isEmpty {
                    Text(library.statusMessage)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
        }
    }

    @ViewBuilder
    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 18, weight: .semibold))
            content()
        }
        .padding()
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }

    private func row(_ label: String, _ value: Int) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 18))
            Spacer()
            Text(value.formatted())
                .font(.system(size: 18, design: .monospaced))
        }
    }
}
