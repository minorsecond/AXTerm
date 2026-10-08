import ImageIO
import SwiftUI

/// The photo half of sending a file: the size to send it at, what it will
/// look like when it arrives, and how long it will be on the air (operator,
/// 2026-10-07, planning a field test with photos).
///
/// The preview is decoded from the very bytes that will be sent, so what the
/// operator sees is what the other station gets. Pressing and holding it
/// shows the original for comparison.
struct PhotoSendPanel: View {
    let original: Data
    let name: String
    /// The rate of the last transfer with this station, for the airtime.
    var measuredBytesPerSecond: Double?
    var peer: String?
    /// HEIC is offered only when the other end can be trusted to open it:
    /// another AXTerm.
    var offersHEIC: Bool = false
    /// Where the size starts; nil starts at the suggestion for the link.
    var initialSize: PhotoSendSize? = nil
    @Binding var prepared: PhotoSendChoice.Prepared?

    @State private var size: PhotoSendSize = .small
    @State private var format: ImageShrinker.Format = .jpeg
    @State private var keepsLocation = false
    @State private var showsOriginal = false
    @State private var preview: CGImage?
    @State private var originalPreview: CGImage?
    @State private var isWorking = false

    private struct Key: Equatable {
        var size: PhotoSendSize
        var format: ImageShrinker.Format
        var keepsLocation: Bool
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            previewImage
            Picker("Size", selection: $size) {
                ForEach(PhotoSendSize.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            if offersHEIC, size != .original {
                Picker("Format", selection: $format) {
                    Text("JPEG").tag(ImageShrinker.Format.jpeg)
                    Text("HEIC, smaller").tag(ImageShrinker.Format.heic)
                }
                .pickerStyle(.segmented)
                .help("HEIC looks the same in less airtime. The other station is AXTerm, which opens it.")
            }
            Toggle("Keep the photo's location", isOn: $keepsLocation)
                .help("Off, the GPS position is taken out. Anyone listening can read what you send, and a photo taken at home says where home is.")
            summary
        }
        .onAppear {
            size = initialSize ?? PhotoSendSize.suggested(bytesPerSecond: measuredBytesPerSecond)
        }
        .task {
            let data = original
            originalPreview = await Task.detached { PhotoPreview.image(from: data, longEdge: 900) }.value
        }
        .task(id: Key(size: size, format: format, keepsLocation: keepsLocation)) {
            isWorking = true
            let (data, name, size, format, keepsLocation) = (original, name, size, format, keepsLocation)
            let result = await Task.detached {
                PhotoSendChoice.prepare(original: data, name: name, size: size, format: format,
                                        keepsLocation: keepsLocation)
            }.value
            guard !Task.isCancelled else { return }
            prepared = result
            preview = await Task.detached { PhotoPreview.image(from: result.data, longEdge: 900) }.value
            isWorking = false
        }
    }

    @ViewBuilder
    private var previewImage: some View {
        let shown = showsOriginal ? originalPreview : preview
        ZStack(alignment: .topLeading) {
            if let shown {
                Image(decorative: shown, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.quaternary)
                    .frame(height: 180)
                    .overlay { ProgressView() }
            }
            Text(showsOriginal ? "Original" : "As it will arrive")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.regularMaterial, in: Capsule())
                .padding(8)
        }
        .contentShape(Rectangle())
        .onLongPressGesture(minimumDuration: 0.15, maximumDistance: 40, perform: {}, onPressingChanged: { pressing in
            showsOriginal = pressing
        })
        .help("Press and hold to compare with the original.")
        .accessibilityLabel(showsOriginal ? "Original photo" : "The photo as it will arrive")
        .accessibilityHint("Press and hold to compare with the original")
    }

    @ViewBuilder
    private var summary: some View {
        if let prepared {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(ByteCount.string(Int64(prepared.data.count))) · \(prepared.pixelWidth) × \(prepared.pixelHeight) px"
                     + (prepared.isOriginal ? "" : " · was \(ByteCount.string(Int64(original.count)))"))
                    .font(.callout.monospacedDigit())
                if let hint = AirtimeHint.make(bytes: prepared.data.count,
                                               measuredBytesPerSecond: measuredBytesPerSecond, peer: peer) {
                    Text(hint.text.prefix(1).uppercased() + hint.text.dropFirst())
                        .font(.callout)
                        .foregroundStyle(hint.seconds > 20 * 60 ? .orange : .secondary)
                }
                if let note = prepared.note {
                    Text(note)
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }
            .opacity(isWorking ? 0.5 : 1)
        }
    }
}

/// A decoded copy of an image for showing on screen.
nonisolated enum PhotoPreview {
    static func image(from data: Data, longEdge: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: longEdge,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
