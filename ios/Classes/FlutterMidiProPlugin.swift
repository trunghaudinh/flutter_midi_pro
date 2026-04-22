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

public struct SamplerConfiguration {
  public let bank: Int
  public let program: Int

  public init(bank: Int, program: Int) {
    self.bank = bank
    self.program = program
  }
}

public final class SoundfontState {
  public let engine: AVAudioEngine
  public let samplers: [AVAudioUnitSampler]
  public let url: URL
  public var samplerConfigurations: [SamplerConfiguration]

  public init(
    engine: AVAudioEngine,
    samplers: [AVAudioUnitSampler],
    url: URL,
    samplerConfigurations: [SamplerConfiguration]
  ) {
    self.engine = engine
    self.samplers = samplers
    self.url = url
    self.samplerConfigurations = samplerConfigurations
  }

  public static func makeEmpty(
    channelCount: Int,
    url: URL,
    initialConfiguration: SamplerConfiguration
  ) -> SoundfontState {
    makeEmpty(
      channelCount: channelCount,
      url: url,
      samplerConfigurations: Array(
        repeating: initialConfiguration,
        count: channelCount
      )
    )
  }

  public static func makeEmpty(
    channelCount: Int,
    url: URL,
    samplerConfigurations: [SamplerConfiguration]
  ) -> SoundfontState {
    let engine = AVAudioEngine()
    var samplers: [AVAudioUnitSampler] = []
    samplers.reserveCapacity(channelCount)

    for _ in 0..<channelCount {
      let sampler = AVAudioUnitSampler()
      engine.attach(sampler)
      engine.connect(sampler, to: engine.mainMixerNode, format: nil)
      samplers.append(sampler)
    }

    return SoundfontState(
      engine: engine,
      samplers: samplers,
      url: url,
      samplerConfigurations: samplerConfigurations
    )
  }
}

public enum PluginLoadError: Error, LocalizedError {
  case audioEngineStartFailed(String)
  case soundfontStateUnavailable
  case invalidSamplerConfigurationCount(expected: Int, actual: Int)
  case invalidMidiValue(name: String, value: Int)

