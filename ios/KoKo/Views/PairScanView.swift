import SwiftUI
import AVFoundation

/// QR scanner for RunEverything pairing (v3 JSON / koko://pair).
struct PairScanView: View {
    @Environment(\.dismiss) private var dismiss
    /// HostList `connecting` — false after failure lets the user scan again.
    @Binding var pairingInFlight: Bool
    var onPayload: (RE2PairingPayload) -> Void

    @State private var errorText: String?
    @State private var torchOn = false
    @State private var scanEpoch = 0

    var body: some View {
        NavigationStack {
            ZStack {
                QRScannerRepresentable(
                    scanEpoch: scanEpoch,
                    onCode: { raw in
                        do {
                            let payload = try RE2PairingPayload.parse(raw)
                            errorText = nil
                            onPayload(payload)
                            dismiss()
                        } catch {
                            errorText = error.localizedDescription
                            scanEpoch &+= 1 // allow another scan
                        }
                    },
                    torchOn: torchOn
                )
                .ignoresSafeArea()

                VStack {
                    Spacer()
                    Text(pairingInFlight
                         ? String(localized: "Connecting…")
                         : String(localized: "Scan the Agent QR code"))
                        .font(.headline)
                        .padding(12)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                        .padding()
                    if let errorText {
                        Text(errorText)
                            .foregroundStyle(.red)
                            .padding(.bottom, 8)
                    }
                }
            }
            .navigationTitle(String(localized: "Pair Desktop"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        torchOn.toggle()
                    } label: {
                        Image(systemName: torchOn ? "flashlight.on.fill" : "flashlight.off.fill")
                    }
                }
            }
            .onChange(of: pairingInFlight) { _, inflight in
                if !inflight {
                    // Connect failed / cancelled — re-arm camera for another scan.
                    scanEpoch &+= 1
                }
            }
        }
    }
}

/// Manual paste fallback when camera unavailable.
struct PairPasteView: View {
    @Environment(\.dismiss) private var dismiss
    var onPayload: (RE2PairingPayload) -> Void
    @State private var text = ""
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text)
                        .frame(minHeight: 120)
                } header: {
                    Text(String(localized: "Paste QR JSON or koko://pair link"))
                }
                if let errorText {
                    Section {
                        Text(errorText).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(String(localized: "Paste Pairing"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Pair")) {
                        do {
                            let payload = try RE2PairingPayload.parse(text)
                            onPayload(payload)
                            dismiss()
                        } catch {
                            errorText = error.localizedDescription
                        }
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

struct QRScannerRepresentable: UIViewControllerRepresentable {
    var scanEpoch: Int
    var onCode: (String) -> Void
    var torchOn: Bool

    func makeUIViewController(context: Context) -> QRScannerViewController {
        let vc = QRScannerViewController()
        vc.onCode = onCode
        return vc
    }

    func updateUIViewController(_ uiViewController: QRScannerViewController, context: Context) {
        uiViewController.onCode = onCode
        uiViewController.setTorch(torchOn)
        uiViewController.applyScanEpoch(scanEpoch)
    }
}

final class QRScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?
    private let session = AVCaptureSession()
    private var preview: AVCaptureVideoPreviewLayer?
    private var handled = false
    private var appliedEpoch = 0

    func applyScanEpoch(_ epoch: Int) {
        guard epoch != appliedEpoch else { return }
        appliedEpoch = epoch
        handled = false
        if !session.isRunning {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.session.startRunning()
            }
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        guard
            let device = AVCaptureDevice.default(for: .video),
            let input = try? AVCaptureDeviceInput(device: device),
            session.canAddInput(input)
        else { return }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        preview = layer
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.session.startRunning()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    func setTorch(_ on: Bool) {
        guard let device = AVCaptureDevice.default(for: .video), device.hasTorch else { return }
        try? device.lockForConfiguration()
        device.torchMode = on ? .on : .off
        device.unlockForConfiguration()
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !handled,
              let obj = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let value = obj.stringValue
        else { return }
        handled = true
        session.stopRunning()
        onCode?(value)
    }
}
