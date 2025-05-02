import AVFoundation
import CoreVideo
import UIKit

// FourCharCode 확장 - 포맷 타입 코드를 문자열로 변환
extension FourCharCode {
  func toString() -> String {
    let bytes: [CChar] = [
      CChar((self >> 24) & 0xFF),
      CChar((self >> 16) & 0xFF),
      CChar((self >> 8) & 0xFF),
      CChar(self & 0xFF),
      0
    ]
    return String(cString: bytes)
  }
}

public protocol VideoCaptureDelegate: AnyObject {
  func videoCapture(_ capture: VideoCapture, didCaptureVideoFrame: CMSampleBuffer)
}

func bestCaptureDevice(position: AVCaptureDevice.Position) -> AVCaptureDevice {

  if UserDefaults.standard.bool(forKey: "use_telephoto"),
    let device = AVCaptureDevice.default(.builtInTelephotoCamera, for: .video, position: position)
  {
    return device
  } else if let device = AVCaptureDevice.default(
    .builtInDualCamera, for: .video, position: position)
  {
    return device
  } else if let device = AVCaptureDevice.default(
    .builtInWideAngleCamera, for: .video, position: position)
  {
    return device
  } else {
    fatalError("Missing expected back camera device.")
  }
}

public class VideoCapture: NSObject {
  public var previewLayer: AVCaptureVideoPreviewLayer?
  public weak var delegate: VideoCaptureDelegate?
  public let captureSession = AVCaptureSession()
  let videoOutput = AVCaptureVideoDataOutput()
  let photoOutput = AVCapturePhotoOutput()
  let movieFileOutput = AVCaptureMovieFileOutput()
  let cameraQueue = DispatchQueue(label: "camera-queue")
  public var lastCapturedPhoto: UIImage?
  public weak var nativeView: FLNativeView?
  
  private var isRecording = false
  private var currentRecordingURL: URL?
  private var recordingCompletionHandler: ((URL?, Error?) -> Void)?
  private var currentPosition: AVCaptureDevice.Position = .back
  private var currentZoomFactor: CGFloat = 1.0
  public var currentDevice: AVCaptureDevice?
  private var audioEnabled = true // 오디오 활성화 상태 추적
  
  // FPS 관련 속성 추가
  private var currentFrameRate: Int = 30
  private var isSlowMotionEnabled: Bool = false
  
  public override init() {
    super.init()
    print("DEBUG: VideoCapture initialized")
  }

