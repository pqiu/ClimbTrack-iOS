import AVFoundation
import SwiftUI

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let displayCrop: CGRect
    let orientedImageSize: CGSize

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        view.setDisplayCrop(displayCrop, orientedImageSize: orientedImageSize)
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.previewLayer.session = session
        uiView.setDisplayCrop(displayCrop, orientedImageSize: orientedImageSize)
    }
}

final class PreviewView: UIView {
    let previewLayer = AVCaptureVideoPreviewLayer()
    private var displayCrop = TrackingGeometry.unitRectangle
    private var orientedImageSize = CGSize.zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        layer.addSublayer(previewLayer)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        clipsToBounds = true
        layer.addSublayer(previewLayer)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        applyDisplayCrop()
    }

    func setDisplayCrop(_ crop: CGRect, orientedImageSize: CGSize) {
        displayCrop = TrackingGeometry.clipped(crop)
        self.orientedImageSize = orientedImageSize
        applyDisplayCrop()
    }

    private func applyDisplayCrop() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        guard orientedImageSize.width > 0,
              orientedImageSize.height > 0,
              displayCrop.width > 0,
              displayCrop.height > 0 else {
            previewLayer.frame = bounds
            return
        }

        // The recording first crops in normalized source-image coordinates and
        // then aspect-fills that crop. Size and position the preview layer using
        // the exact same geometry instead of approximating it in view space.
        let zoom = 1 / displayCrop.width
        let baseScale = max(
            bounds.width / orientedImageSize.width,
            bounds.height / orientedImageSize.height
        )
        let baseImageOrigin = CGPoint(
            x: (bounds.width - orientedImageSize.width * baseScale) / 2,
            y: (bounds.height - orientedImageSize.height * baseScale) / 2
        )
        let cropCenterInBasePreview = CGPoint(
            x: baseImageOrigin.x
                + displayCrop.midX * orientedImageSize.width * baseScale,
            y: baseImageOrigin.y
                + (1 - displayCrop.midY) * orientedImageSize.height * baseScale
        )
        let enlargedSize = CGSize(
            width: bounds.width * zoom,
            height: bounds.height * zoom
        )
        let enlargedOrigin = CGPoint(
            x: bounds.midX - cropCenterInBasePreview.x * zoom,
            y: bounds.midY - cropCenterInBasePreview.y * zoom
        )

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.setAffineTransform(.identity)
        previewLayer.frame = CGRect(origin: enlargedOrigin, size: enlargedSize)
        CATransaction.commit()
    }
}
