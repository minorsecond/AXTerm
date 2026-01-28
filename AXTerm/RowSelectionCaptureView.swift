//
//  RowSelectionCaptureView.swift
//  AXTerm
//
//  Created by Ross Wardrup on 2/1/26.
//

import SwiftUI
import AppKit

struct RowSelectionCaptureView: NSViewRepresentable {
    let onSecondaryClick: () -> Void

    func makeNSView(context: Context) -> NSView {
        CaptureView(onSecondaryClick: onSecondaryClick)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? CaptureView else { return }
        view.onSecondaryClick = onSecondaryClick
    }
}

private final class CaptureView: NSView {
    var onSecondaryClick: () -> Void

    init(onSecondaryClick: @escaping () -> Void) {
        self.onSecondaryClick = onSecondaryClick
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func rightMouseDown(with event: NSEvent) {
        onSecondaryClick()
        super.rightMouseDown(with: event)
    }
}
