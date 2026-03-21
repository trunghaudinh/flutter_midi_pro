import AVFAudio
import AVFoundation
import CoreAudio
import CoreMIDI
import Flutter

public struct SoundfontBankInfo {
  public let isPercussion: Bool
  public let bankMSB: UInt8
  public let bankLSB: UInt8

  public init(bank: Int) {
    let percussion = bank == 128
    isPercussion = percussion
    bankMSB = percussion ? UInt8(kAUSampler_DefaultPercussionBankMSB) : UInt8(kAUSampler_DefaultMelodicBankMSB)
    bankLSB = percussion ? 0 : UInt8(bank)
  }
}

public final class SoundfontState {
  public let engine: AVAudioEngine
  public let samplers: [AVAudioUnitSampler]
  public let url: URL

  public init(engine: AVAudioEngine, samplers: [AVAudioUnitSampler], url: URL) {
    self.engine = engine
    self.samplers = samplers
    self.url = url
  }

  public static func makeEmpty(channelCount: Int) -> SoundfontState {
    let engine = AVAudioEngine()
    var samplers: [AVAudioUnitSampler] = []
    samplers.reserveCapacity(channelCount)

    for _ in 0..<channelCount {
      let sampler = AVAudioUnitSampler()
      engine.attach(sampler)
      engine.connect(sampler, to: engine.mainMixerNode, format: nil)
      samplers.append(sampler)
    }

    return SoundfontState(engine: engine, samplers: samplers, url: URL(fileURLWithPath: "/dev/null"))
  }

  public func withURL(_ url: URL) -> SoundfontState {
    SoundfontState(engine: engine, samplers: samplers, url: url)
  }
}

private enum PluginLoadError: Error {
  case audioEngineStartFailed(String)
}

enum AudioSessionRecoveryAction: Equatable {
  case none
  case reconfigureAndRestart

  static func interruption(_ userInfo: [AnyHashable: Any]?) -> AudioSessionRecoveryAction {
    guard let userInfo,
          let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
          let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
      return .none
    }

    guard type == .ended else {
      return .none
    }

    guard let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt else {
      return .reconfigureAndRestart
    }

    let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
    return options.contains(.shouldResume) ? .reconfigureAndRestart : .none
  }

  static func routeChange(_ userInfo: [AnyHashable: Any]?) -> AudioSessionRecoveryAction {
    guard let userInfo,
          let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
          let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
      return .none
    }

    switch reason {
    case .newDeviceAvailable, .oldDeviceUnavailable, .routeConfigurationChange:
      return .reconfigureAndRestart
    default:
      return .none
    }
  }
}