  public var errorDescription: String? {
    switch self {
    case .audioEngineStartFailed(let details):
      return "Audio engine start failed: \(details)"
    case .soundfontStateUnavailable:
      return "Soundfont state unavailable."
    case .invalidSamplerConfigurationCount(let expected, let actual):
      return "Invalid sampler configuration count. Expected \(expected), got \(actual)."
    case .invalidMidiValue(let name, let value):
      return "Invalid MIDI value for \(name): \(value)."
    }
  }
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
  private let logTag = "MIDIPRO_IOS"
  private let channelCount = 16
  private let workQueue = DispatchQueue(label: "flutter_midi_pro.audio.work", qos: .userInitiated)
  private let stateQueue = DispatchQueue(label: "flutter_midi_pro.audio.state")
  private var soundfontIndex = 1
  private var soundfonts: [Int: SoundfontState] = [:]
  private var lastSoundfontRecoveryStartedAt = Date.distantPast
  private let configurationChangeRecoverySuppressionWindow: TimeInterval = 0.75
  private let isVerboseLoggingEnabled = false

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "flutter_midi_pro", binaryMessenger: registrar.messenger())
    let instance = FlutterMidiProPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  public override init() {
    super.init()
    log("plugin init")
    configureAudioSession()
    setupAudioSessionNotifications()
  }

  deinit {
    log("plugin deinit")
    NotificationCenter.default.removeObserver(self)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    logVerbose("handle method=\(call.method) args=\(describeArguments(call.arguments)) activeSoundfonts=\(soundfontCount())")
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
            let sfId = args["sfId"] as? Int else {
        result(FlutterError(code: "INVALID_ARGUMENTS", message: "Missing soundfont arguments", details: nil))
        return
      }
      stopAllNotes(sfId: sfId, result: result)
    case "controlChange":
      guard let args = call.arguments as? [String: Any],
            let sfId = args["sfId"] as? Int,
            let channel = args["channel"] as? Int,
            let controller = args["controller"] as? Int,
            let value = args["value"] as? Int else {
        result(FlutterError(code: "INVALID_ARGUMENTS", message: "Missing control change arguments", details: nil))
        return
      }
      controlChange(sfId: sfId, channel: channel, controller: controller, value: value, result: result)
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
            let sfId = args["sfId"] as? Int else {
        result(FlutterError(code: "INVALID_ARGUMENTS", message: "Missing note arguments", details: nil))
        return
      }
      playNote(sfId: sfId, channel: channel, note: note, velocity: velocity, result: result)
    case "stopNote":
      guard let args = call.arguments as? [String: Any],
            let channel = args["channel"] as? Int,
            let note = args["key"] as? Int,
            let sfId = args["sfId"] as? Int else {
        result(FlutterError(code: "INVALID_ARGUMENTS", message: "Missing note arguments", details: nil))
        return
      }
      stopNote(sfId: sfId, channel: channel, note: note, result: result)
    case "unloadSoundfont":
      guard let args = call.arguments as? [String: Any],
            let sfId = args["sfId"] as? Int,
            let soundfont = removeSoundfont(for: sfId) else {
        result(FlutterError(code: "SOUND_FONT_NOT_FOUND", message: "Soundfont not found", details: nil))
        return
      }
      log("unloadSoundfont sfId=\(sfId)")
      soundfont.engine.stop()
      result(nil)
    case "dispose":
      let soundfonts = removeAllSoundfonts()
      for soundfont in soundfonts {
        soundfont.engine.stop()
      }
      log("dispose completed releasedSoundfonts=\(soundfonts.count)")
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func setupAudioSessionNotifications() {
    log("setupAudioSessionNotifications")
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
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleAudioEngineConfigurationChange),
      name: .AVAudioEngineConfigurationChange,
      object: nil
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
      log("configureAudioSession success snapshot=\(audioSessionSnapshot())")
    } catch {
      log("configureAudioSession failed error=\(error.localizedDescription)")
    }
    #endif
  }

  @objc private func handleAudioSessionInterruption(notification: Notification) {
    log("audioSession interruption userInfo=\(notification.userInfo ?? [:]) snapshot=\(audioSessionSnapshot())")
    recoverAudioSessionIfNeeded(AudioSessionRecoveryAction.interruption(notification.userInfo))
  }

  @objc private func handleAudioSessionRouteChange(notification: Notification) {
    log("audioSession routeChange reason=\(routeChangeReasonDescription(notification.userInfo)) userInfo=\(notification.userInfo ?? [:]) snapshot=\(audioSessionSnapshot())")
    logAllEngineStates(context: "audioSession routeChange")
    recoverAudioSessionIfNeeded(AudioSessionRecoveryAction.routeChange(notification.userInfo))
  }

  @objc private func handleMediaServicesWereReset(_: Notification) {
    log("audioSession mediaServicesWereReset snapshot=\(audioSessionSnapshot())")
    recoverAudioSessionIfNeeded(.reconfigureAndRestart)
  }

  @objc private func handleAudioEngineConfigurationChange(notification: Notification) {
    workQueue.async {
      guard let engine = notification.object as? AVAudioEngine else {
        self.log("audioEngine configurationChange unknown object=\(String(describing: notification.object)) snapshot=\(self.audioSessionSnapshot())")
        self.recoverAllSoundfonts(reason: "audioEngineConfigurationChange")
        return
      }
      guard let sfId = self.soundfontId(forEngine: engine) else {
        self.logVerbose("audioEngine configurationChange ignored unmanagedEngine=\(String(describing: notification.object))")
        return
      }

      self.log("audioEngine configurationChange sfId=\(sfId) snapshot=\(self.audioSessionSnapshot())")
      let elapsedSinceRecovery = Date().timeIntervalSince(self.lastSoundfontRecoveryStartedAt)
      guard elapsedSinceRecovery > self.configurationChangeRecoverySuppressionWindow else {
        self.log("audioEngine configurationChange recovery skipped elapsedSinceRecovery=\(elapsedSinceRecovery)")
        return
      }
      do {
        self.lastSoundfontRecoveryStartedAt = Date()
        try self.recoverSoundfont(sfId: sfId, reason: "audioEngineConfigurationChange")
      } catch {
        self.log("audioEngine configurationChange recovery failed sfId=\(sfId) error=\(error.localizedDescription)")
      }
    }
  }

  private func recoverAudioSessionIfNeeded(_ action: AudioSessionRecoveryAction) {
    guard action == .reconfigureAndRestart else {
      log("recoverAudioSessionIfNeeded skipped action=\(action)")
      return
    }

    workQueue.async {
      self.configureAudioSession()
      self.recoverAllSoundfonts(reason: "audioSessionRecovery")
    }
  }

  private func recoverAllSoundfonts(reason: String) {
    lastSoundfontRecoveryStartedAt = Date()
    let soundfontIds = stateQueue.sync { Array(self.soundfonts.keys).sorted() }
    log("recoverAllSoundfonts reason=\(reason) ids=\(soundfontIds)")
    for sfId in soundfontIds {
      do {
        try recoverSoundfont(sfId: sfId, reason: reason)
      } catch {
        log("recoverAllSoundfonts failed sfId=\(sfId) reason=\(reason) error=\(error.localizedDescription)")
      }
    }
    logAllEngineStates(context: "recoverAllSoundfonts \(reason)")
  }

  private func recoverSoundfont(sfId: Int, reason: String) throws {
    guard let soundfont = soundfontState(for: sfId) else {
      throw PluginLoadError.soundfontStateUnavailable
    }
    log("recoverSoundfont start sfId=\(sfId) reason=\(reason) engineStateBefore=\(describeEngineState(soundfont.engine)) snapshot=\(audioSessionSnapshot())")
    let replacement = try createSoundfontState(
      url: soundfont.url,
      samplerConfigurations: soundfont.samplerConfigurations
    )
    soundfont.engine.stop()
    stateQueue.sync {
      self.soundfonts[sfId] = replacement
    }
    log("recoverSoundfont completed sfId=\(sfId) reason=\(reason) engineStateAfter=\(describeEngineState(replacement.engine)) snapshot=\(audioSessionSnapshot())")
  }

  private func loadSoundfont(path: String, bank: Int, program: Int, result: @escaping FlutterResult) {
    let url = URL(fileURLWithPath: path)
    let sfId = stateQueue.sync { () -> Int in
      let nextID = soundfontIndex
      soundfontIndex += 1
      return nextID
    }
    log("loadSoundfont queued sfId=\(sfId) path=\(path) bank=\(bank) program=\(program)")

    workQueue.async {
      do {
        let soundfont = try self.createSoundfontState(url: url, bank: bank, program: program)
        self.stateQueue.sync {
          self.soundfonts[sfId] = soundfont
        }
        self.log("loadSoundfont success sfId=\(sfId) path=\(path) engineState=\(self.describeEngineState(soundfont.engine)) snapshot=\(self.audioSessionSnapshot())")
        DispatchQueue.main.async {
          result(sfId)
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
        case .soundfontStateUnavailable:
          flutterError = FlutterError(
            code: "SOUND_FONT_NOT_FOUND",
            message: "Soundfont not found",
            details: nil
          )
        case .invalidSamplerConfigurationCount, .invalidMidiValue:
          flutterError = FlutterError(
            code: "INVALID_ARGUMENTS",
            message: error.localizedDescription,
            details: nil
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
    let initialConfiguration = SamplerConfiguration(bank: bank, program: program)
    return try createSoundfontState(
      url: url,
      samplerConfigurations: Array(
        repeating: initialConfiguration,
        count: channelCount
      )
    )
  }

  private func createSoundfontState(url: URL, samplerConfigurations: [SamplerConfiguration]) throws -> SoundfontState {
    guard samplerConfigurations.count == channelCount else {
      throw PluginLoadError.invalidSamplerConfigurationCount(
        expected: channelCount,
        actual: samplerConfigurations.count
      )
    }

    let state = SoundfontState.makeEmpty(
      channelCount: channelCount,
      url: url,
      samplerConfigurations: samplerConfigurations
    )
    log("createSoundfontState start url=\(url.path) configurations=\(describeSamplerConfigurations(samplerConfigurations)) snapshot=\(audioSessionSnapshot())")
    try reloadSamplers(soundfont: state)
    do {
      try state.engine.start()
    } catch {
      throw PluginLoadError.audioEngineStartFailed(error.localizedDescription)
    }
    log("createSoundfontState engineStarted url=\(url.path) engineState=\(describeEngineState(state.engine))")
    return state
  }

  private func reloadSamplers(soundfont: SoundfontState) throws {
    for (index, sampler) in soundfont.samplers.enumerated() {
      let configuration = soundfont.samplerConfigurations[index]
      try configureSampler(
        sampler,
        soundfontURL: soundfont.url,
        configuration: configuration,
        channel: index
      )
    }
  }

  private func configureSampler(
    _ sampler: AVAudioUnitSampler,
    soundfontURL: URL,
    configuration: SamplerConfiguration,
    channel: Int
  ) throws {
    guard isSoundfontBank(configuration.bank) else {
      throw PluginLoadError.invalidMidiValue(name: "bank", value: configuration.bank)
    }
    guard isMidiByte(configuration.program) else {
      throw PluginLoadError.invalidMidiValue(name: "program", value: configuration.program)
    }

    let bankInfo = SoundfontBankInfo(bank: configuration.bank)
    try sampler.loadSoundBankInstrument(
      at: soundfontURL,
      program: UInt8(configuration.program),
      bankMSB: bankInfo.bankMSB,
      bankLSB: bankInfo.bankLSB
    )
    sampler.sendProgramChange(
      UInt8(configuration.program),
      bankMSB: bankInfo.bankMSB,
      bankLSB: bankInfo.bankLSB,
      onChannel: UInt8(channel)
    )
  }

  private func selectInstrument(sfId: Int, channel: Int, bank: Int, program: Int, result: @escaping FlutterResult) {
    guard channel >= 0 && channel < channelCount else {
      result(FlutterError(code: "SOUND_FONT_NOT_FOUND", message: "Soundfont/channel not found", details: nil))
      return
    }

    let configuration = SamplerConfiguration(bank: bank, program: program)

    workQueue.async {
      do {
        guard let soundfont = self.soundfontState(for: sfId),
              soundfont.samplers.indices.contains(channel) else {
          throw PluginLoadError.soundfontStateUnavailable
        }

        let sampler = soundfont.samplers[channel]
        try self.configureSampler(
          sampler,
          soundfontURL: soundfont.url,
          configuration: configuration,
          channel: channel
        )
        self.stateQueue.sync {
          self.soundfonts[sfId]?.samplerConfigurations[channel] = configuration
        }
        self.log("selectInstrument success sfId=\(sfId) channel=\(channel) bank=\(bank) program=\(program)")
        DispatchQueue.main.async {
          result(nil)
        }
      } catch let error as PluginLoadError {
        DispatchQueue.main.async {
          result(self.flutterError(for: error))
        }
      } catch {
        DispatchQueue.main.async {
          result(FlutterError(code: "SOUND_FONT_LOAD_FAILED", message: "Failed to load soundfont", details: error.localizedDescription))
        }
      }
    }
  }

  private func stopAllNotes(sfId: Int, result: @escaping FlutterResult) {
    workQueue.async {
      guard let soundfont = self.soundfontState(for: sfId) else {
        DispatchQueue.main.async {
          result(FlutterError(code: "SOUND_FONT_NOT_FOUND", message: "Soundfont not found", details: nil))
        }
        return
      }

      self.logVerbose("stopAllNotes sfId=\(sfId) engineState=\(self.describeEngineState(soundfont.engine))")
      for (channel, sampler) in soundfont.samplers.enumerated() {
        sampler.sendController(64, withValue: 0, onChannel: UInt8(channel))
        sampler.sendController(120, withValue: 0, onChannel: UInt8(channel))
      }
      DispatchQueue.main.async {
        result(nil)
      }
    }
  }

  private func controlChange(
    sfId: Int,
    channel: Int,
    controller: Int,
    value: Int,
    result: @escaping FlutterResult
  ) {
    guard channel >= 0 && channel < channelCount,
          isMidiByte(controller),
          isMidiByte(value) else {
      result(FlutterError(code: "SOUND_FONT_NOT_FOUND", message: "Soundfont/channel not found", details: nil))
      return
    }

    workQueue.async {
      guard let sampler = self.sampler(for: sfId, channel: channel) else {
        DispatchQueue.main.async {
          result(FlutterError(code: "SOUND_FONT_NOT_FOUND", message: "Soundfont/channel not found", details: nil))
        }
        return
      }

      self.logVerbose("controlChange sfId=\(sfId) channel=\(channel) controller=\(controller) value=\(value)")
      sampler.sendController(UInt8(controller), withValue: UInt8(value), onChannel: UInt8(channel))
      DispatchQueue.main.async {
        result(nil)
      }
    }
  }

  private func playNote(sfId: Int, channel: Int, note: Int, velocity: Int, result: @escaping FlutterResult) {
    guard channel >= 0 && channel < channelCount,
          isMidiByte(note),
          isMidiByte(velocity) else {
      result(FlutterError(code: "SOUND_FONT_NOT_FOUND", message: "Soundfont/channel not found", details: nil))
      return
    }

    workQueue.async {
      do {
        try self.ensureSoundfontReady(sfId: sfId, reason: "playNote")
        guard let sampler = self.sampler(for: sfId, channel: channel) else {
          throw PluginLoadError.soundfontStateUnavailable
        }
        self.logVerbose("playNote sfId=\(sfId) channel=\(channel) note=\(note) velocity=\(velocity)")
        sampler.startNote(UInt8(note), withVelocity: UInt8(velocity), onChannel: UInt8(channel))
        DispatchQueue.main.async {
          result(nil)
        }
      } catch let error as PluginLoadError {
        let flutterError: FlutterError
        switch error {
        case .audioEngineStartFailed(let details):
          flutterError = FlutterError(
            code: "AUDIO_ENGINE_START_FAILED",
            message: "Failed to start audio engine before playNote",
            details: details
          )
        case .soundfontStateUnavailable:
          flutterError = FlutterError(
            code: "SOUND_FONT_NOT_FOUND",
            message: "Soundfont/channel not found",
            details: nil
          )
        case .invalidSamplerConfigurationCount, .invalidMidiValue:
          flutterError = FlutterError(
            code: "INVALID_ARGUMENTS",
            message: error.localizedDescription,
            details: nil
          )
        }
        DispatchQueue.main.async {
          result(flutterError)
        }
      } catch {
        DispatchQueue.main.async {
          result(FlutterError(code: "PLAY_NOTE_FAILED", message: "Failed to play note", details: error.localizedDescription))
        }
      }
    }
  }

  private func stopNote(sfId: Int, channel: Int, note: Int, result: @escaping FlutterResult) {
    guard channel >= 0 && channel < channelCount,
          isMidiByte(note) else {
      result(FlutterError(code: "SOUND_FONT_NOT_FOUND", message: "Soundfont/channel not found", details: nil))
      return
    }

    workQueue.async {
      guard let sampler = self.sampler(for: sfId, channel: channel) else {
        DispatchQueue.main.async {
          result(FlutterError(code: "SOUND_FONT_NOT_FOUND", message: "Soundfont/channel not found", details: nil))
        }
        return
      }

      self.logVerbose("stopNote sfId=\(sfId) channel=\(channel) note=\(note)")
      sampler.stopNote(UInt8(note), onChannel: UInt8(channel))
      DispatchQueue.main.async {
        result(nil)
      }
    }
  }

  private func ensureSoundfontReady(sfId: Int, reason: String) throws {
    guard let soundfont = soundfontState(for: sfId) else {
      throw PluginLoadError.soundfontStateUnavailable
    }
    if soundfont.engine.isRunning {
      return
    }
    log("ensureSoundfontReady engineDown sfId=\(sfId) reason=\(reason) snapshot=\(audioSessionSnapshot())")
    configureAudioSession()
    try recoverSoundfont(sfId: sfId, reason: reason)
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

  private func soundfontId(forEngine engine: AVAudioEngine) -> Int? {
    stateQueue.sync {
      soundfonts.first { entry in entry.value.engine === engine }?.key
    }
  }

  private func isMidiByte(_ value: Int) -> Bool {
    value >= 0 && value <= 127
  }

  private func isSoundfontBank(_ value: Int) -> Bool {
    value >= 0 && value <= 128
  }

  private func flutterError(for error: PluginLoadError) -> FlutterError {
    switch error {
    case .audioEngineStartFailed(let details):
      return FlutterError(
        code: "AUDIO_ENGINE_START_FAILED",
        message: "Failed to start audio engine",
        details: details
      )
    case .soundfontStateUnavailable:
      return FlutterError(
        code: "SOUND_FONT_NOT_FOUND",
        message: "Soundfont/channel not found",
        details: nil
      )
    case .invalidSamplerConfigurationCount, .invalidMidiValue:
      return FlutterError(
        code: "INVALID_ARGUMENTS",
        message: error.localizedDescription,
        details: nil
      )
    }
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

  private func log(_ message: String) {
    print("\(logTag) \(message)")
  }

  private func logVerbose(_ message: String) {
    guard isVerboseLoggingEnabled else {
      return
    }
    log(message)
  }

  private func soundfontCount() -> Int {
    stateQueue.sync { soundfonts.count }
  }

  private func describeArguments(_ arguments: Any?) -> String {
    guard let arguments else {
      return "nil"
    }
    return String(describing: arguments)
  }

  private func currentAudioRouteDescription() -> String {
    #if os(iOS)
    let session = AVAudioSession.sharedInstance()
    let outputs = session.currentRoute.outputs.map { output in
      "\(output.portType.rawValue):\(output.portName)"
    }.joined(separator: ",")
    let inputs = session.currentRoute.inputs.map { input in
      "\(input.portType.rawValue):\(input.portName)"
    }.joined(separator: ",")
    return "outputs=[\(outputs)] inputs=[\(inputs)]"
    #else
    return "unsupported"
    #endif
  }

  private func audioSessionSnapshot() -> String {
    #if os(iOS)
    let session = AVAudioSession.sharedInstance()
    return "category=\(session.category.rawValue) mode=\(session.mode.rawValue) sampleRate=\(session.sampleRate) preferredSampleRate=\(session.preferredSampleRate) ioBuffer=\(session.ioBufferDuration) otherAudioPlaying=\(session.isOtherAudioPlaying) secondaryAudioSilenced=\(session.secondaryAudioShouldBeSilencedHint) outputChannels=\(session.outputNumberOfChannels) inputChannels=\(session.inputNumberOfChannels) route=\(currentAudioRouteDescription())"
    #else
    return "unsupported"
    #endif
  }

  private func describeEngineState(_ engine: AVAudioEngine) -> String {
    let outputFormat = engine.outputNode.outputFormat(forBus: 0)
    let mainMixerFormat = engine.mainMixerNode.outputFormat(forBus: 0)
    return "running=\(engine.isRunning) attachedNodes=\(engine.attachedNodes.count) outputSampleRate=\(outputFormat.sampleRate) outputChannels=\(outputFormat.channelCount) mixerSampleRate=\(mainMixerFormat.sampleRate) mixerChannels=\(mainMixerFormat.channelCount) mixerVolume=\(engine.mainMixerNode.outputVolume)"
  }

  private func logAllEngineStates(context: String) {
    let entries = stateQueue.sync { soundfonts.map { ($0.key, $0.value) }.sorted { $0.0 < $1.0 } }
    if entries.isEmpty {
      log("engineStateSnapshot context=\(context) soundfonts=[]")
      return
    }
    let details = entries.map { sfId, soundfont in
      "sfId=\(sfId) url=\(soundfont.url.lastPathComponent) \(describeEngineState(soundfont.engine))"
    }.joined(separator: " || ")
    log("engineStateSnapshot context=\(context) \(details)")
  }

  private func routeChangeReasonDescription(_ userInfo: [AnyHashable: Any]?) -> String {
    guard let userInfo,
          let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
          let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
      return "unknown"
    }
    switch reason {
    case .unknown:
      return "unknown"
    case .newDeviceAvailable:
      return "newDeviceAvailable"
    case .oldDeviceUnavailable:
      return "oldDeviceUnavailable"
    case .categoryChange:
      return "categoryChange"
    case .override:
      return "override"
    case .wakeFromSleep:
      return "wakeFromSleep"
    case .noSuitableRouteForCategory:
      return "noSuitableRouteForCategory"
    case .routeConfigurationChange:
      return "routeConfigurationChange"
    @unknown default:
      return "unhandled(\(reason.rawValue))"
    }
  }

  private func describeSamplerConfigurations(_ configurations: [SamplerConfiguration]) -> String {
    configurations.enumerated().map { index, configuration in
      "\(index):\(configuration.bank)/\(configuration.program)"
    }.joined(separator: ",")
  }
}
