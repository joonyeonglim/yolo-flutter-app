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
        print("Loading model with path: \(modelPath)")

        let fileURL: URL

        // 절대 경로인지 확인
        if modelPath.hasPrefix("/") {
            fileURL = URL(fileURLWithPath: modelPath)
            print("Using absolute path: \(fileURL.path)")
        } else {
            // Bundle 리소스에서 찾기 - 파일명과 확장자 정확히 분리
            let url = URL(fileURLWithPath: modelPath)
            let resourceName = url.deletingPathExtension().lastPathComponent
            let resourceExtension = url.pathExtension.isEmpty ? nil : url.pathExtension
            
            print("Searching bundle for - name: \(resourceName), extension: \(resourceExtension ?? "nil")")

            if let bundlePath = Bundle.main.path(forResource: resourceName, ofType: resourceExtension) {
                fileURL = URL(fileURLWithPath: bundlePath)
                print("Found bundle path: \(bundlePath)")
            } else {
                throw NSError(domain: "Model file not found in bundle", code: -1, userInfo: [
                    "modelPath": modelPath,
                    "resourceName": resourceName,
                    "resourceExtension": resourceExtension ?? "nil",
                    "bundleResourcesPath": Bundle.main.bundlePath
                ])
            }
        }
        
        let fileExtension = fileURL.pathExtension.lowercased()
        print("File extension: \(fileExtension)")
        print("Final file URL: \(fileURL)")

        do {
            if fileExtension == "mlmodelc" {
                // 컴파일된 모델 로드 (Apple이 암호화/복호화 자동 처리)
                return try MLModel(contentsOf: fileURL)
            } else if fileExtension == "mlmodel" || fileExtension == "mlpackage" {
                // 컴파일된 모델 경로 확인
                let fileManager = FileManager.default
                let modelFileName = fileURL.lastPathComponent
                let compiledModelName = modelFileName.replacingOccurrences(of: fileURL.pathExtension, with: "mlmodelc")
                let compiledModelURL = fileURL.deletingLastPathComponent().appendingPathComponent(compiledModelName)

                // 이미 컴파일된 모델이 있는지 확인
                if fileManager.fileExists(atPath: compiledModelURL.path) {
                    return try MLModel(contentsOf: compiledModelURL)
                } else {
                    // 컴파일된 모델이 없으면 컴파일 후 로드
                    let newCompiledModelURL = try MLModel.compileModel(at: fileURL)
                    return try MLModel(contentsOf: newCompiledModelURL)
                }
            } else {
                throw NSError(domain: "Unsupported model file extension", code: -1, userInfo: nil)
            }
        } catch {
            print("Model loading error: \(error)")
            throw error
        }
    }
}
