import CoreML

public class LocalModel {
    public var task: String
    var modelPath: String
    var model: MLModel?

    public init(modelPath: String, task: String) {
        self.modelPath = modelPath
        self.task = task
    }

    public func loadModel() throws {
        let fileURL = URL(fileURLWithPath: modelPath)
        let fileExtension = fileURL.pathExtension.lowercased()

        do {
            if fileExtension == "mlmodelc" {
                // mlmodelc 형식은 직접 로드
                self.model = try MLModel(contentsOf: fileURL)
            } else if fileExtension == "mlmodel" {
                // mlmodel 형식은 컴파일 후 로드
                let compiledModelURL = try MLModel.compileModel(at: fileURL)
                self.model = try MLModel(contentsOf: compiledModelURL)
            } else {
                throw NSError(domain: "Unsupported model file extension", code: -1, userInfo: nil)
            }
        } catch {
            print("Model loading error: \(error)")
            throw error
        }
    }

    public func predict(input: MLFeatureProvider) throws -> MLFeatureProvider? {
        guard let model = self.model else {
            throw NSError(domain: "Model not loaded", code: -1, userInfo: nil)
        }
        return try model.prediction(from: input)
    }
}
