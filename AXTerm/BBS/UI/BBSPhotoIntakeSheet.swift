//
//  BBSPhotoIntakeSheet.swift
//  AXTerm
//

import SwiftUI

/// Sizes photos on their way into a BBS area, one at a time, with the same
/// preview Send File uses: what callers will download, and how long it holds
/// the channel (operator, 2026-10-07).
struct BBSPhotoIntakeSheet: View {
    let photos: [BBSPendingPhoto]
    /// Adds one photo as chosen and says what became of it.
    let add: (BBSPendingPhoto, PhotoSendChoice.Prepared) -> BBSFileLibrary.AddOutcome
    /// Called once, with every outcome, when the last photo is done or the
    /// rest are skipped.
    let finish: ([BBSFileLibrary.AddOutcome]) -> Void

    @State private var index = 0
    @State private var prepared: PhotoSendChoice.Prepared?
    @State private var outcomes: [BBSFileLibrary.AddOutcome] = []

    var body: some View {
        NavigationStack {
            Form {
                if let photo = current {
                    Section {
                        PhotoSendPanel(original: photo.data, name: photo.name, prepared: $prepared)
                            // A fresh panel per photo, so its size and preview
                            // start over rather than carry the last one's.
                            .id(photo.id)
                    } header: {
                        Text(photos.count > 1
                             ? "\(photo.name) · \(index + 1) of \(photos.count) for \(photo.area)"
                             : "\(photo.name) for \(photo.area)")
                    } footer: {
                        Text("Callers download it at this size. The photo you picked is not changed.")
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Photo Size")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(photos.count - index > 1 ? "Skip" : "Don't Add") { advance() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        if let photo = current, let prepared {
                            outcomes.append(add(photo, prepared))
                        }
                        advance()
                    }
                    .disabled(prepared == nil)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 560)
        #endif
    }

    private var current: BBSPendingPhoto? {
        photos.indices.contains(index) ? photos[index] : nil
    }

    private func advance() {
        prepared = nil
        if index + 1 < photos.count {
            index += 1
        } else {
            finish(outcomes)
        }
    }
}
