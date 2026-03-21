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
    let state = SoundfontState.makeEmpty(channelCount: 16)
    XCTAssertEqual(state.samplers.count, 16)
    XCTAssertNotNil(state.engine)
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
