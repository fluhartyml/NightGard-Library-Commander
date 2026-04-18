//
//  LockerPaneView.swift
//  NightGard Library Commander
//

import SwiftUI

struct LockerPaneView: View {
    @Environment(PlaylistLockerService.self) private var locker

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Playlist Locker — \(locker.lockerFiles.count) backups")
                    .font(.system(size: 18))
                Spacer()
                Button("Backup All Playlists") {
                    Task { try? await locker.backupAllPlaylists() }
                }
                .disabled(locker.isBackingUp)
                Button("Refresh") { locker.scanLocker() }
            }
            .padding()

            if locker.isBackingUp {
                VStack(spacing: 8) {
                    ProgressView()
                    Text(locker.backupProgress)
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
                .padding()
            }

            if locker.lockerFiles.isEmpty && !locker.isBackingUp {
                ContentUnavailableView(
                    "No backups yet",
                    systemImage: "archivebox",
                    description: Text("Tap Backup All Playlists to write M3U snapshots to iCloud Drive/Documents/Playlist Locker/.")
                )
            } else {
                List {
                    ForEach(groupedByFolder, id: \.folder) { group in
                        Section(group.folder) {
                            ForEach(group.files) { file in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(file.name)
                                            .font(.system(size: 18))
                                        Text("\(file.createdAt, format: .dateTime) — \(file.formattedSize)")
                                            .font(.system(size: 14))
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button(role: .destructive) {
                                        locker.deleteFile(file)
                                    } label: {
                                        Image(systemName: "trash")
                                    }
                                    .buttonStyle(.borderless)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var groupedByFolder: [(folder: String, files: [LockerFile])] {
        let groups = Dictionary(grouping: locker.lockerFiles, by: \.folder)
        return groups
            .map { (folder: $0.key, files: $0.value.sorted { $0.name < $1.name }) }
            .sorted { $0.folder > $1.folder }
    }
}
