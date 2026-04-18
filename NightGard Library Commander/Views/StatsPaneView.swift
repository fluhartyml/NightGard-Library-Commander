//
//  StatsPaneView.swift
//  NightGard Library Commander
//

import SwiftUI

struct StatsPaneView: View {
    @Environment(LibraryService.self) private var library
    var onJumpToLibrary: () -> Void = {}

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    Button {
                        onJumpToLibrary()
                    } label: {
                        HStack(spacing: 12) {
                            Text("Library Health")
                                .font(.system(size: 24, weight: .bold))
                            Image(systemName: healthIcon)
                                .font(.system(size: 28))
                                .foregroundStyle(healthColor)
                            Text(healthLabel)
                                .font(.system(size: 16))
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 14))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    #if os(macOS)
                    .onHover { hovering in
                        if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                    }
                    #endif

                    Spacer()
                    Button {
                        Task { await library.refreshStats() }
                    } label: {
                        HStack(spacing: 6) {
                            if library.isWorking {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text("Refresh")
                        }
                    }
                    .disabled(library.isWorking)
                }

                if health == .sad || health == .bored {
                    Text(suggestedAction)
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
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
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Last message")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(library.statusMessage)
                            .font(.system(size: 14))
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                    .padding()
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .padding()
        }
    }

    // MARK: - Health classification

    private enum Health { case happy, bored, sad, noData }

    private var problemState: Int {
        let accounted = library.stats.matched + library.stats.subscription + library.stats.purchased + library.stats.uploaded
        return max(0, library.stats.totalTracks - accounted)
    }

    private var metadataGaps: Int {
        library.stats.missingArtist + library.stats.missingAlbum + library.stats.missingGenre
    }

    private var health: Health {
        if library.stats.totalTracks == 0 { return .noData }
        if problemState > 0 { return .sad }
        if metadataGaps > 0 { return .bored }
        return .happy
    }

    private var healthIcon: String {
        switch health {
        case .happy: "hand.thumbsup.fill"
        case .bored: "minus.circle.fill"
        case .sad: "hand.thumbsdown.fill"
        case .noData: "questionmark.circle.fill"
        }
    }

    private var healthColor: Color {
        switch health {
        case .happy: .green
        case .bored: .yellow
        case .sad: .red
        case .noData: .gray
        }
    }

    private var healthLabel: String {
        switch health {
        case .happy: "Clean"
        case .bored: "\(metadataGaps.formatted()) metadata gaps"
        case .sad: "\(problemState.formatted()) tracks in problem state"
        case .noData: "Tap Refresh to load stats"
        }
    }

    private var suggestedAction: String {
        switch health {
        case .sad:
            "Run Apple Music Scan on your uploaded + problem tracks to identify and fill missing metadata. Shazam only what's still unresolved after that."
        case .bored:
            "Run Apple Music Scan to fill missing artist / album / genre fields using the iTunes catalog."
        default:
            ""
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
