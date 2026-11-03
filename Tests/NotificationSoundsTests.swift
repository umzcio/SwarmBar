import Foundation
import Testing
@testable import SwarmBar

struct NotificationSoundsTests {
    private func system(_ names: String...) -> [URL] {
        names.map { URL(fileURLWithPath: "/System/Library/Sounds/\($0)") }
    }
    private func user(_ names: String...) -> [URL] {
        names.map { URL(fileURLWithPath: "/Users/someone/Library/Sounds/\($0)") }
    }

    @Test func listsSoundsByNameInAlphabeticalOrder() {
        let options = NotificationSounds.options(
            user: user("yodel.aiff"), system: system("Ping.aiff", "Glass.aiff"))
        #expect(options.map(\.name) == ["Glass", "Ping", "yodel"])
    }

    /// A file macOS cannot play would sit in the menu and alert with the
    /// wrong sound, so it is left out rather than offered.
    @Test func leavesOutFilesNotificationsCannotPlay() {
        let options = NotificationSounds.options(
            user: user("song.mp3", "memo.m4a", "notes.txt", ".DS_Store", "a.caf", "b.WAV", "c.aif"),
            system: [])
        #expect(options.map(\.name) == ["a", "b", "c"])
    }

    @Test func aUsersSoundReplacesASystemSoundOfTheSameName() {
        let mine = user("Glass.wav")
        let options = NotificationSounds.options(user: mine, system: system("Glass.aiff"))
        #expect(options.map(\.url) == mine)
    }

    @Test func aChosenSoundResolvesToItsFile() {
        let options = NotificationSounds.options(user: user("Yeehaw.aiff"), system: [])
        let sound = NotificationSounds.alertSound(enabled: true, chosen: "Yeehaw", options: options)
        #expect(sound == .file("Yeehaw.aiff"))
    }

    @Test func nothingChosenUsesTheStandardSound() {
        let options = NotificationSounds.options(user: [], system: system("Glass.aiff"))
        #expect(NotificationSounds.alertSound(enabled: true, chosen: nil, options: options) == .standard)
        #expect(NotificationSounds.alertSound(enabled: true, chosen: "", options: options) == .standard)
    }

    /// Deleting a custom file must not silence approvals: the alert still
    /// has to make a noise, or the agent just sits there unanswered.
    @Test func aChosenSoundThatWasDeletedFallsBackToTheStandardSound() {
        let options = NotificationSounds.options(user: [], system: system("Glass.aiff"))
        let sound = NotificationSounds.alertSound(enabled: true, chosen: "Yeehaw", options: options)
        #expect(sound == .standard)
    }

    @Test func theSoundSwitchSilencesWhateverIsChosen() {
        let options = NotificationSounds.options(user: [], system: system("Glass.aiff"))
        let sound = NotificationSounds.alertSound(enabled: false, chosen: "Glass", options: options)
        #expect(sound == .silent)
    }

    /// These are the saved settings' names; changing one forgets a choice.
    @Test func eachKindOfAlertKeepsItsOwnChoice() {
        #expect(NotificationSounds.Kind.approval.defaultsKey == "approvalSound")
        #expect(NotificationSounds.Kind.waiting.defaultsKey == "waitingSound")
    }
}
