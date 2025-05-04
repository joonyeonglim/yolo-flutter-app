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
        // 세션 중지 후 약간의 지연 추가
        Thread.sleep(forTimeInterval: 0.2)
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
        
        // 안전하게 현재 줌 팩터 초기화
        self.currentZoomFactor = 1.0
        self.isSlowMotionEnabled = false
        self.currentFrameRate = 30
        
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
        }
        
        device.unlockForConfiguration()

        let input = try AVCaptureDeviceInput(device: device)
        if self.captureSession.canAddInput(input) {
          self.captureSession.addInput(input)
          print("DEBUG: Added camera input")
        } else {
          print("DEBUG: ⚠️ Cannot add camera input")
          throw NSError(domain: "VideoCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot add camera input"])
        }

        // 오디오 입력 설정
        if self.audioEnabled, let audioDevice = AVCaptureDevice.default(for: .audio) {
          do {
            let audioInput = try AVCaptureDeviceInput(device: audioDevice)
            if self.captureSession.canAddInput(audioInput) {
              self.captureSession.addInput(audioInput)
              print("DEBUG: Added audio input")
            } else {
              print("DEBUG: ⚠️ Cannot add audio input")
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
        } else {
          print("DEBUG: ⚠️ Cannot add video output")
        }

        if self.captureSession.canAddOutput(self.photoOutput) {
          self.captureSession.addOutput(self.photoOutput)
          print("DEBUG: Added photo output")
        } else {
          print("DEBUG: ⚠️ Cannot add photo output")
        }

        if self.captureSession.canAddOutput(self.movieFileOutput) {
          self.captureSession.addOutput(self.movieFileOutput)
          print("DEBUG: Added movie file output")
        } else {
          print("DEBUG: ⚠️ Cannot add movie output")
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

          // 슬로우 모션 지원 여부 확인 및 로깅 (세션 설정에 영향 없음)
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
    cameraQueue.async { [weak self] in
      guard let self = self else { return }
      
      if !self.captureSession.isRunning {
        // iOS 14+ 에서는 카메라 권한 상태 확인
        if #available(iOS 14.0, *) {
          let authStatus = AVCaptureDevice.authorizationStatus(for: .video)
          if authStatus != .authorized {
            print("DEBUG: Camera authorization not granted")
            return
          }
        }
        
        print("DEBUG: Starting camera session")
        self.captureSession.startRunning()
        
        // 세션 시작 성공 여부 확인
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
          guard let self = self else { return }
          
          if self.captureSession.isRunning {
            print("DEBUG: Camera started running successfully")
            
            // 세션이 시작된 후 메인 스레드에서 프리뷰 레이어 상태 확인
            if let previewLayer = self.previewLayer, previewLayer.superlayer == nil, let nativeView = self.nativeView {
              if let view = nativeView.view() as? UIView {
                previewLayer.frame = view.bounds
                view.layer.addSublayer(previewLayer)
                print("DEBUG: Re-added preview layer to view after starting camera")
              }
            }
          } else {
            print("DEBUG: Failed to start camera session")
          }
        }
      } else {
        print("DEBUG: Camera already running, no need to start")
      }
    }
  }

  public func stop() {
    cameraQueue.async { [weak self] in
      guard let self = self else { return }
      
      if self.captureSession.isRunning {
        print("DEBUG: Stopping camera session")
        self.captureSession.stopRunning()
        
        // 세션 중지 확인
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
          guard let self = self else { return }
          
          if !self.captureSession.isRunning {
            print("DEBUG: Camera stopped successfully")
            
            // 프리뷰 레이어 제거 (메모리 관리)
            DispatchQueue.main.async {
              self.previewLayer?.removeFromSuperlayer()
            }
          } else {
            print("DEBUG: Failed to stop camera session")
          }
        }
      } else {
        print("DEBUG: Camera already stopped, no need to stop")
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
      guard let self = self else { 
        DispatchQueue.main.async { completion(nil, NSError(domain: "VideoCapture", code: 105, userInfo: [NSLocalizedDescriptionKey: "VideoCapture 객체가 해제됨"])) }
        return 
      }
      
      // 녹화를 시작하기 전에 세션이 실행 중인지 확인
      guard self.captureSession.isRunning else {
        print("DEBUG: 카메라 세션이 실행 중이지 않아 녹화를 시작할 수 없습니다.")
        DispatchQueue.main.async { completion(nil, NSError(domain: "VideoCapture", code: 106, userInfo: [NSLocalizedDescriptionKey: "카메라 세션이 실행 중이지 않음"])) }
        return
      }
      
      // 실제 녹화 시작 전에 플래그 설정
      self.isRecording = true
      
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
          // 비디오 방향 설정
          connection.videoOrientation = .portrait
          connection.isVideoMirrored = self.currentPosition == AVCaptureDevice.Position.front
          
          // 슬로우 모션 모드인 경우 추가 설정
          if self.isSlowMotionEnabled {
            print("DEBUG: 슬로우 모션 모드로 녹화 시작 - \(self.currentFrameRate) FPS")
            
            // 비디오 안정화 설정 (가능한 경우)
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
        
        // 녹화 시작 시도
        do {
          // iOS 14+ 에서만 가능한 추가 구성
          if #available(iOS 14.0, *) {
            if let audioConnection = self.movieFileOutput.connection(with: .audio) {
              // 오디오 설정이 가능한지 확인
              if audioConnection.isActive && !audioConnection.isEnabled {
                audioConnection.isEnabled = true
              }
            }
          }
          
          self.movieFileOutput.startRecording(to: fileURL, recordingDelegate: self)
          print("DEBUG: Video recording started to \(fileURL.path)")
        } catch {
          print("DEBUG: ❌ 녹화 시작 오류: \(error)")
          self.isRecording = false
          DispatchQueue.main.async {
            completion(nil, NSError(domain: "VideoCapture", code: 107, userInfo: [NSLocalizedDescriptionKey: "녹화 시작 실패: \(error.localizedDescription)"])) 
          }
        }
      } else {
        self.isRecording = false
        DispatchQueue.main.async {
          completion(nil, NSError(domain: "VideoCapture", code: 101, userInfo: [NSLocalizedDescriptionKey: "녹화 시작 실패 - 이미 다른 녹화가 진행 중"]))
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
      guard let self = self else {
        DispatchQueue.main.async { completion(nil, NSError(domain: "VideoCapture", code: 108, userInfo: [NSLocalizedDescriptionKey: "VideoCapture 객체가 해제됨"])) }
        return
      }
      
      if self.movieFileOutput.isRecording {
        print("DEBUG: 녹화 중지 시도 중...")
        
        // 원래의 콜백을 저장하고 새 콜백 설정
        self.recordingCompletionHandler = { [weak self] (url, error) in
          guard let self = self else {
            completion(url, error)
            return
          }
          
          self.isRecording = false
          
          if let error = error {
            print("DEBUG: 녹화 중지 오류: \(error)")
            completion(nil, error)
          } else if let url = url {
            print("DEBUG: 녹화 성공적으로 완료됨: \(url.path)")
            completion(url, nil)
          } else {
            print("DEBUG: 녹화가 중지되었으나 URL이 없음")
            completion(nil, NSError(domain: "VideoCapture", code: 109, userInfo: [NSLocalizedDescriptionKey: "녹화 URL을 찾을 수 없음"]))
          }
        }
        
        // 녹화 중지
        self.movieFileOutput.stopRecording()
      } else {
        // 이상 상태: isRecording은 true지만 실제로는 녹화 중이 아님
        print("DEBUG: ⚠️ 녹화 플래그는 활성화되어 있으나 실제 녹화는 진행 중이 아님")
        self.isRecording = false
        DispatchQueue.main.async {
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
    guard let device = self.currentDevice else { 
      print("DEBUG: Cannot set frame rate - no device available")
      return false 
    }
    
    // 이미 같은 FPS라면 변경 불필요
    if self.currentFrameRate == fps {
      print("DEBUG: Frame rate already set to \(fps) FPS")
      return true
    }
    
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
      print("DEBUG: Frame rate successfully set to \(targetFps) FPS")
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
    
    // 모든 포맷 정보 간단히 로깅 (너무 많은 로그 생성 방지)
    print("DEBUG: 슬로우 모션 포맷 검색 시작")
    
    // 1. 먼저 SlowMo 전용 포맷 찾기 (120fps 이상을 지원하는 포맷)
    var bestFormat: AVCaptureDevice.Format? = nil
    var bestFrameRate: Float64 = 0
    var bestResolution: Int32 = 0
    
    for format in device.formats {
      let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
      let resolution = dimensions.width * dimensions.height
      
      // 포맷의 프레임 레이트 범위 확인
      for range in format.videoSupportedFrameRateRanges {
        // 120fps 이상을 지원하는 포맷 찾기
        if range.maxFrameRate >= 120 {
          // 프레임레이트가 더 높거나, 같은 프레임레이트면 해상도가 더 높은 포맷 선택
          if range.maxFrameRate > bestFrameRate || 
            (range.maxFrameRate == bestFrameRate && resolution > bestResolution) {
            bestFormat = format
            bestFrameRate = range.maxFrameRate
            bestResolution = resolution
            print("DEBUG: ✅ 슬로우 모션 포맷 후보: \(dimensions.width)x\(dimensions.height) @ \(bestFrameRate)fps")
          }
        }
      }
    }
    
    if let format = bestFormat {
      let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
      let formatTypeStr = CMFormatDescriptionGetMediaSubType(format.formatDescription).toString()
      print("DEBUG: 🎯 선택된 슬로우 모션 포맷: \(dimensions.width)x\(dimensions.height) \(formatTypeStr), \(bestFrameRate)fps")
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
    
    if bestFormat == nil {
      // 높은 해상도의 포맷을 찾지 못한 경우 낮은 해상도라도 사용
      for format in device.formats {
        for range in format.videoSupportedFrameRateRanges {
          if range.maxFrameRate >= 30 {
            bestFormat = format
            break
          }
        }
        if bestFormat != nil {
          break
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
    
    // 녹화 중에는 모드 변경 금지
    if isRecording {
      print("DEBUG: ⚠️ 녹화 중에는 슬로우 모션 모드를 변경할 수 없습니다")
      return false
    }
    
    do {
      // 세션 재구성 시작 전 카메라가 실행 중인지 확인
      let wasRunning = captureSession.isRunning
      
      // 실행 중이라면 잠시 중지
      if wasRunning {
        captureSession.stopRunning()
        // 세션이 완전히 중지될 때까지 짧게 대기
        Thread.sleep(forTimeInterval: 0.2)
      }
      
      // 세션 재구성 시작
      captureSession.beginConfiguration()
      
      // 기존 비디오 입력/출력 임시 저장 (오디오는 유지)
      var videoInputs = [AVCaptureDeviceInput]()
      for input in captureSession.inputs {
        if let deviceInput = input as? AVCaptureDeviceInput, 
           deviceInput.device.hasMediaType(AVMediaType.video) {
          videoInputs.append(deviceInput)
          captureSession.removeInput(deviceInput)
        }
      }
      
      if enable {
        print("DEBUG: 슬로우 모션 모드 활성화 시도 중...")
        
        // 기존 세션 설정 백업
        let previousPreset = captureSession.sessionPreset
        
        // SlowMo 전용 프리셋으로 설정
        captureSession.sessionPreset = AVCaptureSession.Preset.hd1280x720
        
        // 슬로우 모션 모드 활성화 (120fps 또는 240fps)
        guard let slowMotionFormat = findSlowMotionFormat() else {
          // 실패 시 원래 설정으로 복원
          captureSession.sessionPreset = previousPreset
          for input in videoInputs {
            if captureSession.canAddInput(input) {
              captureSession.addInput(input)
            }
          }
          
          print("DEBUG: ❌ 슬로우 모션 포맷을 찾을 수 없어 활성화 실패")
          captureSession.commitConfiguration()
          
          // 이전에 실행 중이었다면 다시 시작
          if wasRunning {
            captureSession.startRunning()
          }
          
          return false
        }
        
        // 포맷 변경 전 카메라 구성 잠금
        try device.lockForConfiguration()
        
        // 새 포맷으로 변경
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
        do {
          let newInput = try AVCaptureDeviceInput(device: device)
          if captureSession.canAddInput(newInput) {
            captureSession.addInput(newInput)
          } else {
            throw NSError(domain: "VideoCapture", code: 3, userInfo: [NSLocalizedDescriptionKey: "Cannot add video input for slow motion"])
          }
        } catch {
          print("DEBUG: ❌ 슬로우 모션 비디오 입력 설정 오류: \(error)")
          
          // 원래 입력으로 복구 시도
          for input in videoInputs {
            if captureSession.canAddInput(input) {
              captureSession.addInput(input)
            }
          }
        }
        
        print("DEBUG: ✅ 슬로우 모션 활성화 성공: \(targetFrameRate) FPS")
      } else {
        print("DEBUG: 일반 비디오 모드로 복귀 중...")
        
        // 기본 세션 프리셋으로 복원
        captureSession.sessionPreset = AVCaptureSession.Preset.high
        
        // 슬로우 모션 모드 비활성화 (일반 녹화로 돌아감)
        guard let normalFormat = findNormalVideoFormat() else {
          print("DEBUG: ❌ 일반 비디오 포맷을 찾을 수 없어 비활성화 실패")
          
          // 원래 입력 복원
          for input in videoInputs {
            if captureSession.canAddInput(input) {
              captureSession.addInput(input)
            }
          }
          
          captureSession.commitConfiguration()
          
          // 이전에 실행 중이었다면 다시 시작
          if wasRunning {
            captureSession.startRunning()
          }
          
          return false
        }
        
        // 포맷 변경 전 카메라 구성 잠금
        try device.lockForConfiguration()
        
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
        do {
          let newInput = try AVCaptureDeviceInput(device: device)
          if captureSession.canAddInput(newInput) {
            captureSession.addInput(newInput)
          } else {
            throw NSError(domain: "VideoCapture", code: 4, userInfo: [NSLocalizedDescriptionKey: "Cannot add video input for normal mode"])
          }
        } catch {
          print("DEBUG: ❌ 일반 모드 비디오 입력 설정 오류: \(error)")
          
          // 원래 입력으로 복구 시도
          for input in videoInputs {
            if captureSession.canAddInput(input) {
              captureSession.addInput(input)
            }
          }
        }
        
        print("DEBUG: ✅ 일반 비디오 모드 복귀 성공: 30 FPS")
      }
      
      // 변경사항 적용
      captureSession.commitConfiguration()
      
      // 이전에 실행 중이었다면 다시 시작
      if wasRunning {
        captureSession.startRunning()
      }
      
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

  // 리소스 해제 메서드 추가
  public func releaseResources() {
    print("DEBUG: 비디오 캡처 리소스 해제 시작")
    
    // 진행 중인 녹화가 있다면 중지
    if isRecording && movieFileOutput.isRecording {
      movieFileOutput.stopRecording()
      isRecording = false
      print("DEBUG: 진행 중인 녹화를 중지함")
    }
    
    cameraQueue.async { [weak self] in
      guard let self = self else { return }
      
      // 세션 실행 중이면 중지
      if self.captureSession.isRunning {
        self.captureSession.stopRunning()
        print("DEBUG: 실행 중인 카메라 세션 중지됨")
      }
      
      // 세션 구성 시작
      self.captureSession.beginConfiguration()
      
      // 모든 입력 제거
      for input in self.captureSession.inputs {
        self.captureSession.removeInput(input)
      }
      
      // 모든 출력 제거
      for output in self.captureSession.outputs {
        self.captureSession.removeOutput(output)
      }
      
      self.captureSession.commitConfiguration()
      
      // 프리뷰 레이어 제거
      DispatchQueue.main.async {
        self.previewLayer?.removeFromSuperlayer()
        self.previewLayer = nil
        print("DEBUG: 비디오 캡처 리소스 해제 완료")
      }
    }
  }

  // 클래스가 정리될 때 리소스를 해제하도록 deinit 추가
  deinit {
    print("DEBUG: VideoCapture deinit 호출됨")
    releaseResources()
  }
}

extension VideoCapture: AVCaptureVideoDataOutputSampleBufferDelegate {
  public func captureOutput(
    _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    delegate?.videoCapture(self, didCaptureVideoFrame: sampleBuffer)
  }
  
  // 출력이 삭제되었을 때 호출되는 메서드
  public func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
    // 프레임 드롭 로깅 (성능 문제 진단용)
    print("DEBUG: 프레임 드롭 발생")
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
