import AVFoundation

// 슬로우 모션 관련 기능
extension VideoCapture {
  // 슬로우 모션 녹화를 위한 최적 포맷을 찾는 메서드
  func findSlowMotionFormat() -> AVCaptureDevice.Format? {
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
  func findNormalVideoFormat(minResolution: (width: Int32, height: Int32) = (1920, 1080)) -> AVCaptureDevice.Format? {
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
  func enableSlowMotion(_ enable: Bool) -> Bool {
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
  func isSlowMotionSupported() -> Bool {
    let result = findSlowMotionFormat() != nil
    print("DEBUG: 슬로우 모션 지원 여부: \(result)")
    return result
  }
  
  // 디바이스가 지원하는 최대 슬로우 모션 프레임레이트 확인
  func getMaxSlowMotionFrameRate() -> Int {
    guard let format = findSlowMotionFormat() else { return 0 }
    
    let maxFrameRate = Int(format.videoSupportedFrameRateRanges.map { $0.maxFrameRate }.max() ?? 0.0)
    return maxFrameRate
  }
  
  // 현재 슬로우 모션 활성화 상태 확인
  func isSlowMotionActive() -> Bool {
    return isSlowMotionEnabled
  }
  
  // FPS 문자열 표시를 위한 확장 함수
  func getMaxFPSString() -> String {
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