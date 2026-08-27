import AVFoundation
import SwiftUI
import UIKit

/// The camera half of pairing: a live capture session that reports the first
/// QR payload it reads and then stops, so a code cannot fire twice while the
/// sheet dismisses.
struct QRScannerView: UIViewControllerRepresentable {
    enum Failure: Error, Equatable {
        case cameraUnavailable
        case permissionDenied
    }

    let onScan: (String) -> Void
    let onFailure: (Failure) -> Void

    func makeUIViewController(context: Context) -> QRScannerViewController {
        let controller = QRScannerViewController()
        controller.onScan = onScan
        controller.onFailure = onFailure
        return controller
    }

    func updateUIViewController(_ controller: QRScannerViewController, context: Context) {
        controller.onScan = onScan
        controller.onFailure = onFailure
    }
}

final class QRScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onScan: ((String) -> Void)?
    var onFailure: ((QRScannerView.Failure) -> Void)?

    private let session = AVCaptureSession()
    private var preview: AVCaptureVideoPreviewLayer?
    private var hasReported = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configure()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor in
                    guard let self else { return }
                    if granted {
                        self.configure()
                    } else {
                        self.onFailure?(.permissionDenied)
                    }
                }
            }
        case .denied, .restricted:
            onFailure?(.permissionDenied)
        @unknown default:
            onFailure?(.permissionDenied)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stop()
    }

    private func configure() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input)
        else {
            onFailure?(.cameraUnavailable)
            return
        }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            onFailure?(.cameraUnavailable)
            return
        }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        view.layer.addSublayer(preview)
        self.preview = preview

        view.accessibilityLabel = String(localized: "Camera viewfinder. Point it at the pairing code on your Mac.")
        view.isAccessibilityElement = true

        start()
    }

    private func start() {
        guard !session.isRunning else { return }
        // Starting the session blocks; keeping it off the main thread is what
        // stops the sheet's presentation animation from stuttering.
        Task.detached(priority: .userInitiated) { [session] in
            session.startRunning()
        }
    }

    private func stop() {
        guard session.isRunning else { return }
        Task.detached(priority: .userInitiated) { [session] in
            session.stopRunning()
        }
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput objects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !hasReported else { return }
        guard let code = objects.compactMap({ $0 as? AVMetadataMachineReadableCodeObject }).first,
              let value = code.stringValue
        else { return }
        hasReported = true
        // The only evidence this delegate ever fired; a camera that reads
        // nothing is indistinguishable on screen from a user aiming badly.
        pairingLog.info("camera read a code")
        stop()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        onScan?(value)
    }
}
