import AVFAudio
import SwiftUI
import WisperLive
import WisperPhone

/// Open Wisper for iPhone. The whole app is `RootScreen`, in the `WisperPhone` module;
/// this target adds the entry point and the App Intents.
@main
struct OpenWisperApp: App {
  init() {
    // iOS mutes taps and system sounds while the microphone is open. The tap that says
    // "recording stopped" matters most exactly then.
    try? AVAudioSession.sharedInstance().setAllowHapticsAndSystemSoundsDuringRecording(true)
    // The Stop button on the Lock Screen runs here, in the app, even when no screen is up.
    MeetingActivity.stopRecording = { _ = await PhoneSession.shared.stopMeeting() }
  }

  var body: some Scene {
    WindowGroup {
      RootScreen()
    }
  }
}
