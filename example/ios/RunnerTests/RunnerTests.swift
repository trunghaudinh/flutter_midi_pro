import AVFAudio
@testable import flutter_midi_pro
import XCTest

class RunnerTests: XCTestCase {
  func testBankInfoUsesPercussionMSBForBank128() {
    let info = SoundfontBankInfo(bank: 128)
    XCTAssertTrue(info.isPercussion)
    XCTAssertEqual(info.bankMSB, UInt8(kAUSampler_DefaultPercussionBankMSB))
    XCTAssertEqual(info.bankLSB, 0)
  }

  func testBankInfoKeepsMelodicBankLSB() {
    let info = SoundfontBankInfo(bank: 5)
    XCTAssertFalse(info.isPercussion)
    XCTAssertEqual(info.bankMSB, UInt8(kAUSampler_DefaultMelodicBankMSB))
    XCTAssertEqual(info.bankLSB, 5)
  }

  func testSoundfontStateBuildsSingleEngineAndSixteenSamplers() {
    let state = SoundfontState.makeEmpty(
      channelCount: 16,
      url: URL(fileURLWithPath: "/tmp/test.sf2"),
      initialConfiguration: SamplerConfiguration(bank: 0, program: 0)
    )
    XCTAssertEqual(state.samplers.count, 16)
    XCTAssertEqual(state.samplerConfigurations.count, 16)
    XCTAssertNotNil(state.engine)
  }

  func testSoundfontStateBuildsSamplersWithPerChannelConfigurations() {
    let configurations = (0..<16).map { SamplerConfiguration(bank: 0, program: $0) }

    let state = SoundfontState.makeEmpty(
      channelCount: 16,
      url: URL(fileURLWithPath: "/tmp/test.sf2"),
      samplerConfigurations: configurations
    )

    XCTAssertEqual(state.samplers.count, 16)
    XCTAssertEqual(state.samplerConfigurations.map(\.program), Array(0..<16))
  }

  func testPluginLoadErrorDescribesInvalidSamplerConfigurationCount() {
    let error = PluginLoadError.invalidSamplerConfigurationCount(expected: 16, actual: 2)

    XCTAssertEqual(
      error.localizedDescription,
      "Invalid sampler configuration count. Expected 16, got 2."
    )
  }

  func testPluginLoadErrorDescribesMissingSoundfontState() {
    XCTAssertEqual(PluginLoadError.soundfontStateUnavailable.localizedDescription, "Soundfont state unavailable.")
  }

  func testPluginLoadErrorDescribesInvalidMidiValue() {
    let error = PluginLoadError.invalidMidiValue(name: "program", value: 200)

    XCTAssertEqual(error.localizedDescription, "Invalid MIDI value for program: 200.")
  }

  func testAudioSessionRecoveryResumesOnInterruptionEndWhenResumeFlagIsSet() {
    let userInfo: [AnyHashable: Any] = [
      AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
      AVAudioSessionInterruptionOptionKey: AVAudioSession.InterruptionOptions.shouldResume.rawValue,
    ]

    XCTAssertEqual(
      AudioSessionRecoveryAction.interruption(userInfo),
      .reconfigureAndRestart
    )
  }

  func testAudioSessionRecoveryIgnoresInterruptionEndWhenResumeFlagIsMissing() {
    let userInfo: [AnyHashable: Any] = [
      AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
      AVAudioSessionInterruptionOptionKey: UInt(0),
    ]

    XCTAssertEqual(AudioSessionRecoveryAction.interruption(userInfo), .none)
  }

  func testAudioSessionRecoveryReconfiguresForRouteChangesThatAffectOutput() {
    let userInfo: [AnyHashable: Any] = [
      AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue
    ]

    XCTAssertEqual(AudioSessionRecoveryAction.routeChange(userInfo), .reconfigureAndRestart)
  }
}
