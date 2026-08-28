import SwiftUI
import UIKit

/// The camera, for attaching a photo to a prompt.
///
/// `PhotosPicker` covers the library without asking for permission; the camera
/// is the one that needs `UIImagePickerController` and a usage description,
/// so it is the only part wrapped here.
struct CameraPicker: UIViewControllerRepresentable {
    let onCapture: (Data, String) -> Void

    @Environment(\.dismiss) private var dismiss

    static var isAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let controller = UIImagePickerController()
        controller.sourceType = .camera
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(picker: self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate,
        UINavigationControllerDelegate
    {
        private let picker: CameraPicker

        init(picker: CameraPicker) {
            self.picker = picker
        }

        func imagePickerController(
            _ controller: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            defer { picker.dismiss() }
            guard let image = info[.originalImage] as? UIImage,
                // JPEG rather than PNG: a camera frame is a photograph, and a
                // lossless copy of one is megabytes of wire for no benefit.
                let data = image.jpegData(compressionQuality: 0.85)
            else { return }
            picker.onCapture(data, "photo.jpg")
        }

        func imagePickerControllerDidCancel(_ controller: UIImagePickerController) {
            picker.dismiss()
        }
    }
}
