import CoreML

// YoloModel 프로토콜을 준수하도록 변경
public class LocalModel: YoloModel {
  public var task: String
  var modelPath: String

    public init(modelPath: String, task: String) {
        self.modelPath = modelPath
        self.task = task
    }

    public func loadModel() async throws -> MLModel? {
        let fileURL = URL(fileURLWithPath: modelPath)
        let fileExtension = fileURL.pathExtension.lowercased()

        do {
            if fileExtension == "mlmodelc" {
                // 이미 컴파일된 모델은 직접 로드
                return try MLModel(contentsOf: fileURL)
            } else if fileExtension == "mlmodel" || fileExtension == "mlpackage" {
                // mlmodel과 mlpackage는 동일하게 컴파일 후 로드
                let compiledModelURL = try MLModel.compileModel(at: fileURL)
                return try MLModel(contentsOf: compiledModelURL)
            } else {
                throw NSError(domain: "Unsupported model file extension", code: -1, userInfo: nil)
            }
        } catch {
            print("Model loading error: \(error)")
            throw error
        }
    }
}
