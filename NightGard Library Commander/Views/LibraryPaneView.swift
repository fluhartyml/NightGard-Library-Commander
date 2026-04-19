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
                .buttonStyle(.bordered)
                .disabled(library.isWorking)

                Button {
                    Task { await library.runAppleMusicScan() }
                } label: {
                    Label("Apple Music Scan", systemImage: "bolt.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(library.isWorking || library.uploadedTracksTotal == 0)

                Button {
                    Task { await library.runShazamScan() }
                } label: {
                    Label {
                        Text("Shazam Scan (last resort)")
                    } icon: {
                        Image(systemName: "shazam.logo.fill")
                            .foregroundStyle(.blue)
                    }
                }
                .buttonStyle(.bordered)
                .help("Port of ShazamService + SHSession from NightGard Commander is next. Button is wired but not yet functional.")
                .disabled(true)
            }
            .padding()

            Text("Run Apple Music Scan first — text-search against the iTunes catalog fills metadata and attaches Apple Music IDs. Shazam the leftovers only if anything remains unidentified.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.bottom, 8)

            scanBanner

            refreshingBanner

            if !library.statusMessage.isEmpty {
                Text(library.statusMessage)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            }

            #if os(macOS)
            if library.uploadedTracks.isEmpty && library.isWorking {
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.large)
                    Text("One moment please…")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if library.uploadedTracks.isEmpty {
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

    @ViewBuilder
    private var refreshingBanner: some View {
        if library.isWorking, case .idle = library.scanState, !library.uploadedTracks.isEmpty {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("Refreshing track list…")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
    }

    @ViewBuilder
    private var scanBanner: some View {
        switch library.scanState {
        case .idle:
            EmptyView()
        case .scanning(let kind, let current, let processed, let total, let matched, let failed, let skipped, let needsDownload):
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("\(kind) — \(processed.formatted()) / \(total.formatted())")
                        .font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Button(library.scanCancelRequested ? "Cancelling…" : "Cancel") {
                        library.cancelScan()
                    }
                    .buttonStyle(.bordered)
                    .disabled(library.scanCancelRequested)
                }
                ProgressView(value: Double(processed), total: Double(max(total, 1)))
                Text(current)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 16) {
                    countPill("Matched", matched, .green)
                    countPill("Failed", failed, .red)
                    countPill("Needs download", needsDownload, .blue)
                    countPill("Skipped", skipped, .secondary)
                }
            }
            .padding()
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal)
            .padding(.bottom, 8)
        case .complete(let kind, let processed, let total, let matched, let failed, let skipped, let needsDownload, let cancelled):
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: cancelled ? "stop.circle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(cancelled ? .orange : .green)
                    Text(cancelled ? "\(kind) cancelled" : "\(kind) complete")
                        .font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Text("\(processed.formatted()) / \(total.formatted())")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 16) {
                    countPill("Matched", matched, .green)
                    countPill("Failed", failed, .red)
                    countPill("Needs download", needsDownload, .blue)
                    countPill("Skipped", skipped, .secondary)
                }
                if needsDownload > 0 {
                    Text("Needs download: \(needsDownload) tracks are iCloud-only on this Mac. In Music, select them and tap Download, then rerun Apple Music Scan to process.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
            }
            .padding()
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
    }

    @ViewBuilder
    private func countPill(_ label: String, _ value: Int, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text("\(label): \(value.formatted())")
                .font(.system(size: 13, design: .monospaced))
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
