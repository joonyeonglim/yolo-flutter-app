// 이 파일은 리팩토링 후 모듈화된 VideoCapture 구현을 참조합니다.
// 모든 실제 구현은 VideoCapture/ 디렉토리 내의 파일들로 분리되었습니다.

// 기존 프로젝트와의 호환성을 유지하기 위해 원래 API를 그대로 노출합니다.
// 클래스 정의와 함께 모든 프로토콜 및 확장 기능을 포함합니다.

// FourCharCode 확장은 그대로 유지 (호환성을 위해)
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

// 베스트 카메라 장치 선택 함수 (호환성을 위해)
func bestCaptureDevice(position: AVCaptureDevice.Position) -> AVCaptureDevice {
  return AVCaptureDevice.bestCaptureDevice(position: position)
}

// VideoCapture 클래스는 원래와 동일한 API를 유지합니다.
public class VideoCapture: NSObject {
  // MARK: - 공개 속성
  public var previewLayer: AVCaptureVideoPreviewLayer?
  public weak var delegate: VideoCaptureDelegate?
  public var lastCapturedPhoto: UIImage?
  public weak var nativeView: FLNativeView?
  public let captureSession = AVCaptureSession()
  public var currentDevice: AVCaptureDevice?
  
  // MARK: - 내부 속성
  let videoOutput = AVCaptureVideoDataOutput()
  let photoOutput = AVCapturePhotoOutput()
  let movieFileOutput = AVCaptureMovieFileOutput()
  let cameraQueue = DispatchQueue(label: "camera-queue")
  
  var isRecording = false
  var currentRecordingURL: URL?
  var recordingCompletionHandler: ((URL?, Error?) -> Void)?
  var currentPosition: AVCaptureDevice.Position = .back
  var currentZoomFactor: CGFloat = 1.0
  var audioEnabled = true
  
  var currentFrameRate: Int = 30
  var isSlowMotionEnabled: Bool = false
  
  // MARK: - 초기화
  public override init() {
    super.init()
    print("DEBUG: VideoCapture initialized")
  }
  
  deinit {
    print("DEBUG: VideoCapture deinit 호출됨")
    releaseResources()
  }
}

// 프로토콜 준수 및 기타 기능은 해당 파일에서 구현됨
// VideoCapture/Delegates/VideoCaptureDelegates.swift
// VideoCapture/Components/VideoCaptureSetup.swift
// VideoCapture/Components/VideoRecordingManager.swift
// VideoCapture/Components/FrameRateManager.swift
// VideoCapture/Components/SlowMotionSupport.swift