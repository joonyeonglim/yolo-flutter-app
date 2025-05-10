import Foundation

public protocol FrameRateConfigurable {
    var currentFrameRate: Int { get }
    func getSupportedFrameRatesInfo() -> [String: Bool]
    func isFrameRateSupported(_ fps: Double) -> Bool
    func setFrameRate(_ fps: Int) -> Bool
    
    // 슬로우 모션 관련
    var isSlowMotionEnabled: Bool { get }
    func enableSlowMotion(_ enable: Bool) -> Bool
    func isSlowMotionSupported() -> Bool
    func getMaxSlowMotionFrameRate() -> Int
    func isSlowMotionActive() -> Bool
} 