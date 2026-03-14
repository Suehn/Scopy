import AVKit
import SwiftUI

struct VideoPlayerPreviewView: NSViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView(frame: .zero)
        context.coordinator.configure(view: view, url: url)
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        context.coordinator.configure(view: nsView, url: url)
    }

    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: Coordinator) {
        coordinator.teardown(view: nsView)
    }

    final class Coordinator {
        private var currentURL: URL?
        private var endObserver: NSObjectProtocol?
        private weak var player: AVPlayer?

        func configure(view: AVPlayerView, url: URL) {
            guard currentURL?.path != url.path || view.player == nil else { return }

            teardown(view: view)
            currentURL = url

            let playerItem = AVPlayerItem(url: url)
            let player = AVPlayer(playerItem: playerItem)
            player.actionAtItemEnd = .pause
            player.isMuted = true
            player.volume = 0

            view.player = player
            view.controlsStyle = .floating
            view.videoGravity = .resizeAspect
            view.allowsMagnification = false
            view.showsFrameSteppingButtons = false
            view.showsSharingServiceButton = false
            view.showsFullScreenToggleButton = false
            view.updatesNowPlayingInfoCenter = false
            view.allowsPictureInPicturePlayback = false

            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: playerItem,
                queue: .main
            ) { [weak player] _ in
                player?.seek(to: .zero)
                player?.pause()
            }

            self.player = player
            player.play()
        }

        func teardown(view: AVPlayerView) {
            if let endObserver {
                NotificationCenter.default.removeObserver(endObserver)
                self.endObserver = nil
            }
            player?.pause()
            player?.replaceCurrentItem(with: nil)
            player = nil
            view.player = nil
            currentURL = nil
        }
    }
}
