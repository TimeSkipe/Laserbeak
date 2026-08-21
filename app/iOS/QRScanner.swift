import SwiftUI
import AVFoundation

// Сканер QR-коду для підключення до ноута.
//
// Без нього телефон не запрацює взагалі: у коді лежить ключ доступу, а
// демон без ключа не віддає нічого. Заразом код несе адресу й імʼя ноута
// — на випадок, коли прямий канал не складеться і треба буде піти на
// демон по HTTP.

struct QRScannerView: View {
    var onScan: (Pairing) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var status: Status = .scanning

    enum Status: Equatable {
        case scanning
        case denied
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                switch status {
                case .scanning:
                    CameraPreview { code in
                        guard let parsed = Connection.parse(code) else {
                            status = .failed(String(localized: "Це не код Laserbeak"))
                            return
                        }
                        guard !parsed.token.isEmpty else {
                            status = .failed(String(localized: "У коді немає ключа — онови Laserbeak на маку"))
                            return
                        }
                        onScan(parsed)
                        dismiss()
                    } onDenied: {
                        status = .denied
                    }
                    .ignoresSafeArea()

                    // Рамка-підказка, куди наводити.
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(.white.opacity(0.85), lineWidth: 3)
                        .frame(width: 230, height: 230)

                case .denied:
                    message(
                        icon: "camera.fill",
                        title: String(localized: "Немає доступу до камери"),
                        text: String(localized: "Дозволь у Параметрах → Laserbeak → Камера.")
                    )

                case .failed(let reason):
                    message(icon: "questionmark.circle", title: reason,
                            text: String(localized: "Відкрий на маку «Підключити телефон» і наведи на той код."))
                }
            }
            .navigationTitle("Сканувати код")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Скасувати") { dismiss() }
                }

                if case .failed = status {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Ще раз") { status = .scanning }
                    }
                }
            }
        }
    }

    private func message(icon: String, title: String, text: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 32)
    }
}

// MARK: - Камера

/// Тонка обгортка над AVFoundation: SwiftUI не вміє камеру сам.
private struct CameraPreview: UIViewControllerRepresentable {
    var onCode: (String) -> Void
    var onDenied: () -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let controller = ScannerController()
        controller.onCode = onCode
        controller.onDenied = onDenied
        return controller
    }

    func updateUIViewController(_ controller: ScannerController, context: Context) {}
}

final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?
    var onDenied: (() -> Void)?

    private let session = AVCaptureSession()
    private var preview: AVCaptureVideoPreviewLayer?
    private var handled = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configure()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    granted ? self?.configure() : self?.onDenied?()
                }
            }
        default:
            onDenied?()
        }
    }

    private func configure() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input)
        else {
            onDenied?()
            return
        }

        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            onDenied?()
            return
        }

        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        preview = layer

        // Запуск камери блокує потік — тому в фоновому.
        Task.detached { [session] in
            session.startRunning()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        session.stopRunning()
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput objects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        // Один код — одна дія: інакше спрацює десятки разів за секунду.
        guard !handled,
              let object = objects.first as? AVMetadataMachineReadableCodeObject,
              let value = object.stringValue
        else { return }

        handled = true
        session.stopRunning()
        onCode?(value)
    }
}
