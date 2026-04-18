//
//  PlaylistsPaneView.swift
//  NightGard Library Commander
//

import SwiftUI
import MusicKit

struct PlaylistsPaneView: View {
    @Environment(LibraryService.self) private var library
    @State private var selection: Set<MusicItemID> = []
    @State private var showingDeleteConfirm = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(library.playlists.count) playlists — \(selection.count) selected")
                    .font(.system(size: 18))
                Spacer()
                Button("Refresh") {
                    Task { await library.refreshPlaylists() }
                }
                Button(role: .destructive) {
                    showingDeleteConfirm = true
                } label: {
                    Text("Delete Selected")
                }
                .disabled(selection.isEmpty)
            }
            .padding()

            List(library.playlists, id: \.id, selection: $selection) { playlist in
                HStack {
                    Image(systemName: "music.note.list")
                        .foregroundStyle(.tint)
                    Text(playlist.name)
                        .font(.system(size: 18))
                }
                .tag(playlist.id)
            }
        }
        .task {
            if library.playlists.isEmpty {
                await library.refreshPlaylists()
            }
        }
        .confirmationDialog(
            "Delete \(selection.count) playlist(s)?",
            isPresented: $showingDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task {
                    let toDelete = library.playlists.filter { selection.contains($0.id) }
                    for playlist in toDelete {
                        await library.deletePlaylist(playlist)
                    }
                    selection.removeAll()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the playlists from your Apple Music library. The tracks stay.")
        }
    }
}
