import AVFoundation
import UIKit

// 카메라 설정 관련 기능
extension VideoCapture {
  
  func setUp(
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

      self.configureSession(sessionPreset: sessionPreset, position: position, completion: completion)
    }
  }
  
  private func configureSession(sessionPreset: AVCaptureSession.Preset, position: AVCaptureDevice.Position, completion: @escaping (Bool) -> Void) {
    captureSession.beginConfiguration()

    // Remove existing inputs/outputs
    for input in captureSession.inputs {
      captureSession.removeInput(input)
    }
    for output in captureSession.outputs {
      captureSession.removeOutput(output)
    }

    captureSession.sessionPreset = sessionPreset

    do {
      // 개선된 카메라 장치 선택 로직 사용
      let device = AVCaptureDevice.bestCaptureDevice(position: position)
      self.currentDevice = device
      
      // 안전하게 현재 줌 팩터 초기화
      self.currentZoomFactor = 1.0
      self.isSlowMotionEnabled = false
      self.currentFrameRate = 30
      
      try configureDevice(device)
      try setupCameraInput(device)
      setupAudioInput()
      setupOutputs()

      captureSession.commitConfiguration()

      // Set up preview layer on main thread
      setupPreviewLayer(position: position, completion: completion)
    } catch {
      print("DEBUG: Camera setup error:", error)
      captureSession.commitConfiguration()
      DispatchQueue.main.async { completion(false) }
    }
  }
  
  private func configureDevice(_ device: AVCaptureDevice) throws {
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
    let (bestFormat, maxFrameRate) = findBestVideoFormat(device)
    
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
  }
  
  private func findBestVideoFormat(_ device: AVCaptureDevice) -> (AVCaptureDevice.Format?, Float64) {
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
    
    return (bestFormat, maxFrameRate)
  }
  
  private func setupCameraInput(_ device: AVCaptureDevice) throws {
    let input = try AVCaptureDeviceInput(device: device)
    if captureSession.canAddInput(input) {
      captureSession.addInput(input)
      print("DEBUG: Added camera input")
    } else {
      print("DEBUG: ⚠️ Cannot add camera input")
      throw NSError(domain: "VideoCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot add camera input"])
    }
  }
  
  private func setupAudioInput() {
    // 오디오 입력 설정
    if audioEnabled, let audioDevice = AVCaptureDevice.default(for: .audio) {
      do {
        let audioInput = try AVCaptureDeviceInput(device: audioDevice)
        if captureSession.canAddInput(audioInput) {
          captureSession.addInput(audioInput)
          print("DEBUG: Added audio input")
        } else {
          print("DEBUG: ⚠️ Cannot add audio input")
        }
      } catch {
        print("DEBUG: Could not create audio input: \(error)")
      }
    }
  }
  
  private func setupOutputs() {
    // Set up video output
    videoOutput.videoSettings = [
      kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: kCVPixelFormatType_32BGRA)
    ]
    videoOutput.alwaysDiscardsLateVideoFrames = true
    videoOutput.setSampleBufferDelegate(self, queue: cameraQueue)

    if captureSession.canAddOutput(videoOutput) {
      captureSession.addOutput(videoOutput)
      print("DEBUG: Added video output")
    } else {
      print("DEBUG: ⚠️ Cannot add video output")
    }

    if captureSession.canAddOutput(photoOutput) {
      captureSession.addOutput(photoOutput)
      print("DEBUG: Added photo output")
    } else {
      print("DEBUG: ⚠️ Cannot add photo output")
    }

    // 비디오 녹화를 위한 출력 설정
    if captureSession.canAddOutput(movieFileOutput) {
      captureSession.addOutput(movieFileOutput)
      print("DEBUG: Added movie file output")
      
      // 비디오 연결 설정
      if let connection = movieFileOutput.connection(with: .video) {
        connection.videoOrientation = .portrait
        connection.isVideoMirrored = currentPosition == .front
        
        // 비디오 안정화 설정
        if connection.isVideoStabilizationSupported {
          connection.preferredVideoStabilizationMode = .auto
        }
        
        print("DEBUG: Configured movie file output video connection")
      } else {
        print("DEBUG: ⚠️ Movie file output has no video connection")
      }
      
      // 오디오 연결 설정
      if let connection = movieFileOutput.connection(with: .audio) {
        connection.isEnabled = audioEnabled
        print("DEBUG: Configured movie file output audio connection: \(audioEnabled ? "enabled" : "disabled")")
      }
    } else {
      print("DEBUG: ⚠️ Cannot add movie output")
    }

    let connection = videoOutput.connection(with: .video)
    connection?.videoOrientation = .portrait
    connection?.isVideoMirrored = currentPosition == .front
  }
  
  private func setupPreviewLayer(position: AVCaptureDevice.Position, completion: @escaping (Bool) -> Void) {
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      
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
  }
  
  // 줌 설정
  func setZoomRatio(_ zoomFactor: CGFloat) {
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

  // 세션 시작
  func start() {
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

  // 세션 중지
  func stop() {
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
  
  // 리소스 해제
  func releaseResources() {
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
} 