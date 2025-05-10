import Foundation

public protocol VideoRecordable {
    var isRecording: Bool { get }
    func startRecording(completion: @escaping (URL?, Error?) -> Void)
    func stopRecording(completion: @escaping (URL?, Error?) -> Void)
} 