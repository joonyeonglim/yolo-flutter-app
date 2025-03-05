import CoreML

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
      if fileExtension == "mlpackage" {
        // mlpackage 형식은 직접 로드
        return try MLModel(contentsOf: fileURL)
      } else {
        // mlmodel 형식은 컴파일 후 로드
        let compiledModelURL = try await MLModel.compileModel(at: fileURL)
        return try MLModel(contentsOf: compiledModelURL)
      }
    } catch {
      print("Model loading error: \(error)")
      throw error
    }
  }
}
