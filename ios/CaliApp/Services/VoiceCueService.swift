import AVFoundation
import CaliCore
import CaliDomain
import Foundation
import UIKit
import UserNotifications

/// IOS-019 (CON-010, ADR-078): spoken cues during a workout.
///
/// - Foreground: the cue file plays with `AVAudioPlayer` at its due time (session `.playback` + `.duckOthers`: heard with
///   the ringer switch on silent, music is lowered, not stopped).
/// - Background or locked: the cue rides on a local notification scheduled ahead, whose sound is the downloaded file in
///   `Library/Sounds`. The cue at the phase deadline is the sound of the existing deadline reminder (one notification,
///   not two). iOS does not present notifications to an app in the foreground (no delegate), so nothing plays twice.
///
/// A cue is advisory only: nothing here changes workout state, and nothing runs in a notification callback (AGENTS).
/// Missing pack or file: the default sound. Voice off in Settings: no sound at all from cues.
@MainActor
final class VoiceCueService {
    static let requestPrefix = "cali.voice."
    /// A due cue found this late (the app was suspended) is not played: an old prompt is worse than none.
    static let lateTolerance: TimeInterval = 2

    var library: VoiceCueLibrary = .empty
    let soundsDirectory: URL

    private var timers: [Task<Void, Never>] = []
    private var played: Set<String> = []
    private var player: AVAudioPlayer?
    private lazy var finish = PlaybackFinish { [weak self] in self?.didFinishPlaying() }

    init(soundsDirectory: URL = VoicePackStore.defaultSoundsDirectory) {
        self.soundsDirectory = soundsDirectory
    }

    /// Sentence shown with a cue (the pack's text, else the bundled one).
    func text(for key: VoiceCueKey) -> String { library[key]?.text ?? key.defaultText }

    /// Sound for a notification carrying `key`: the downloaded file, else the default sound; `nil` when voice is off.
    func notificationSound(for key: VoiceCueKey, enabled: Bool) -> UNNotificationSound? {
        guard enabled else { return nil }
        guard let file = library[key]?.soundFile else { return .default }
        return UNNotificationSound(named: UNNotificationSoundName(file))
    }

    /// Replaces every scheduled cue with the plan of `state` (called on each accepted transition, like the reminder).
    /// - Parameters:
    ///   - enabled: the voice setting.
    ///   - notificationsAllowed: the reminder setting; without it background cues are not scheduled.
    func sync(state: SessionState?, enabled: Bool, notificationsAllowed: Bool, now: Date = Date()) {
        cancelScheduled()
        guard enabled, let state, state.isActive || state.phase == .completed else { return }
        let plan = VoiceCuePlan.cues(for: state)
        for cue in plan {
            let id = "\(state.sessionId.uuidString)|\(cue.key.rawValue)|\(cue.at.timeIntervalSince1970)"
            guard !played.contains(id) else { continue }
            let delay = cue.at.timeIntervalSince(now)
            if delay < -Self.lateTolerance { continue }
            timers.append(Task { [weak self] in
                if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                guard !Task.isCancelled else { return }
                self?.playIfForeground(cue.key, id: id)
            })
            // The deadline cue is the deadline reminder's sound (NotificationService); the others get their own request.
            if notificationsAllowed, !cue.isPhaseDeadline, delay > 1, cue.key != .sessionDone {
                schedule(cue, after: delay)
            }
        }
    }

    func cancelAll() {
        cancelScheduled()
        player?.stop()
        player = nil
    }

    private func cancelScheduled() {
        timers.forEach { $0.cancel() }
        timers = []
        let center = UNUserNotificationCenter.current()
        let ids = VoiceCueKey.allCases.map { Self.requestPrefix + $0.rawValue }
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    private func schedule(_ cue: PlannedVoiceCue, after delay: TimeInterval) {
        let content = UNMutableNotificationContent()
        content.title = "COAMI"
        content.body = text(for: cue.key)
        content.sound = notificationSound(for: cue.key, enabled: true)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: Self.requestPrefix + cue.key.rawValue, content: content, trigger: trigger))
    }

    private func playIfForeground(_ key: VoiceCueKey, id: String) {
        // In the background the notification plays it; playing here as well would be heard twice.
        guard UIApplication.shared.applicationState == .active else { return }
        played.insert(id)
        guard let file = library[key]?.soundFile else { return } // no pack yet: the haptic and the screen remain
        let url = soundsDirectory.appendingPathComponent(file)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true)
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = finish
            player.play()
            self.player = player
        } catch {
            player = nil
        }
    }

    private func didFinishPlaying() {
        guard player?.isPlaying != true else { return }
        player = nil
        // Give the music its volume back.
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

/// `AVAudioPlayerDelegate` kept apart from the service, so the service stays a plain main-actor class.
private final class PlaybackFinish: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
    private let done: @MainActor () -> Void

    init(_ done: @escaping @MainActor () -> Void) { self.done = done }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let done = self.done
        Task { @MainActor in done() }
    }
}
