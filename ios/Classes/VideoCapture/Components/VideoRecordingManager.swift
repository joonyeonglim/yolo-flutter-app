import AVFoundation
import Foundation

// 비디오 녹화 관련 기능
extension VideoCapture {
  func startRecording(completion: @escaping (URL?, Error?) -> Void) {
    // 이미 녹화 중인지 실제 movieFileOutput 상태로 확인
    if movieFileOutput.isRecording {
      completion(nil, NSError(domain: "VideoCapture", code: 100, userInfo: [NSLocalizedDescriptionKey: "이미 녹화 중입니다"]))
      return
    }
    
    // isRecording 플래그가 true인데 실제로 녹화가 진행 중이 아닌 경우
    if isRecording && !movieFileOutput.isRecording {
      print("DEBUG: 상태 불일치 감지 - isRecording은 true이나 실제로는 녹화 중이 아님")
      isRecording = false // 상태 재설정
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
      
      // captureSession이 실행 중인지 확인
      guard self.captureSession.isRunning else {
        DispatchQueue.main.async { completion(nil, NSError(domain: "VideoCapture", code: 107, userInfo: [NSLocalizedDescriptionKey: "카메라 세션이 실행 중이 아님"])) }
        return
      }
      
      // 출력이 모두 설정되어 있는지 확인
      if !self.captureSession.outputs.contains(self.movieFileOutput) {
        // 출력이 없으면 다시 추가 시도
        self.captureSession.beginConfiguration()
        if self.captureSession.canAddOutput(self.movieFileOutput) {
          self.captureSession.addOutput(self.movieFileOutput)
          print("DEBUG: movieFileOutput 다시 추가됨")
        }
        self.captureSession.commitConfiguration()
        
        // 여전히 없으면 오류 반환
        if !self.captureSession.outputs.contains(self.movieFileOutput) {
          DispatchQueue.main.async { completion(nil, NSError(domain: "VideoCapture", code: 110, userInfo: [NSLocalizedDescriptionKey: "movieFileOutput을 세션에 추가할 수 없음"])) }
          return
        }
      }
      
      // 실제 녹화 시작 전에 플래그 설정
      self.isRecording = true
      
      if self.movieFileOutput.isRecording == false {
        // 디버그: movieFileOutput 상태 확인
        print("DEBUG: movieFileOutput 상태 확인 - 연결된 출력 개수: \(self.captureSession.outputs.count)")
        print("DEBUG: movieFileOutput이 captureSession에 포함되어 있는지: \(self.captureSession.outputs.contains(self.movieFileOutput))")
        
        let connections = self.movieFileOutput.connections
        if !connections.isEmpty {
          print("DEBUG: movieFileOutput에 \(connections.count)개의 연결이 있습니다")
          for (index, connection) in connections.enumerated() {
            // inputPorts를 통해 미디어 유형 확인
            let mediaTypes = connection.inputPorts.compactMap { $0.mediaType.rawValue }
            let mediaTypeStr = mediaTypes.isEmpty ? "unknown" : mediaTypes.joined(separator: ", ")
            print("DEBUG: Connection \(index): \(mediaTypeStr) enabled: \(connection.isEnabled)")
          }
        } else {
          print("DEBUG: ⚠️ movieFileOutput에 연결이 없습니다! 이는 녹화가 작동하지 않는 원인일 수 있습니다.")
          
          // 연결이 없는 경우 녹화 상태를 초기화하고 오류 반환
          self.isRecording = false
          DispatchQueue.main.async {
            completion(nil, NSError(domain: "VideoCapture", code: 111, userInfo: [NSLocalizedDescriptionKey: "movieFileOutput에 연결이 없음"]))
          }
          return
        }
        
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
        // iOS 14+ 에서만 가능한 추가 구성
        if #available(iOS 14.0, *) {
          if let audioConnection = self.movieFileOutput.connection(with: .audio) {
            // 오디오 설정이 가능한지 확인
            if audioConnection.isActive && !audioConnection.isEnabled {
              audioConnection.isEnabled = true
            }
          }
        }
        
        do {
          // 녹화를 try-catch로 감싸서 예상치 못한 예외 처리
          print("DEBUG: 녹화 시작 시도 to \(fileURL.path)")
          self.movieFileOutput.startRecording(to: fileURL, recordingDelegate: self)
          print("DEBUG: Video recording started successfully")
        } catch {
          // 예외 발생 시 상태 초기화 및 오류 보고
          print("DEBUG: 녹화 시작 중 예외 발생: \(error)")
          self.isRecording = false
          DispatchQueue.main.async {
            completion(nil, error)
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
  
  func stopRecording(completion: @escaping (URL?, Error?) -> Void) {
    // 실제 녹화 상태 확인 (이중 검증)
    if !movieFileOutput.isRecording {
      // 상태 불일치 감지 - isRecording 플래그 재설정
      if isRecording {
        print("DEBUG: 상태 불일치 감지 - isRecording은 true이나 실제로는 녹화 중이 아님")
        isRecording = false
      }
      
      // 사용자에게 오류 반환
      completion(nil, NSError(domain: "VideoCapture", code: 102, userInfo: [NSLocalizedDescriptionKey: "녹화 중이 아닙니다"]))
      return
    }
    
    cameraQueue.async { [weak self] in
      guard let self = self else {
        DispatchQueue.main.async { completion(nil, NSError(domain: "VideoCapture", code: 108, userInfo: [NSLocalizedDescriptionKey: "VideoCapture 객체가 해제됨"])) }
        return
      }
      
      // 녹화 중인지 다시 확인 (비동기 작업 중 상태가 변경되었을 수 있음)
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
            
            // 녹화 완료 후 약간의 지연 시간을 두어 리소스 정리
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
              completion(url, nil)
            }
          } else {
            print("DEBUG: 녹화가 중지되었으나 URL이 없음")
            completion(nil, NSError(domain: "VideoCapture", code: 109, userInfo: [NSLocalizedDescriptionKey: "녹화 URL을 찾을 수 없음"]))
          }
        }
        
        // 녹화 중지 시도를 try-catch로 감싸서 예외 처리
        do {
          // 녹화 중지
          self.movieFileOutput.stopRecording()
        } catch {
          print("DEBUG: 녹화 중지 중 예외 발생: \(error)")
          self.isRecording = false
          DispatchQueue.main.async {
            completion(nil, error)
          }
        }
      } else {
        // 이 시점에서는 isRecording과 실제 녹화 상태가 불일치하는 상황
        print("DEBUG: ⚠️ 상태 불일치: stopRecording 호출됨 - 실제 녹화 중이 아님")
        
        // 상태 정리 및 초기화
        self.isRecording = false
        
        // movieFileOutput이 정상적으로 연결되어 있지 않은 경우 재설정 시도
        if !self.captureSession.outputs.contains(self.movieFileOutput) {
          print("DEBUG: movieFileOutput이 연결되어 있지 않아 재설정 시도")
          
          // 세션 재구성
          self.captureSession.beginConfiguration()
          
          // movieFileOutput 다시 추가
          if self.captureSession.canAddOutput(self.movieFileOutput) {
            self.captureSession.addOutput(self.movieFileOutput)
            print("DEBUG: movieFileOutput 재연결 성공")
          } else {
            print("DEBUG: ⚠️ movieFileOutput 재연결 실패")
          }
          
          self.captureSession.commitConfiguration()
        }
        
        DispatchQueue.main.async {
          completion(nil, NSError(domain: "VideoCapture", code: 103, userInfo: [NSLocalizedDescriptionKey: "녹화가 이미 중지됨"]))
        }
      }
    }
  }

  // 오디오 입력이 있는지 확인하는 헬퍼 메서드
  func hasAudioInput() -> Bool {
    return captureSession.inputs.contains { input in
      guard let deviceInput = input as? AVCaptureDeviceInput else { return false }
      return deviceInput.device.hasMediaType(.audio)
    }
  }
  
  // 오디오 입력을 추가하는 헬퍼 메서드
  func addAudioInput() {
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

} 