  public func setUp(
    sessionPreset: AVCaptureSession.Preset,
    position: AVCaptureDevice.Position,
    completion: @escaping (Bool) -> Void
  ) {
    print("DEBUG: Setting up video capture with position:", position)
    
    self.currentPosition = position
    
    cameraQueue.async { [weak self] in
      guard let self = self else {
        DispatchQueue.main.async { completion(false) }
        return
      }

      // Ensure session is not running
      if self.captureSession.isRunning {
        self.captureSession.stopRunning()
      }

      self.captureSession.beginConfiguration()

      // Remove existing inputs/outputs
      for input in self.captureSession.inputs {
        self.captureSession.removeInput(input)
      }
      for output in self.captureSession.outputs {
        self.captureSession.removeOutput(output)
      }

      self.captureSession.sessionPreset = sessionPreset

      do {
        // 개선된 카메라 장치 선택 로직 사용
        let device = bestCaptureDevice(position: position)
        self.currentDevice = device
        
        // 카메라 장치 구성 최적화
        try device.lockForConfiguration()
        if device.isFocusModeSupported(.continuousAutoFocus) {
          device.focusMode = .continuousAutoFocus
        }
        if device.isExposureModeSupported(.continuousAutoExposure) {
          device.exposureMode = .continuousAutoExposure
        }
        if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
          device.whiteBalanceMode = .continuousAutoWhiteBalance
        }
        
        // 높은 프레임레이트를 지원하는 포맷을 선택
        var bestFormat: AVCaptureDevice.Format? = nil
        var maxFrameRate: Float64 = 0
        
        // 현재 디바이스에서 지원하는 모든 포맷 중에서 가장 높은 FPS를 지원하는 포맷 찾기
        for format in device.formats {
          // 현재 해상도 또는 그에 가까운 포맷만 고려
          let formatDescription = format.formatDescription
          let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
          let width = Int(dimensions.width)
          let height = Int(dimensions.height)
          
          // 최소 720p 이상의 해상도 (너무 낮은 해상도는 제외)
          if width >= 1280 && height >= 720 {
            // 각 포맷의 최대 지원 프레임레이트 확인
            for range in format.videoSupportedFrameRateRanges {
              if range.maxFrameRate > maxFrameRate {
                bestFormat = format
                maxFrameRate = range.maxFrameRate
              }
            }
          }
        }
        
        // 더 좋은 포맷을 찾았다면 적용
        if let format = bestFormat, maxFrameRate > 30 {
          device.activeFormat = format
          print("DEBUG: Selected format with max frame rate: \(maxFrameRate) FPS")
          
          // 기본 FPS를 30으로 설정
          let duration = CMTime(value: 1, timescale: 30)
          device.activeVideoMinFrameDuration = duration
          device.activeVideoMaxFrameDuration = duration
          self.currentFrameRate = 30
        }
        
        // 줌 팩터 적용 - 디폴트는 1.0
        if self.currentZoomFactor != 1.0 {
          let maxZoomFactor = min(device.activeFormat.videoMaxZoomFactor, 5.0)
          device.videoZoomFactor = min(self.currentZoomFactor, maxZoomFactor)
        }
        
        device.unlockForConfiguration()

        let input = try AVCaptureDeviceInput(device: device)
        if self.captureSession.canAddInput(input) {
          self.captureSession.addInput(input)
          print("DEBUG: Added camera input")
        }

        // 오디오 입력 설정
        if self.audioEnabled, let audioDevice = AVCaptureDevice.default(for: .audio) {
          do {
            let audioInput = try AVCaptureDeviceInput(device: audioDevice)
            if self.captureSession.canAddInput(audioInput) {
              self.captureSession.addInput(audioInput)
              print("DEBUG: Added audio input")
            }
          } catch {
            print("DEBUG: Could not create audio input: \(error)")
          }
        }

        // Set up video output
        self.videoOutput.videoSettings = [
          kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: kCVPixelFormatType_32BGRA)
        ]
        self.videoOutput.alwaysDiscardsLateVideoFrames = true
        self.videoOutput.setSampleBufferDelegate(self, queue: self.cameraQueue)

        if self.captureSession.canAddOutput(self.videoOutput) {
          self.captureSession.addOutput(self.videoOutput)
          print("DEBUG: Added video output")
        }

        if self.captureSession.canAddOutput(self.photoOutput) {
          self.captureSession.addOutput(self.photoOutput)
          print("DEBUG: Added photo output")
        }

        if self.captureSession.canAddOutput(self.movieFileOutput) {
          self.captureSession.addOutput(self.movieFileOutput)
          print("DEBUG: Added movie file output")
        }

        let connection = self.videoOutput.connection(with: .video)
        connection?.videoOrientation = .portrait
        connection?.isVideoMirrored = position == .front

        self.captureSession.commitConfiguration()

        // Set up preview layer on main thread
        DispatchQueue.main.async {
          // 기존 프리뷰 레이어가 있으면 제거
          self.previewLayer?.removeFromSuperlayer()
          
          // 새 프리뷰 레이어 생성
          self.previewLayer = AVCaptureVideoPreviewLayer(session: self.captureSession)
          self.previewLayer?.videoGravity = .resizeAspectFill

          if let connection = self.previewLayer?.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = position == .front
          }

          // 카메라 설정 완료 후 슬로우 모션 지원 여부 확인
          let slowMotionSupported = self.isSlowMotionSupported()
          let maxSlowMotionFps = self.getMaxSlowMotionFrameRate()
          print("DEBUG: 카메라 설정 완료 - 슬로우 모션 지원: \(slowMotionSupported), 최대 \(maxSlowMotionFps) FPS")

          completion(true)
        }
      } catch {
        print("DEBUG: Camera setup error:", error)
        self.captureSession.commitConfiguration()
        DispatchQueue.main.async { completion(false) }
      }
    }
  }

  public func setZoomRatio(_ zoomFactor: CGFloat) {
    let zoomFactor = max(1.0, min(5.0, zoomFactor))
    
    cameraQueue.async { [weak self] in
      guard let self = self, let device = self.currentDevice else { return }
      
      do {
        try device.lockForConfiguration()
        
        let maxZoomFactor = min(device.activeFormat.videoMaxZoomFactor, 5.0)
        device.videoZoomFactor = min(zoomFactor, maxZoomFactor)
        self.currentZoomFactor = device.videoZoomFactor
        
        device.unlockForConfiguration()
        print("DEBUG: Zoom factor set to \(self.currentZoomFactor)")
      } catch {
        print("DEBUG: Failed to set zoom: \(error)")
      }
    }
  }

  public func start() {
    if !captureSession.isRunning {
      cameraQueue.async { [weak self] in
        guard let self = self else { return }
        
        // 안전하게 세션 시작
        self.captureSession.startRunning()
        print("DEBUG: Camera started running")
        
        // 세션이 시작된 후 메인 스레드에서 프리뷰 레이어 상태 확인
        DispatchQueue.main.async { [weak self] in
          guard let self = self else { return }
          
          // 프리뷰 레이어가 없거나 슈퍼레이어가 없는 경우 nativeView에 다시 추가
          if let previewLayer = self.previewLayer, previewLayer.superlayer == nil, let nativeView = self.nativeView {
            if let view = nativeView.view() as? UIView {
              previewLayer.frame = view.bounds
              view.layer.addSublayer(previewLayer)
              print("DEBUG: Re-added preview layer to view after starting camera")
            }
          }
        }
      }
    }
  }

  public func stop() {
    if captureSession.isRunning {
      captureSession.stopRunning()
      // Wait for the session to stop
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
        print("DEBUG: Camera stopped running")
      }
    }
  }

  public func startRecording(completion: @escaping (URL?, Error?) -> Void) {
    guard !isRecording else {
      completion(nil, NSError(domain: "VideoCapture", code: 100, userInfo: [NSLocalizedDescriptionKey: "이미 녹화 중입니다"]))
      return
    }
    
    // 고유한 파일 이름 생성: 타임스탬프 + UUID
    let timestamp = Date().timeIntervalSince1970
    let uuid = UUID().uuidString.prefix(8)
    let fileName = "recording_\(timestamp)_\(uuid).mp4"
    
    let tempDir = FileManager.default.temporaryDirectory
    let fileURL = tempDir.appendingPathComponent(fileName)
    
    // 파일이 이미 존재하면 삭제
    try? FileManager.default.removeItem(at: fileURL)
    
    cameraQueue.async { [weak self] in
      guard let self = self else { return }
      
      if self.movieFileOutput.isRecording == false {
        // 오디오 입력이 없는 경우 추가
        if self.audioEnabled && !self.hasAudioInput() {
          self.addAudioInput()
        }
        
        // 현재 줌 팩터 저장 (참조용)
        let currentZoom = self.currentZoomFactor
        print("DEBUG: Current zoom factor before recording: \(currentZoom)")
        
        // 비디오 설정 구성
        if let connection = self.movieFileOutput.connection(with: .video) {
          connection.videoOrientation = .portrait
          connection.isVideoMirrored = self.currentPosition == AVCaptureDevice.Position.front
          
          // 슬로우 모션 모드인 경우 추가 설정
          if self.isSlowMotionEnabled {
            print("DEBUG: 슬로우 모션 모드로 녹화 시작 - \(self.currentFrameRate) FPS")
            
            // 슬로우 모션 녹화용 설정 적용
            // 참고: 이 설정은 일부 기기에서만 작동할 수 있음
            if connection.isVideoStabilizationSupported {
              connection.preferredVideoStabilizationMode = .auto
            }
          } else {
            // 비디오 안정화 설정 (가능한 경우)
            if connection.isVideoStabilizationSupported {
              connection.preferredVideoStabilizationMode = .auto
            }
          }
        }
        
        self.recordingCompletionHandler = completion
        self.currentRecordingURL = fileURL
        self.movieFileOutput.startRecording(to: fileURL, recordingDelegate: self)
        self.isRecording = true
        print("DEBUG: Video recording started to \(fileURL.path)")
      } else {
        DispatchQueue.main.async {
          completion(nil, NSError(domain: "VideoCapture", code: 101, userInfo: [NSLocalizedDescriptionKey: "녹화 시작 실패"]))
        }
      }
    }
  }
  
  public func stopRecording(completion: @escaping (URL?, Error?) -> Void) {
    guard isRecording else {
      completion(nil, NSError(domain: "VideoCapture", code: 102, userInfo: [NSLocalizedDescriptionKey: "녹화 중이 아닙니다"]))
      return
    }
    
    cameraQueue.async { [weak self] in
      guard let self = self else { return }
      
      if self.movieFileOutput.isRecording {
        self.recordingCompletionHandler = { [weak self] (url, error) in
          // 원래의 콜백 호출
          completion(url, error)
        }
        
        self.movieFileOutput.stopRecording()
      } else {
        DispatchQueue.main.async {
          self.isRecording = false
          completion(nil, NSError(domain: "VideoCapture", code: 103, userInfo: [NSLocalizedDescriptionKey: "녹화가 이미 중지됨"]))
        }
      }
    }
  }

  // 오디오 입력이 있는지 확인하는 헬퍼 메서드
  private func hasAudioInput() -> Bool {
    return captureSession.inputs.contains { input in
      guard let deviceInput = input as? AVCaptureDeviceInput else { return false }
      return deviceInput.device.hasMediaType(.audio)
    }
  }
  
  // 오디오 입력을 추가하는 헬퍼 메서드
  private func addAudioInput() {
    captureSession.beginConfiguration()
    
    if let audioDevice = AVCaptureDevice.default(for: .audio) {
      do {
        let audioInput = try AVCaptureDeviceInput(device: audioDevice)
        if captureSession.canAddInput(audioInput) {
          captureSession.addInput(audioInput)
          print("DEBUG: Added audio input for recording")
        }
      } catch {
        print("DEBUG: Could not create audio input: \(error)")
      }
    }
    
    captureSession.commitConfiguration()
  }

  public func getSupportedFrameRatesInfo() -> [String: Bool] {
    let fpsValues = [30.0, 60.0, 90.0, 120.0]
    var result = [String: Bool]()
    
    for fps in fpsValues {
      let key = "\(Int(fps))fps"
      result[key] = isFrameRateSupported(fps)
    }
    
    print("DEBUG: Supported frame rates: \(result)")
    return result
  }

  public func isFrameRateSupported(_ fps: Double) -> Bool {
    guard let device = self.currentDevice else { return false }
    
    // 모든 포맷에서 확인
    for format in device.formats {
      for range in format.videoSupportedFrameRateRanges {
        if fps >= range.minFrameRate && fps <= range.maxFrameRate {
          return true
        }
      }
    }
    return false
  }

  // 특정 FPS를 지원하는 최적의 포맷 찾기
  private func findFormatSupportingFrameRate(_ fps: Double) -> AVCaptureDevice.Format? {
    guard let device = self.currentDevice else { return nil }
    
    // 현재 해상도 가져오기
    let currentDimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
    let currentResolution = currentDimensions.width * currentDimensions.height
    
    var bestFormat: AVCaptureDevice.Format? = nil
    var bestResolutionMatch: Int = Int.max
    
    for format in device.formats {
      // 이 포맷이 원하는 fps를 지원하는지 확인
      let ranges = format.videoSupportedFrameRateRanges
      let supportsFrameRate = ranges.contains { range in
        return fps >= range.minFrameRate && fps <= range.maxFrameRate
      }
      
      if supportsFrameRate {
        let formatDimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        let formatResolution = formatDimensions.width * formatDimensions.height
        let resolutionDiff = abs(Int(formatResolution) - Int(currentResolution))
        
        // 이전에 찾은 포맷보다 현재 해상도에 더 가까운 포맷인 경우 업데이트
        if bestFormat == nil || resolutionDiff < bestResolutionMatch {
          bestFormat = format
          bestResolutionMatch = resolutionDiff
        }
      }
    }
    
    return bestFormat
  }
  
  public func setFrameRate(_ fps: Int) -> Bool {
    guard let device = self.currentDevice else { return false }
    
    // 먼저 현재 포맷이 이 FPS를 지원하는지 확인
    var currentFormatSupported = false
    for range in device.activeFormat.videoSupportedFrameRateRanges {
      if Double(fps) >= range.minFrameRate && Double(fps) <= range.maxFrameRate {
        currentFormatSupported = true
        break
      }
    }
    
    // 현재 포맷이 지원하지 않는 경우, 지원하는 포맷을 찾음
    if !currentFormatSupported {
      print("DEBUG: Current format does not support \(fps) FPS, searching for compatible format...")
      
      guard let newFormat = findFormatSupportingFrameRate(Double(fps)) else {
        print("DEBUG: No format found supporting \(fps) FPS")
        return false
      }
      
      // 새 포맷으로 전환
      do {
        try device.lockForConfiguration()
        device.activeFormat = newFormat
        device.unlockForConfiguration()
        
        let dimensions = CMVideoFormatDescriptionGetDimensions(newFormat.formatDescription)
        print("DEBUG: Switched to format with resolution \(dimensions.width)x\(dimensions.height) supporting \(fps) FPS")
      } catch {
        print("DEBUG: Failed to switch format: \(error)")
        return false
      }
    }
    
    // 이제 FPS를 설정
    do {
      try device.lockForConfiguration()
      
      // 30프레임 디바이스에서 그 이상을 요청한 경우 최대 프레임레이트로 제한
      var targetFps = fps
      let maxSupportedFps = Int(device.activeFormat.videoSupportedFrameRateRanges.map { $0.maxFrameRate }.max() ?? 30.0)
      
      if targetFps > maxSupportedFps {
        print("DEBUG: Requested \(fps) FPS, but device only supports up to \(maxSupportedFps) FPS. Using \(maxSupportedFps) FPS instead.")
        targetFps = maxSupportedFps
      }
      
      let duration = CMTime(value: 1, timescale: CMTimeScale(targetFps))
      device.activeVideoMinFrameDuration = duration
      device.activeVideoMaxFrameDuration = duration
      self.currentFrameRate = targetFps
      
      device.unlockForConfiguration()
      print("DEBUG: Frame rate set to \(targetFps) FPS")
      return true
    } catch {
      print("DEBUG: Failed to set frame rate: \(error)")
      return false
    }
  }

  // 슬로우 모션 녹화를 위한 최적 포맷을 찾는 메서드
  private func findSlowMotionFormat() -> AVCaptureDevice.Format? {
    guard let device = self.currentDevice else { return nil }
    
    print("DEBUG: ===== 카메라 장치 정보 =====")
    print("DEBUG: 현재 카메라: \(device.localizedName)")
    print("DEBUG: 모델 ID: \(device.modelID)")
    print("DEBUG: 모든 포맷 정보 출력 시작:")
    
    // 모든 포맷 정보를 출력하여 디버깅
    var allFormatsInfo = ""
    for (index, format) in device.formats.enumerated() {
      let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
      let frameRates = format.videoSupportedFrameRateRanges.map { "\($0.minFrameRate)-\($0.maxFrameRate)" }.joined(separator: ", ")
      let formatTypeStr = CMFormatDescriptionGetMediaSubType(format.formatDescription).toString()
      
      allFormatsInfo += "포맷 #\(index): \(dimensions.width)x\(dimensions.height) \(formatTypeStr), FPS: [\(frameRates)]\n"
    }
    print("DEBUG: \(allFormatsInfo)")
    
    // 1. 먼저 SlowMo 전용 포맷 찾기 (Slo-mo가 이름에 있거나 240fps를 지원하는 포맷)
    var bestFormat: AVCaptureDevice.Format? = nil
    var bestFrameRate: Float64 = 0
    
    // 슬로우 모션 모드 전용 포맷 검색 (240fps 지원 우선)
    for format in device.formats {
      let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
      let formatDescription = CMFormatDescriptionGetMediaSubType(format.formatDescription).toString()
      
      // 포맷의 프레임 레이트 범위 확인
      for range in format.videoSupportedFrameRateRanges {
        // 240fps 혹은 120fps를 지원하는 포맷 찾기
        if range.maxFrameRate >= 120 {
          // 현재까지 찾은 것보다 프레임레이트가 높으면 업데이트
          if range.maxFrameRate > bestFrameRate {
            bestFormat = format
            bestFrameRate = range.maxFrameRate
            print("DEBUG: ✅ 슬로우 모션 포맷 발견: \(dimensions.width)x\(dimensions.height) \(formatDescription) @ \(bestFrameRate)fps")
          }
          // 같은 프레임레이트라면 해상도가 더 높은 것을 선택
          else if range.maxFrameRate == bestFrameRate && bestFormat != nil {
            let bestDimensions = CMVideoFormatDescriptionGetDimensions(bestFormat!.formatDescription)
            let bestResolution = bestDimensions.width * bestDimensions.height
            let currentResolution = dimensions.width * dimensions.height
            
            if currentResolution > bestResolution {
              bestFormat = format
              print("DEBUG: ✅ 더 높은 해상도의 슬로우 모션 포맷 발견: \(dimensions.width)x\(dimensions.height) \(formatDescription) @ \(bestFrameRate)fps")
            }
          }
        }
      }
    }
    
    if let format = bestFormat {
      let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
      let formatTypeStr = CMFormatDescriptionGetMediaSubType(format.formatDescription).toString()
      print("DEBUG: 🎯 선택된 슬로우 모션 포맷: \(dimensions.width)x\(dimensions.height) \(formatTypeStr), \(bestFrameRate)fps")
      
      // 이 포맷의 프레임레이트 범위 출력
      for range in format.videoSupportedFrameRateRanges {
        print("DEBUG: 지원 프레임레이트 범위: \(range.minFrameRate) - \(range.maxFrameRate)fps")
      }
    } else {
      print("DEBUG: ⚠️ 슬로우 모션을 지원하는 포맷을 찾을 수 없습니다")
    }
    
    return bestFormat
  }
  
  // 일반 비디오 포맷을 찾는 메서드 (기존 메서드와 구분)
  private func findNormalVideoFormat(minResolution: (width: Int32, height: Int32) = (1920, 1080)) -> AVCaptureDevice.Format? {
    guard let device = self.currentDevice else { return nil }
    
    var bestFormat: AVCaptureDevice.Format? = nil
    var bestResolutionMatch: Int32 = 0
    
    for format in device.formats {
      let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
      let resolution = dimensions.width * dimensions.height
      
      // 최소 해상도 이상이고, 최대 프레임레이트가 30 이상인 경우
      if dimensions.width >= minResolution.width && dimensions.height >= minResolution.height {
        for range in format.videoSupportedFrameRateRanges {
          if range.maxFrameRate >= 30 && resolution > bestResolutionMatch {
            bestFormat = format
            bestResolutionMatch = resolution
          }
        }
      }
    }
    
    return bestFormat
  }
  
  // 슬로우 모션 모드 활성화/비활성화 메서드
  public func enableSlowMotion(_ enable: Bool) -> Bool {
    guard let device = self.currentDevice else { return false }
    
    // 이미 원하는 상태면 변경 필요 없음
    if isSlowMotionEnabled == enable {
      print("DEBUG: 슬로우 모션 상태가 이미 \(enable ? "활성화" : "비활성화") 되어있습니다.")
      return true
    }
    
    do {
      // 세션 재구성 시작 (중요: 이 단계에서 카메라 프리뷰가 잠시 중단될 수 있음)
      captureSession.beginConfiguration()
      
      if enable {
        print("DEBUG: 슬로우 모션 모드 활성화 시도 중...")
        
        // 현재 카메라 입력 객체 백업
        var currentInput: AVCaptureDeviceInput? = nil
        for input in captureSession.inputs {
          if let deviceInput = input as? AVCaptureDeviceInput, 
             deviceInput.device.hasMediaType(AVMediaType.video) {
            currentInput = deviceInput
            break
          }
        }
        
        // 현재 입력이 있으면 제거
        if let currentInput = currentInput {
          captureSession.removeInput(currentInput)
        }
        
        // 기존 세션 설정 백업
        let previousPreset = captureSession.sessionPreset
        
        // SlowMo 전용 프리셋으로 설정
        // 이 프리셋은 일반적으로 240fps를 지원하는 포맷을 사용
        captureSession.sessionPreset = AVCaptureSession.Preset.hd1280x720
        
        // 슬로우 모션 모드 활성화 (120fps 또는 240fps)
        guard let slowMotionFormat = findSlowMotionFormat() else {
          // 실패 시 원래 설정으로 복원
          captureSession.sessionPreset = previousPreset
          if let currentInput = currentInput, captureSession.canAddInput(currentInput) {
            captureSession.addInput(currentInput)
          }
          
          print("DEBUG: ❌ 슬로우 모션 포맷을 찾을 수 없어 활성화 실패")
          captureSession.commitConfiguration()
          return false
        }
        
        // 포맷 변경 전 카메라 구성 잠금
        try device.lockForConfiguration()
        
        // 현재 포맷 정보 로깅
        let currentDimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        print("DEBUG: 현재 포맷: \(currentDimensions.width)x\(currentDimensions.height)")
        
        // 새 포맷 정보 로깅
        let newDimensions = CMVideoFormatDescriptionGetDimensions(slowMotionFormat.formatDescription)
        print("DEBUG: 슬로우 모션 포맷으로 변경: \(newDimensions.width)x\(newDimensions.height)")
        
        // 포맷 변경
        device.activeFormat = slowMotionFormat
        
        // 프레임레이트 설정 (포맷의 최대값 또는 240fps 중 작은 값)
        let maxFrameRate = Int(slowMotionFormat.videoSupportedFrameRateRanges.map { $0.maxFrameRate }.max() ?? 120.0)
        let targetFrameRate = min(240, maxFrameRate)
        
        // 프레임 듀레이션 설정
        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(targetFrameRate))
        device.activeVideoMinFrameDuration = frameDuration
        device.activeVideoMaxFrameDuration = frameDuration
        
        self.currentFrameRate = targetFrameRate
        self.isSlowMotionEnabled = true
        
        device.unlockForConfiguration()
        
        // 새 입력 추가
        if let currentInput = currentInput {
          if captureSession.canAddInput(currentInput) {
            captureSession.addInput(currentInput)
          } else {
            do {
              // 새 입력 생성 시도
              let newInput = try AVCaptureDeviceInput(device: device)
              if captureSession.canAddInput(newInput) {
                captureSession.addInput(newInput)
              }
            } catch {
              print("DEBUG: ❌ 카메라 입력 재설정 오류: \(error)")
            }
          }
        } else {
          do {
            // 새 입력 생성 시도
            let newInput = try AVCaptureDeviceInput(device: device)
            if captureSession.canAddInput(newInput) {
              captureSession.addInput(newInput)
            }
          } catch {
            print("DEBUG: ❌ 카메라 입력 설정 오류: \(error)")
          }
        }
        
        print("DEBUG: ✅ 슬로우 모션 활성화 성공: \(targetFrameRate) FPS")
      } else {
        print("DEBUG: 일반 비디오 모드로 복귀 중...")
        
        // 현재 카메라 입력 객체 백업
        var currentInput: AVCaptureDeviceInput? = nil
        for input in captureSession.inputs {
          if let deviceInput = input as? AVCaptureDeviceInput, 
             deviceInput.device.hasMediaType(AVMediaType.video) {
            currentInput = deviceInput
            break
          }
        }
        
        // 현재 입력이 있으면 제거
        if let currentInput = currentInput {
          captureSession.removeInput(currentInput)
        }
        
        // 기본 세션 프리셋으로 복원
        captureSession.sessionPreset = AVCaptureSession.Preset.high
        
        // 슬로우 모션 모드 비활성화 (일반 녹화로 돌아감)
        guard let normalFormat = findNormalVideoFormat() else {
          print("DEBUG: ❌ 일반 비디오 포맷을 찾을 수 없어 비활성화 실패")
          captureSession.commitConfiguration()
          return false
        }
        
        // 포맷 변경 전 카메라 구성 잠금
        try device.lockForConfiguration()
        
        // 현재 포맷 정보 로깅
        let currentDimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        print("DEBUG: 현재 포맷: \(currentDimensions.width)x\(currentDimensions.height)")
        
        // 새 포맷 정보 로깅
        let newDimensions = CMVideoFormatDescriptionGetDimensions(normalFormat.formatDescription)
        print("DEBUG: 일반 비디오 포맷으로 변경: \(newDimensions.width)x\(newDimensions.height)")
        
        // 포맷 변경
        device.activeFormat = normalFormat
        
        // 30fps로 설정
        let frameDuration = CMTime(value: 1, timescale: 30)
        device.activeVideoMinFrameDuration = frameDuration
        device.activeVideoMaxFrameDuration = frameDuration
        
        self.currentFrameRate = 30
        self.isSlowMotionEnabled = false
        
        device.unlockForConfiguration()
        
        // 새 입력 추가
        if let currentInput = currentInput {
          if captureSession.canAddInput(currentInput) {
            captureSession.addInput(currentInput)
          } else {
            do {
              // 새 입력 생성 시도
              let newInput = try AVCaptureDeviceInput(device: device)
              if captureSession.canAddInput(newInput) {
                captureSession.addInput(newInput)
              }
            } catch {
              print("DEBUG: ❌ 카메라 입력 재설정 오류: \(error)")
            }
          }
        }
        
        print("DEBUG: ✅ 일반 비디오 모드 복귀 성공: 30 FPS")
      }
      
      // 변경사항 적용
      captureSession.commitConfiguration()
      return true
    } catch {
      print("DEBUG: ❌ 슬로우 모션 설정 오류: \(error)")
      captureSession.commitConfiguration()
      return false
    }
  }
  
  // 슬로우 모션 지원 여부 확인
  public func isSlowMotionSupported() -> Bool {
    let result = findSlowMotionFormat() != nil
    print("DEBUG: 슬로우 모션 지원 여부: \(result)")
    return result
  }
  
  // 디바이스가 지원하는 최대 슬로우 모션 프레임레이트 확인
  public func getMaxSlowMotionFrameRate() -> Int {
    guard let format = findSlowMotionFormat() else { return 0 }
    
    let maxFrameRate = Int(format.videoSupportedFrameRateRanges.map { $0.maxFrameRate }.max() ?? 0.0)
    return maxFrameRate
  }
  
  // 현재 슬로우 모션 활성화 상태 확인
  public func isSlowMotionActive() -> Bool {
    return isSlowMotionEnabled
  }
  
  // FPS 문자열 표시를 위한 확장 함수
  private func getMaxFPSString() -> String {
    let maxFPS = getMaxSlowMotionFrameRate()
    if maxFPS >= 240 {
      return "240fps"
    } else if maxFPS >= 120 {
      return "120fps"
    } else {
      return "\(maxFPS)fps"
    }
  }
}

extension VideoCapture: AVCaptureVideoDataOutputSampleBufferDelegate {
  public func captureOutput(
    _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    delegate?.videoCapture(self, didCaptureVideoFrame: sampleBuffer)
  }
}

extension VideoCapture: AVCapturePhotoCaptureDelegate {
  public func photoOutput(
    _ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?
  ) {
    guard let imageData = photo.fileDataRepresentation(),
      let image = UIImage(data: imageData)
    else {
      print("DEBUG: Error converting photo to image")
      return
    }

    self.lastCapturedPhoto = image
    print("DEBUG: Photo captured successfully")
  }
}

extension VideoCapture: AVCaptureFileOutputRecordingDelegate {
  public func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
    print("DEBUG: Recording started to \(fileURL.path)")
  }
  
  public func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
    isRecording = false
    
    if let error = error {
      print("DEBUG: Recording error: \(error.localizedDescription)")
      recordingCompletionHandler?(nil, error)
    } else {
      print("DEBUG: Recording finished successfully at \(outputFileURL.path)")
      recordingCompletionHandler?(outputFileURL, nil)
    }
    
    recordingCompletionHandler = nil
  }
}
