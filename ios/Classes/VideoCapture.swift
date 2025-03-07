import AVFoundation
import CoreVideo
import UIKit

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
        device.unlockForConfiguration()

        let input = try AVCaptureDeviceInput(device: device)
        if self.captureSession.canAddInput(input) {
          self.captureSession.addInput(input)
          print("DEBUG: Added camera input")
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

          completion(true)
        }
      } catch {
        print("DEBUG: Camera setup error:", error)
        self.captureSession.commitConfiguration()
        DispatchQueue.main.async { completion(false) }
      }
    }
  }

  public func start() {
    if !captureSession.isRunning {
      cameraQueue.async { [weak self] in
        guard let self = self else { return }
        
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
        // 비디오 설정 구성
        if let connection = self.movieFileOutput.connection(with: .video) {
          connection.videoOrientation = .portrait
          connection.isVideoMirrored = self.currentPosition == AVCaptureDevice.Position.front
          
          // 비디오 안정화 설정 (가능한 경우)
          if connection.isVideoStabilizationSupported {
            connection.preferredVideoStabilizationMode = .auto
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
        self.recordingCompletionHandler = completion
        self.movieFileOutput.stopRecording()
      } else {
        DispatchQueue.main.async {
          self.isRecording = false
          completion(nil, NSError(domain: "VideoCapture", code: 103, userInfo: [NSLocalizedDescriptionKey: "녹화가 이미 중지됨"]))
        }
      }
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