public class FlutterMidiProPlugin: NSObject, FlutterPlugin {
  private let channelCount = 16
  private let workQueue = DispatchQueue(label: "flutter_midi_pro.audio.work", qos: .userInitiated)
  private let stateQueue = DispatchQueue(label: "flutter_midi_pro.audio.state")
  private var soundfontIndex = 1
  private var soundfonts: [Int: SoundfontState] = [:]

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "flutter_midi_pro", binaryMessenger: registrar.messenger())
    let instance = FlutterMidiProPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  public override init() {
    super.init()
    configureAudioSession()
    setupAudioSessionNotifications()
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "loadSoundfont":
      guard let args = call.arguments as? [String: Any],
            let path = args["path"] as? String,
            let bank = args["bank"] as? Int,
            let program = args["program"] as? Int else {
        result(FlutterError(code: "INVALID_ARGUMENTS", message: "Missing soundfont arguments", details: nil))
        return
      }
      loadSoundfont(path: path, bank: bank, program: program, result: result)
    case "stopAllNotes":
      guard let args = call.arguments as? [String: Any],
            let sfId = args["sfId"] as? Int,
            let soundfont = soundfontState(for: sfId) else {
        result(FlutterError(code: "SOUND_FONT_NOT_FOUND", message: "Soundfont not found", details: nil))
        return
      }
      for (channel, sampler) in soundfont.samplers.enumerated() {
        sampler.sendController(64, withValue: 0, onChannel: UInt8(channel))
        sampler.sendController(120, withValue: 0, onChannel: UInt8(channel))
      }
      result(nil)
    case "controlChange":
      guard let args = call.arguments as? [String: Any],
            let sfId = args["sfId"] as? Int,
            let channel = args["channel"] as? Int,
            let controller = args["controller"] as? Int,
            let value = args["value"] as? Int,
            let sampler = sampler(for: sfId, channel: channel) else {
        result(FlutterError(code: "SOUND_FONT_NOT_FOUND", message: "Soundfont/channel not found", details: nil))
        return
      }
      sampler.sendController(UInt8(controller), withValue: UInt8(value), onChannel: UInt8(channel))
      result(nil)
    case "selectInstrument":
      guard let args = call.arguments as? [String: Any],
            let sfId = args["sfId"] as? Int,
            let channel = args["channel"] as? Int,
            let bank = args["bank"] as? Int,
            let program = args["program"] as? Int else {
        result(FlutterError(code: "INVALID_ARGUMENTS", message: "Missing instrument arguments", details: nil))
        return
      }
      selectInstrument(sfId: sfId, channel: channel, bank: bank, program: program, result: result)
    case "playNote":
      guard let args = call.arguments as? [String: Any],
            let channel = args["channel"] as? Int,
            let note = args["key"] as? Int,
            let velocity = args["velocity"] as? Int,
            let sfId = args["sfId"] as? Int,
            let sampler = sampler(for: sfId, channel: channel) else {
        result(FlutterError(code: "SOUND_FONT_NOT_FOUND", message: "Soundfont/channel not found", details: nil))
        return
      }
      sampler.startNote(UInt8(note), withVelocity: UInt8(velocity), onChannel: UInt8(channel))
      result(nil)
    case "stopNote":
      guard let args = call.arguments as? [String: Any],
            let channel = args["channel"] as? Int,
            let note = args["key"] as? Int,
            let sfId = args["sfId"] as? Int,
            let sampler = sampler(for: sfId, channel: channel) else {
        result(FlutterError(code: "SOUND_FONT_NOT_FOUND", message: "Soundfont/channel not found", details: nil))
        return
      }
      sampler.stopNote(UInt8(note), onChannel: UInt8(channel))
      result(nil)
    case "unloadSoundfont":
      guard let args = call.arguments as? [String: Any],
            let sfId = args["sfId"] as? Int,
            let soundfont = removeSoundfont(for: sfId) else {
        result(FlutterError(code: "SOUND_FONT_NOT_FOUND", message: "Soundfont not found", details: nil))
        return
      }
      soundfont.engine.stop()
      result(nil)
    case "dispose":
      let soundfonts = removeAllSoundfonts()
      for soundfont in soundfonts {
        soundfont.engine.stop()
      }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func setupAudioSessionNotifications() {
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleAudioSessionInterruption),
      name: AVAudioSession.interruptionNotification,
      object: AVAudioSession.sharedInstance()
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleAudioSessionRouteChange),
      name: AVAudioSession.routeChangeNotification,
      object: AVAudioSession.sharedInstance()
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleMediaServicesWereReset),
      name: AVAudioSession.mediaServicesWereResetNotification,
      object: AVAudioSession.sharedInstance()
    )
  }

  private func configureAudioSession() {
    #if os(iOS)
    let session = AVAudioSession.sharedInstance()
    do {
      try session.setCategory(.playback, mode: .default, options: [])
      try session.setPreferredSampleRate(44_100)
      try session.setPreferredIOBufferDuration(0.0058)
      try session.setActive(true)
    } catch {
      print("Failed to configure AVAudioSession: \(error)")
    }
    #endif
  }

  @objc private func handleAudioSessionInterruption(notification: Notification) {
    recoverAudioSessionIfNeeded(AudioSessionRecoveryAction.interruption(notification.userInfo))
  }

  @objc private func handleAudioSessionRouteChange(notification: Notification) {
    recoverAudioSessionIfNeeded(AudioSessionRecoveryAction.routeChange(notification.userInfo))
  }

  @objc private func handleMediaServicesWereReset(_: Notification) {
    recoverAudioSessionIfNeeded(.reconfigureAndRestart)
  }

  private func recoverAudioSessionIfNeeded(_ action: AudioSessionRecoveryAction) {
    guard action == .reconfigureAndRestart else {
      return
    }

    workQueue.async {
      self.configureAudioSession()
      self.restartAudioEngines()
    }
  }

  private func restartAudioEngines() {
    let activeSoundfonts = stateQueue.sync { Array(self.soundfonts.values) }
    for soundfont in activeSoundfonts where !soundfont.engine.isRunning {
      do {
        try soundfont.engine.start()
      } catch {
        print("Failed to restart audio engine: \(error)")
      }
    }
  }

  private func loadSoundfont(path: String, bank: Int, program: Int, result: @escaping FlutterResult) {
    let url = URL(fileURLWithPath: path)
    let sfId = stateQueue.sync { () -> Int in
      let nextID = soundfontIndex
      soundfontIndex += 1
      return nextID
    }

    workQueue.async {
      do {
        let soundfont = try self.createSoundfontState(url: url, bank: bank, program: program)
        self.stateQueue.sync {
          self.soundfonts[sfId] = soundfont
        }
        DispatchQueue.main.async {
          result(sfId)
        }
      } catch let error as FlutterError {
        DispatchQueue.main.async {
          result(error)
        }
      } catch let error as PluginLoadError {
        let flutterError: FlutterError
        switch error {
        case .audioEngineStartFailed(let details):
          flutterError = FlutterError(
            code: "AUDIO_ENGINE_START_FAILED",
            message: "Failed to start audio engine",
            details: details
          )
        }
        DispatchQueue.main.async {
          result(flutterError)
        }
      } catch {
        DispatchQueue.main.async {
          result(FlutterError(code: "SOUND_FONT_LOAD_FAILED", message: "Failed to load soundfont", details: error.localizedDescription))
        }
      }
    }
  }

  private func createSoundfontState(url: URL, bank: Int, program: Int) throws -> SoundfontState {
    let state = SoundfontState.makeEmpty(channelCount: channelCount).withURL(url)
    let bankInfo = SoundfontBankInfo(bank: bank)

    for sampler in state.samplers {
      try sampler.loadSoundBankInstrument(
        at: url,
        program: UInt8(program),
        bankMSB: bankInfo.bankMSB,
        bankLSB: bankInfo.bankLSB
      )
    }

    do {
      try state.engine.start()
    } catch {
      throw PluginLoadError.audioEngineStartFailed(error.localizedDescription)
    }

    return state
  }

  private func selectInstrument(sfId: Int, channel: Int, bank: Int, program: Int, result: @escaping FlutterResult) {
    guard let soundfont = soundfontState(for: sfId),
          soundfont.samplers.indices.contains(channel) else {
      result(FlutterError(code: "SOUND_FONT_NOT_FOUND", message: "Soundfont/channel not found", details: nil))
      return
    }

    let sampler = soundfont.samplers[channel]
    let bankInfo = SoundfontBankInfo(bank: bank)

    workQueue.async {
      do {
        try sampler.loadSoundBankInstrument(
          at: soundfont.url,
          program: UInt8(program),
          bankMSB: bankInfo.bankMSB,
          bankLSB: bankInfo.bankLSB
        )
        sampler.sendProgramChange(
          UInt8(program),
          bankMSB: bankInfo.bankMSB,
          bankLSB: bankInfo.bankLSB,
          onChannel: UInt8(channel)
        )
        DispatchQueue.main.async {
          result(nil)
        }
      } catch {
        DispatchQueue.main.async {
          result(FlutterError(code: "SOUND_FONT_LOAD_FAILED", message: "Failed to load soundfont", details: error.localizedDescription))
        }
      }
    }
  }

  private func soundfontState(for sfId: Int) -> SoundfontState? {
    stateQueue.sync { soundfonts[sfId] }
  }

  private func sampler(for sfId: Int, channel: Int) -> AVAudioUnitSampler? {
    guard channel >= 0 && channel < channelCount else {
      return nil
    }
    return stateQueue.sync { soundfonts[sfId]?.samplers[channel] }
  }

  private func removeSoundfont(for sfId: Int) -> SoundfontState? {
    stateQueue.sync { soundfonts.removeValue(forKey: sfId) }
  }

  private func removeAllSoundfonts() -> [SoundfontState] {
    stateQueue.sync {
      let values = Array(soundfonts.values)
      soundfonts.removeAll()
      return values
    }
  }
}
