import SwiftUI
import UIKit
import AVFoundation

/// Shows an `AVPlayer`'s video and nothing else.
///
/// Deliberately not `VideoPlayer`, which brings AVKit's transport chrome — a scrubber, a play/pause
/// button, a skip-forward control. On a live feed every one of those is meaningless and two of them
/// leave the user staring at a stalled frame with no obvious way back. The layer alone is the whole
/// picture.
///
/// Lives here rather than in `CameraModal` because nothing about it is camera-specific: it wraps an
/// `AVPlayerLayer` and knows nothing about what is playing.
struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerHostView {
        let view = PlayerHostView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: PlayerHostView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }
}

/// A `UIView` whose backing layer *is* the `AVPlayerLayer`, so the video sizes with the view for
/// free rather than needing its frame kept in step by hand.
final class PlayerHostView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}
