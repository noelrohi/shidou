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

final class QRScannerViewController: UIViewController {
    var onScan: ((String) -> Void)?
    var onFailure: ((QRScannerView.Failure) -> Void)?

    /// `AVCaptureSession` is not `Sendable`, but Apple documents it as safe
    /// to drive from one serial queue. `sessionQueue` is that queue, and this
    /// box is what tells the compiler so — narrower than making the whole
    /// file `@preconcurrency` and losing every other AVFoundation warning.
    private struct SessionBox: @unchecked Sendable {
        let session: AVCaptureSession
    }

    private let box = SessionBox(session: AVCaptureSession())
    private var session: AVCaptureSession { box.session }
    /// Starting and stopping the session both block, so neither happens on
    /// the thread drawing the sheet's presentation animation.
    private let sessionQueue = DispatchQueue(label: "dev.shidou.ios.camera")
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
        // The main queue, which is what lets the delegate callback below
        // assume main-actor isolation.
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
        sessionQueue.async { [box] in
            guard !box.session.isRunning else { return }
            box.session.startRunning()
        }
    }

    private func stop() {
        sessionQueue.async { [box] in
            guard box.session.isRunning else { return }
            box.session.stopRunning()
        }
    }

    fileprivate func report(_ value: String) {
        guard !hasReported else { return }
        hasReported = true
        // The only evidence this delegate ever fired; a camera that reads
        // nothing is indistinguishable on screen from a user aiming badly.
        pairingLog.info("camera read a code")
        stop()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        onScan?(value)
    }
}

extension QRScannerViewController: AVCaptureMetadataOutputObjectsDelegate {
    nonisolated func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput objects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        // Only the decoded string crosses; the metadata objects themselves
        // are not `Sendable` and have nothing else this view needs.
        let value = objects
            .compactMap { ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }
            .first
        guard let value else { return }
        // `configure` set `.main` as the delegate queue, so this already runs
        // on the main actor — the protocol just cannot say so.
        MainActor.assumeIsolated { self.report(value) }
    }
}
