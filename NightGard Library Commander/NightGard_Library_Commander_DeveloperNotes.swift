// MARK: - NightGard Library Commander — Developer Notes
// Version: 1.0 (pre-release)
// Developer: Michael Lee Fluharty
// Engineered with: Claude by Anthropic
// License: GPL v3 — Share and share alike, attribution required
// Created: 2026-04-18
//
// ============================================================
// MISSION
// ============================================================
//
// An Apple Music library organization tool for people whose library
// has grown messy over the years — missing metadata, orphan playlists,
// uploaded-but-unmatched tracks, duplicates. The app cleans at the
// LIBRARY level (MusicKit + AppleScript-on-macOS), never by moving
// physical audio files. That's NightGard Commander's job (its sibling,
// same family, file-level focus).
//
// Reference audit of Michael's library at project start:
//   27,255 tracks, 45 playlists
//   5,460 missing artist, 8,428 missing album, 7,226 missing genre
//   11,247 matched, 3,122 subscription, 969 purchased, 6,651 uploaded
//   ~5,250 in problem cloud status (error/no longer available)
//
// ============================================================
// PROJECT ROADMAP
// ============================================================
//
// v1.0 — MVP: "Four Panes"
// -------------------------
//   [ ] Rip out Xcode SwiftData scaffold (Item.swift, addItem template)
//   [ ] NavigationSplitView shell with four-pane sidebar
//   [ ] Playlists pane
//       [ ] List all user playlists (MusicLibraryRequest<Playlist>)
//       [ ] Multi-select, bulk delete
//       [ ] Rename in place
//       [ ] Group into playlist folders (where supported)
//   [ ] Library pane
//       [ ] Filter to uploaded + problem-state tracks
//       [ ] Per-row catalog search (find canonical Apple Music version)
//       [ ] One-tap replace: add catalog version, remove uploaded copy
//   [ ] Playlist Locker pane
//       [x] PlaylistLockerService ported from TngrnGrvWr (Apple Music only)
//       [ ] iCloud Documents capability added to entitlements
//       [ ] Backup all playlists button
//       [ ] List existing backups by date folder
//       [ ] Restore playlist from M3U
//       [ ] Delete backup
//   [ ] Stats pane
//       [ ] Live library health dashboard
//       [ ] Total tracks, playlist count
//       [ ] Cloud status breakdown (matched / uploaded / purchased / subscription / problem)
//       [ ] Metadata gaps (missing artist / album / genre counts)
//
// v1.1 — Post-Launch
// -------------------
//   [ ] Shazam queue (identify weak-metadata tracks, batch)
//   [ ] Duplicate finder (title+artist collisions, merge/delete)
//   [ ] macOS AppleScript metadata-edit mode (in-place artist/album/genre fixes)
//   [ ] Playlist locker restore across accounts (M3U → new Apple Music playlist)
//   [ ] iCloud KV sync for "reviewed" flags across devices (or SwiftData+CloudKit)
//
// ============================================================
// WORKING FOLDER (Holding + Quarantine)
// ============================================================
//
// On first Apple Music Scan the app prompts the user via NSOpenPanel to
// choose a "working folder." Sandbox saves a security-scoped bookmark so
// subsequent launches don't re-prompt. Inside that folder, the app creates:
//
//   Holding/       Temporary audio files copied from Music library during
//                  a scan. After each scan, files here get re-imported into
//                  the "Cleaned NightGard Library Commander" playlist —
//                  Apple's own matching then assigns canonical Apple Music
//                  IDs. Files stay on disk as a user-browsable archive.
//
//   Quarantine/    Final home for tracks that failed both Apple Music Scan
//                  AND Shazam Scan. User decides what to do with them later.
//
// Why ask instead of hard-coding ~/Downloads:
//   Sandbox silently redirects standard paths (like the Downloads folder) to
//   the app's container (~/Library/Containers/<bundle>/Data/Downloads).
//   User-picked folders bypass this via security-scoped bookmarks — the user
//   grants explicit access, and that access persists.
//
// Reset paths:
//   UserDefaults.standard.removeObject(forKey: "mediaFolderBookmark")
//   or LibraryService.forgetMediaFolder()
//
// ============================================================
// ARCHITECTURE DECISIONS
// ============================================================
//
// Platform: Universal — iOS, iPadOS, macOS (native SwiftUI, not Catalyst).
//   Rationale: macOS native build gets AppleScript for in-place metadata
//   editing, iOS/iPadOS get MusicKit-only feature set. #if os(macOS)
//   guards the AppleScript paths.
//
// CloudKit: enabled at project creation (automatic container provisioning).
//   SwiftData models must use optionals/defaults per CloudKit rules.
//   Use for: cross-device "reviewed tracks" queue, flagged-playlist staging.
//   Don't store MusicKit library data in SwiftData — query live, cache in memory.
//
// Storage: SwiftData for app-side state only. Apple Music library is the
//   source of truth for tracks/playlists — always queried via MusicKit.
//
// File format: M3U (Extended M3U) for playlist backups, same format used
//   in TngrnGrvWr. Includes #EXT-APPLE-ID per track so restore works.
//   Written to iCloud Drive/Documents/Playlist Locker/YYYY MMM DD Backup.AppleMusic/
//
// No CryoKit: this app has no radio stations or weather widget. Per
//   diamond rule, CryoKit is untouched.
//
// ============================================================
// APP STORE CONNECT
// ============================================================
//
// ** Claude: Update this section as information becomes available.
// ** Keep current with every submission. This is the source of truth.
//
// App Name: NightGard Library Commander
// App Apple ID: TBD (not yet submitted)
// Bundle ID: com.NightGard.NightGard-Library-Commander
// SKU: NightGardLibraryCommander
// Category: Music (alternate: Utilities)
// URL: TBD
//
// Current Version: 1.0 (build 1) — in development
// Status: pre-scaffold cleanup
//
// ============================================================
// RELATED PROJECTS
// ============================================================
//
// NightGard Commander (~/Developer.complex/NightGard/NightGard-Commander/)
//   Sibling app. Two-pane file manager for physical audio files with
//   Shazam + ID3 tag writing + iTunes Search Apple Music ID embedding.
//   File-level cleanup. Use it BEFORE importing messy files to Music.app.
//   This app handles what lives in the library after import.
//
// TngrnGrvWr (~/Developer.complex/TngrnGrvWr/)
//   Source of the ported PlaylistLockerService. Original supported
//   Apple Music + Spotify; this port is Apple Music only using MusicKit
//   types directly instead of the abstract Track wrapper.
//
// ============================================================
// GITHUB
// ============================================================
//
// Repo: https://github.com/fluhartyml/NightGard-Library-Commander
// Visibility: Private
// Branch: main
//
// Wiki: not yet created. Follow CryoTunesPlayer.wiki template when ready.
//
// ============================================================
// STANDING RULES (Michael's preferences baked into this project)
// ============================================================
//
// - 18pt minimum font height (iPad readability standard)
// - 100% black or 100% white contrast (no opacity tricks)
// - Packages bare bones — no fonts or aesthetic control, app owns UI
// - Auto-build after code changes, provide commit message unchased
// - Sync DeveloperNotes to wiki Developer-Notes.md after every change
// - Don't touch working code outside the task scope (ain't broke rule)

import Foundation
