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