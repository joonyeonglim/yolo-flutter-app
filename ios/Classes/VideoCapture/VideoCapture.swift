import AVFoundation
import CoreVideo
import UIKit

/**
 * VideoCapture 클래스 - 카메라 및 비디오 관련 기능을 담당
 * 리팩토링 후 코어 클래스
 */
public class VideoCapture: NSObject {
  // 프리뷰 및 델리게이트
  public var previewLayer: AVCaptureVideoPreviewLayer?
  public weak var delegate: VideoCaptureDelegate?
  public weak var nativeView: FLNativeView?
  
  // 캡처 세션 및 출력
  public let captureSession = AVCaptureSession()
  let videoOutput = AVCaptureVideoDataOutput()
  let photoOutput = AVCapturePhotoOutput()
  let movieFileOutput = AVCaptureMovieFileOutput()
  let cameraQueue = DispatchQueue(label: "camera-queue")
  
  // 사진 캡처 관련
  public var lastCapturedPhoto: UIImage?
  
  // 녹화 상태 관련 속성
  var isRecording = false
  var currentRecordingURL: URL?
  var recordingCompletionHandler: ((URL?, Error?) -> Void)?
  
  // 카메라 설정 관련 속성
  var currentPosition: AVCaptureDevice.Position = .back
  var currentZoomFactor: CGFloat = 1.0
  public var currentDevice: AVCaptureDevice?
  var audioEnabled = true
  
  // FPS 및 슬로우 모션 관련 속성
  var currentFrameRate: Int = 30
  var isSlowMotionEnabled: Bool = false
  
  // 초기화
  public override init() {
    super.init()
    print("DEBUG: VideoCapture initialized")
  }
  
  // 클래스가 정리될 때 리소스를 해제하도록 deinit 추가
  deinit {
    print("DEBUG: VideoCapture deinit 호출됨")
    releaseResources()
  }
} 