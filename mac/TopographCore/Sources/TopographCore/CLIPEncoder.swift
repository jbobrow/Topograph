import Accelerate
import CoreML
import Foundation

public enum CLIPError: Error, LocalizedError {
    case modelNotFound(URL)
    case unreadablePicture(URL)
    case noOutput

    public var errorDescription: String? {
        switch self {
        case .modelNotFound(let url): "No CLIP model at \(url.path). Run mac/tools/convert_clip.py to make it."
        case .unreadablePicture(let url): "Couldn't read the picture \(url.lastPathComponent)."
        case .noOutput: "The CLIP model returned nothing."
        }
    }
}

/// CLIP on this Mac through Core ML, making vectors comparable with the ones the Python
/// pipeline stores under `clip-vit-b-32`. Each model loads the first time it's needed.
public final class CLIPEncoder: @unchecked Sendable {
    public static let modelName = "clip-vit-b-32"
    public static let dimensions = 512
    private static let imageWeight: Float = 0.75     // image vs caption, as in embed.py
    private static let maxImages = 4
    private static let captionLength = 300

    public static var defaultFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Topograph/models/\(modelName)", directoryHint: .isDirectory)
    }

    public static func isInstalled(at folder: URL = defaultFolder) -> Bool {
        ["image", "text"].allSatisfy {
            FileManager.default.fileExists(atPath: folder.appending(path: "\($0).mlmodelc").path)
        }
    }

    private let folder: URL
    private let computeUnits: MLComputeUnits
    private let tokenizer: CLIPTokenizer
    private let lock = NSLock()
    private var imageModel: MLModel?
    private var textModel: MLModel?

    public init(folder: URL = CLIPEncoder.defaultFolder, computeUnits: MLComputeUnits = .all) throws {
        guard Self.isInstalled(at: folder) else { throw CLIPError.modelNotFound(folder) }
        self.folder = folder
        self.computeUnits = computeUnits
        tokenizer = try CLIPTokenizer()
    }

    private func model(_ name: String, keep: ReferenceWritableKeyPath<CLIPEncoder, MLModel?>) throws -> MLModel {
        lock.lock()
        defer { lock.unlock() }
        if let loaded = self[keyPath: keep] { return loaded }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        let loaded = try MLModel(contentsOf: folder.appending(path: "\(name).mlmodelc"), configuration: configuration)
        self[keyPath: keep] = loaded
        return loaded
    }

    private func run(_ model: MLModel, input name: String, array: MLMultiArray) throws -> [Float] {
        let provider = try MLDictionaryFeatureProvider(dictionary: [name: MLFeatureValue(multiArray: array)])
        guard let output = try model.prediction(from: provider).featureValue(for: "embedding")?.multiArrayValue else { throw CLIPError.noOutput }
        var vector = [Float](repeating: 0, count: Self.dimensions)
        output.withUnsafeBufferPointer(ofType: Float.self) { source in
            for index in vector.indices { vector[index] = source[index] }
        }
        return Self.normalized(vector)
    }

    private static func normalized(_ vector: [Float]) -> [Float] {
        vDSP.divide(vector, max(vDSP.sumOfSquares(vector).squareRoot(), 1e-9))
    }

    /// A unit vector for some text.
    public func embed(text: String) throws -> [Float] {
        let model = try model("text", keep: \.textModel)
        let tokens = tokenizer.tokens(text)
        let array = try MLMultiArray(shape: [1, NSNumber(value: tokens.count)], dataType: .int32)
        array.withUnsafeMutableBufferPointer(ofType: Int32.self) { out, _ in
            for index in tokens.indices { out[index] = tokens[index] }
        }
        return try run(model, input: "tokens", array: array)
    }

    /// A unit vector for one picture.
    public func embed(imageAt url: URL) throws -> [Float] {
        let model = try model("image", keep: \.imageModel)
        guard let image = CLIPImage.decode(url) else { throw CLIPError.unreadablePicture(url) }
        let pixels = CLIPImage.pixels(rgb: image.rgb, width: image.width, height: image.height)
        let side = NSNumber(value: CLIPImage.size)
        let array = try MLMultiArray(shape: [1, 3, side, side], dataType: .float32)
        array.withUnsafeMutableBufferPointer(ofType: Float.self) { out, _ in
            for index in pixels.indices { out[index] = pixels[index] }
        }
        return try run(model, input: "pixels", array: array)
    }

    /// An item's vector, by the pipeline's recipe: up to four pictures averaged, then
    /// blended with the caption's first 300 characters. With no picture, just the text.
    public func embedItem(pictures: [URL], caption: String?) throws -> [Float] {
        let text = caption.flatMap { $0.isEmpty ? nil : String(String.UnicodeScalarView($0.unicodeScalars.prefix(Self.captionLength))) }
        guard !pictures.isEmpty else { return try embed(text: text ?? "") }
        var sum = [Float](repeating: 0, count: Self.dimensions)
        for picture in pictures.prefix(Self.maxImages) { vDSP.add(sum, try embed(imageAt: picture), result: &sum) }
        let image = Self.normalized(sum)
        guard let text else { return image }
        let words = try embed(text: text)
        return Self.normalized(vDSP.add(vDSP.multiply(Self.imageWeight, image), vDSP.multiply(1 - Self.imageWeight, words)))
    }
}
