import Foundation
import MediaPlayer
import UIKit

/// Lock-screen / Control Center / AirPods stem controls for an active review.
@MainActor
final class NowPlayingSession {
    static let shared = NowPlayingSession()

    enum RemoteAction: Sendable {
        case pause
        case resume
        case skip
        case `repeat`
    }

    var onRemote: ((RemoteAction) -> Void)?

    private var commandsInstalled = false
    private var lastTitle = ""
    private var lastAlbum = ""
    private var lastPlaying: Bool?

    private init() {}

    func activate() {
        installCommandsIfNeeded()
        UIApplication.shared.beginReceivingRemoteControlEvents()
        update(
            deckName: "Rounds Voice",
            detail: "Starting review…",
            isPlaying: true
        )
    }

    func deactivate() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        lastTitle = ""
        lastAlbum = ""
        lastPlaying = nil
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.removeTarget(nil)
        center.pauseCommand.removeTarget(nil)
        center.nextTrackCommand.removeTarget(nil)
        center.previousTrackCommand.removeTarget(nil)
        center.togglePlayPauseCommand.removeTarget(nil)
        commandsInstalled = false
        onRemote = nil
    }

    func update(deckName: String, detail: String, isPlaying: Bool) {
        installCommandsIfNeeded()
        let title = String(detail.prefix(80))
        // Skip identical updates — caption thrash was hammering MPNowPlayingInfoCenter.
        if title == lastTitle, deckName == lastAlbum, lastPlaying == isPlaying {
            return
        }
        lastTitle = title
        lastAlbum = deckName
        lastPlaying = isPlaying
        let info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: "Rounds Voice",
            MPMediaItemPropertyAlbumTitle: deckName,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: 0,
            MPMediaItemPropertyPlaybackDuration: 60 * 60
        ]
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func installCommandsIfNeeded() {
        guard !commandsInstalled else { return }
        commandsInstalled = true
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.togglePlayPauseCommand.isEnabled = true
        center.nextTrackCommand.isEnabled = true
        center.previousTrackCommand.isEnabled = true

        center.playCommand.addTarget { [weak self] _ in
            self?.onRemote?(.resume)
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            self?.onRemote?(.pause)
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.onRemote?(.pause)
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            self?.onRemote?(.skip)
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            self?.onRemote?(.repeat)
            return .success
        }
    }
}
