#if os(iOS)
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The camera, for a photo taken straight into a message.
///
/// SwiftUI has no camera view, so this wraps `UIImagePickerController`. It is
/// only offered where `isAvailable` says there is a camera: the simulator and
/// some iPads have none, and a menu item that opens a black screen is worse
/// than no menu item.
struct ComposeCameraPicker: UIViewControllerRepresentable {

    /// Called with the photo as JPEG, or nil when the operator canceled.
    var onFinish: (Data?) -> Void

    static var isAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = [UTType.image.identifier]
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onFinish: (Data?) -> Void

        init(onFinish: @escaping (Data?) -> Void) { self.onFinish = onFinish }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            // High quality here on purpose. This is the original the operator
            // can choose to send, and the shrinker makes the small copy.
            let image = info[.originalImage] as? UIImage
            onFinish(image?.jpegData(compressionQuality: 0.9))
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onFinish(nil)
        }
    }
}
#endif
