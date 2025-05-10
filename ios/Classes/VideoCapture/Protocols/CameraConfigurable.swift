import AVFoundation

public protocol CameraConfigurable {
    func setUp(sessionPreset: AVCaptureSession.Preset, position: AVCaptureDevice.Position, completion: @escaping (Bool) -> Void)
    func setZoomRatio(_ zoomFactor: CGFloat)
    func start()
    func stop()
    func releaseResources()
} 