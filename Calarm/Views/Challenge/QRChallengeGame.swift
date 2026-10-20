//
//  QRChallengeGame.swift
//  Calarm
//

import AVFoundation
import SwiftUI
import VisionKit

/// Hay que escanear EL código registrado al configurar el reto: el de la pasta
/// de dientes, uno pegado en la cocina… lo que obligue a levantarse.
struct QRChallengeGame: View {
    let expectedCode: String
    let onSolved: () -> Void

    @State private var mismatch = false

    var body: some View {
        VStack(spacing: DS.Spacing.md) {
            Text("Apunta la cámara al código registrado")
                .font(.headline)
                .multilineTextAlignment(.center)

            CodeScannerView { code in
                if code == expectedCode {
                    onSolved()
                } else {
                    withAnimation(DS.Motion.quick) { mismatch = true }
                    Haptics.error()
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 340)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous))

            Text("Ese no es el código registrado.")
                .font(.footnote)
                .foregroundStyle(.red)
                .opacity(mismatch ? 1 : 0)
                .accessibilityHidden(!mismatch)
        }
    }
}

/// Lector de códigos QR y de barras (VisionKit), con el permiso de cámara
/// resuelto aquí mismo. Se usa para registrar el código en el editor y para
/// escanearlo al sonar la alarma.
struct CodeScannerView: View {
    let onScan: (String) -> Void

    @State private var cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)

    var body: some View {
        Group {
            if !DataScannerViewController.isSupported {
                message("Este dispositivo no puede escanear códigos.", systemImage: "camera.badge.ellipsis")
            } else {
                switch cameraStatus {
                case .authorized:
                    DataScannerRepresentable(onScan: onScan)
                case .notDetermined:
                    ProgressView()
                        .task {
                            let granted = await AVCaptureDevice.requestAccess(for: .video)
                            cameraStatus = granted ? .authorized : .denied
                        }
                default:
                    VStack(spacing: DS.Spacing.md) {
                        message("Calarm necesita la cámara para leer el código. Actívala en Ajustes.", systemImage: "camera.fill")
                        Button("Abrir Ajustes") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.secondarySystemBackground))
    }

    private func message(_ text: LocalizedStringKey, systemImage: String) -> some View {
        VStack(spacing: DS.Spacing.sm) {
            Image(systemName: systemImage)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
}

private struct DataScannerRepresentable: UIViewControllerRepresentable {
    let onScan: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(
            recognizedDataTypes: [.barcode()],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isHighlightingEnabled: true
        )
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {
        context.coordinator.onScan = onScan
        if !controller.isScanning, DataScannerViewController.isAvailable {
            try? controller.startScanning()
        }
    }

    static func dismantleUIViewController(_ controller: DataScannerViewController, coordinator: Coordinator) {
        controller.stopScanning()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onScan: onScan)
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var onScan: (String) -> Void
        private var lastCode: String?
        private var lastScan: Date = .distantPast

        init(onScan: @escaping (String) -> Void) {
            self.onScan = onScan
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            for item in addedItems {
                guard case .barcode(let barcode) = item, let code = barcode.payloadStringValue else { continue }
                report(code)
            }
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didTapOn item: RecognizedItem) {
            guard case .barcode(let barcode) = item, let code = barcode.payloadStringValue else { return }
            report(code)
        }

        /// El mismo código reaparece muchas veces por segundo mientras se apunta:
        /// se avisa una vez y, como mucho, otra vez al segundo y medio.
        private func report(_ code: String) {
            let now = Date()
            if code == lastCode, now.timeIntervalSince(lastScan) < 1.5 { return }
            lastCode = code
            lastScan = now
            onScan(code)
        }
    }
}
