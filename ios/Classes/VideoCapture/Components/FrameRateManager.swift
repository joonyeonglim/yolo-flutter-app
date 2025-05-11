import AVFoundation

// 프레임 레이트 관리 기능
extension VideoCapture {
  func getSupportedFrameRatesInfo() -> [String: Bool] {
    let fpsValues = [30.0, 60.0, 90.0, 120.0]
    var result = [String: Bool]()
    
    for fps in fpsValues {
      let key = "\(Int(fps))fps"
      result[key] = isFrameRateSupported(fps)
    }
    
    print("DEBUG: Supported frame rates: \(result)")
    return result
  }

  func isFrameRateSupported(_ fps: Double) -> Bool {
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
  
  func setFrameRate(_ fps: Int) -> Bool {
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
      let originalFormat = device.activeFormat // 원래 포맷 저장
      do {
        try device.lockForConfiguration()
        device.activeFormat = newFormat
        device.unlockForConfiguration()
        
        let dimensions = CMVideoFormatDescriptionGetDimensions(newFormat.formatDescription)
        print("DEBUG: Switched to format with resolution \(dimensions.width)x\(dimensions.height) supporting \(fps) FPS")
      } catch {
        print("DEBUG: Failed to switch format: \(error)")
        // 실패한 경우 원래 포맷으로 복원
        do {
          try device.lockForConfiguration()
          device.activeFormat = originalFormat
          device.unlockForConfiguration()
          print("DEBUG: Restored original format after failure")
        } catch {
          print("DEBUG: Failed to restore original format: \(error)")
        }
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
} 