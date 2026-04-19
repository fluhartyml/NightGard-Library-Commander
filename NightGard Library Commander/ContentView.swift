//
//  ContentView.swift
//  NightGard Library Commander
//

import SwiftUI
import MusicKit

struct ContentView: View {
    @Environment(LibraryService.self) private var library
    @State private var selection: Pane = .stats

    enum Pane: Hashable, CaseIterable {
        case playlists, libraryBrowser, locker, stats

        var title: String {
            switch self {
            case .playlists: "Playlists"
            case .libraryBrowser: "Library"
            case .locker: "Playlist Locker"
            case .stats: "Stats"
            }
        }

        var systemImage: String {
            switch self {
            case .playlists: "music.note.list"
            case .libraryBrowser: "books.vertical"
            case .locker: "archivebox"
            case .stats: "chart.bar"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(Pane.allCases, id: \.self, selection: $selection) { pane in
                Label(pane.title, systemImage: pane.systemImage)
                    .font(.system(size: 18))
                    .tag(pane)
            }
            .navigationTitle("NightGard")
            #if os(macOS)
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
            #endif
        } detail: {
            detailPane(for: selection)
                .navigationTitle(selection.title)
        }
        .overlay(alignment: .top) {
            if library.authorizationStatus == .denied || library.authorizationStatus == .restricted {
                authorizationBanner
                    .padding()
            }
        }
        .safeAreaInset(edge: .bottom) {
            footerStatusBar
        }
    }

    private var footerStatusBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(library.isWorking ? Color.blue : Color.green)
                .frame(width: 8, height: 8)
            Text(footerMessage)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    private var footerMessage: String {
        if !library.statusMessage.isEmpty {
            return library.statusMessage
        }
        if case .scanning(let kind, let current, let processed, let total, _, _, _, _) = library.scanState {
            return "\(kind) \(processed.formatted())/\(total.formatted()) — \(current)"
        }
        if library.isWorking {
            return "Working…"
        }
        return "Ready"
    }

    @ViewBuilder
    private func detailPane(for pane: Pane) -> some View {
        switch pane {
        case .playlists: PlaylistsPaneView()
        case .libraryBrowser: LibraryPaneView()
        case .locker: LockerPaneView()
        case .stats: StatsPaneView(onJumpToLibrary: { selection = .libraryBrowser })
        }
    }

    private var authorizationBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.fill")
            Text("Apple Music access required. Status: \(authorizationText)")
                .font(.system(size: 18))
            Spacer()
            Button("Request Access") {
                Task { await library.authorize() }
            }
        }
        .padding()
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private var authorizationText: String {
        switch library.authorizationStatus {
        case .authorized: "Authorized"
        case .denied: "Denied (enable in Settings)"
        case .restricted: "Restricted"
        case .notDetermined: "Not yet asked"
        @unknown default: "Unknown"
        }
    }
}

#Preview {
    ContentView()
        .environment(LibraryService())
        .environment(PlaylistLockerService())
}
