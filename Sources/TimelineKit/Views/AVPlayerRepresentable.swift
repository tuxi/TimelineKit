#if canImport(UIKit)
import SwiftUI
import AVFoundation

/// UIViewRepresentable that hosts an AVPlayerLayer.
/// The view owns only the display layer; the AVPlayer is owned by EditorStore.
struct AVPlayerRepresentable: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerHostView {
        let view = PlayerHostView()
        view.player = player
        return view
    }

    func updateUIView(_ uiView: PlayerHostView, context: Context) {
        if uiView.player !== player {
            uiView.player = player
        }
    }
}

// MARK: -

final class PlayerHostView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    var player: AVPlayer? {
        get { playerLayer.player }
        set {
            playerLayer.player = newValue
            playerLayer.videoGravity = .resizeAspect
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
    }

    required init?(coder: NSCoder) { fatalError() }
}
#endif
