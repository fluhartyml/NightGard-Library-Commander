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
    @State private var editingID: MusicItemID?
    @State private var editingName: String = ""

    static let visibleCharCount = 20

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

            Text("First \(Self.visibleCharCount) characters shown bold — that's the practical display limit before most music apps truncate. Double-click a name to rename.")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.bottom, 8)

            List(library.playlists, id: \.id, selection: $selection) { playlist in
                row(for: playlist)
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

    @ViewBuilder
    private func row(for playlist: Playlist) -> some View {
        HStack(alignment: .top) {
            Image(systemName: "music.note.list")
                .foregroundStyle(.tint)
                .padding(.top, 2)

            if editingID == playlist.id {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        TextField("Name", text: $editingName, onCommit: {
                            commitRename(from: playlist.name)
                        })
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 18))

                        Button("Save") { commitRename(from: playlist.name) }
                            .keyboardShortcut(.defaultAction)
                        Button("Cancel") { cancelRename() }
                    }
                    emphasizedName(editingName)
                        .opacity(0.8)
                    charCountIndicator(for: editingName)
                }
            } else {
                emphasizedName(playlist.name)
                    .onTapGesture(count: 2) {
                        editingID = playlist.id
                        editingName = playlist.name
                    }
            }
        }
        .contextMenu {
            Button("Rename") {
                editingID = playlist.id
                editingName = playlist.name
            }
        }
    }

    @ViewBuilder
    private func charCountIndicator(for text: String) -> some View {
        let count = text.count
        let overflow = max(0, count - Self.visibleCharCount)
        HStack(spacing: 6) {
            Text("\(count) chars")
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(count > Self.visibleCharCount ? .red : .secondary)
            Text("•")
                .foregroundStyle(.secondary)
            Text("truncates at \(Self.visibleCharCount)")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            if overflow > 0 {
                Text("(\(overflow) over)")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.red)
            } else if count == Self.visibleCharCount {
                Text("(at limit)")
                    .font(.system(size: 13))
                    .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private func emphasizedName(_ name: String) -> some View {
        let visible = String(name.prefix(Self.visibleCharCount))
        let overflow = name.count > Self.visibleCharCount ? String(name.dropFirst(Self.visibleCharCount)) : ""
        HStack(spacing: 0) {
            Text(visible)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.primary)
            if !overflow.isEmpty {
                Text(overflow)
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func commitRename(from oldName: String) {
        let newName = editingName.trimmingCharacters(in: .whitespaces)
        defer {
            editingID = nil
            editingName = ""
        }
        guard !newName.isEmpty, newName != oldName else { return }
        Task {
            await library.renamePlaylist(oldName: oldName, newName: newName)
        }
    }

    private func cancelRename() {
        editingID = nil
        editingName = ""
    }
}
