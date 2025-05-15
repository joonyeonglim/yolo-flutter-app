import AVFoundation
import UIKit

// 비디오 캡처 델리게이트 확장
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

// 사진 촬영 델리게이트 확장
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

// 파일 출력 델리게이트 확장
extension VideoCapture: AVCaptureFileOutputRecordingDelegate {
  public func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
    // 녹화가 시작되면 확실하게 isRecording 플래그를 true로 설정
    isRecording = true
    
    print("DEBUG: Recording started to \(fileURL.path)")
    print("DEBUG: movieFileOutput.isRecording 값: \(self.movieFileOutput.isRecording)")
    print("DEBUG: connections 개수: \(connections.count)")
    
    // 녹화가 실제로 시작되었는지 확인하기 위해 연결 정보 출력
    for (index, connection) in connections.enumerated() {
      // inputPorts를 통해 미디어 유형 확인
      let mediaTypes = connection.inputPorts.compactMap { $0.mediaType.rawValue }
      let mediaTypeStr = mediaTypes.isEmpty ? "unknown" : mediaTypes.joined(separator: ", ")
      print("DEBUG: Connection \(index): \(mediaTypeStr) enabled: \(connection.isEnabled)")
    }
  }
  
  public func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
    // 녹화가 끝나면 항상 isRecording 플래그를 false로 설정
    let wasRecording = isRecording
    isRecording = false
    
    print("DEBUG: 녹화 종료됨, 이전 isRecording 상태: \(wasRecording)")
    
    if let error = error {
      print("DEBUG: Recording error: \(error.localizedDescription)")
      
      // 오류 세부 정보 출력 (AVErrorKeys 활용)
      if let avError = error as? AVError {
        print("DEBUG: AVError 코드: \(avError.code.rawValue)")
      }
      
      // 녹화 중 오류가 발생해도 콜백 호출
      recordingCompletionHandler?(nil, error)
    } else {
      print("DEBUG: Recording finished successfully at \(outputFileURL.path)")
      
      // 파일이 실제로 존재하는지 확인
      let fileExists = FileManager.default.fileExists(atPath: outputFileURL.path)
      print("DEBUG: 녹화된 파일 존재 여부: \(fileExists ? "있음" : "없음")")
      
      recordingCompletionHandler?(outputFileURL, nil)
    }
    
    recordingCompletionHandler = nil
  }
} 