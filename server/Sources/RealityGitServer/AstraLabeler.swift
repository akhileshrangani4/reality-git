import CoreImage
import Foundation
import ImageIO
import RealityGitCore

/// Semantic-only reference labeling. Never supplies geometry or identity confirmation.
enum AstraLabeler {
    typealias Provider = @Sendable (FrameRequest) async throws -> String
    enum Failure: Error { case unavailable, invalidImage, invalidResponse }

    static func label(_ reference: FrameRequest) async throws -> String {
        let jpeg = try crop(reference)
        let schema: [String: Any] = ["type": "object", "properties": ["label": ["type": "string"]],
                                     "required": ["label"], "additionalProperties": false]
        let body: [String: Any] = [
            "model": "gpt-6-astra", "store": false, "reasoning": ["effort": "low"],
            "max_output_tokens": 512,
            "input": [["role": "user", "content": [
                ["type": "input_text", "text": "Name the selected physical object in this cropped camera image with a short plain noun phrase (maximum 60 characters). The image may be sideways. If unclear, say unknown object. Do not identify people or infer sensitive traits. Describe appearance only; this is not identity verification."],
                ["type": "input_image", "image_url": "data:image/jpeg;base64," + jpeg.base64EncodedString(), "detail": "low"]
            ]]],
            "text": ["format": ["type": "json_schema", "name": "selected_object_label", "strict": true, "schema": schema]]
        ]
        return try parse(await send(body))
    }

    struct Comparison: Sendable, Equatable {
        enum Verdict: String, Sendable { case same, different, uncertain }
        let verdict: Verdict
        let confidence: Double
        var authorizes: Bool { verdict == .same && confidence.isFinite && confidence >= 0.85 && confidence <= 1 }
    }
    typealias Comparator = @Sendable (FrameRequest, FrameRequest) async throws -> Comparison

    static func compare(_ reference: FrameRequest, _ candidate: FrameRequest) async throws -> Comparison {
        let images = try [crop(reference), crop(candidate)]
        let schema: [String: Any] = ["type": "object", "properties": [
            "verdict": ["type": "string", "enum": ["same", "different", "uncertain"]],
            "confidence": ["type": "number", "minimum": 0, "maximum": 1]
        ], "required": ["verdict", "confidence"], "additionalProperties": false]
        var content: [[String: Any]] = [["type": "input_text", "text": "Compare image 1 (original selected physical object) with image 2 (candidate). Decide whether they show the SAME individual physical object, not merely the same category. Use distinctive visible details. If lookalikes are indistinguishable, crops are partial or unclear, or evidence is insufficient, return uncertain. Images may be sideways. Do not identify people or infer sensitive traits. Return only verdict same/different/uncertain and confidence from 0 to 1. Never return geometry."]]
        content += images.map { ["type": "input_image", "image_url": "data:image/jpeg;base64," + $0.base64EncodedString(), "detail": "low"] }
        let body: [String: Any] = ["model": "gpt-6-astra", "store": false, "reasoning": ["effort": "low"],
            "max_output_tokens": 512, "input": [["role": "user", "content": content]],
            "text": ["format": ["type": "json_schema", "name": "object_comparison", "strict": true, "schema": schema]]]
        return try parseComparison(await send(body))
    }

    private static func send(_ body: [String: Any]) async throws -> Data {
        guard let key = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !key.isEmpty else { throw Failure.unavailable }
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else { throw Failure.unavailable }
        return data
    }

    static func parseComparison(_ data: Data) throws -> Comparison {
        let result = try outputObject(data)
        guard Set(result.keys) == ["verdict", "confidence"],
              let verdictText = result["verdict"] as? String, let verdict = Comparison.Verdict(rawValue: verdictText),
              let number = result["confidence"] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, (0...1).contains(number.doubleValue) else { throw Failure.invalidResponse }
        return Comparison(verdict: verdict, confidence: number.doubleValue)
    }

    static func parse(_ data: Data) throws -> String {
        let result = try outputObject(data)
        guard Set(result.keys) == ["label"], let label = result["label"] as? String else { throw Failure.invalidResponse }
        let clean = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 60, !clean.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw Failure.invalidResponse
        }
        return clean
    }

    private static func outputObject(_ data: Data) throws -> [String: Any] {
        guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              response["status"] as? String == "completed",
              let output = response["output"] as? [[String: Any]] else { throw Failure.invalidResponse }
        let content = output.flatMap { $0["content"] as? [[String: Any]] ?? [] }
        let texts = content.filter { $0["type"] as? String == "output_text" }
        guard !content.contains(where: { $0["type"] as? String == "refusal" }), texts.count == 1,
              let text = texts.first?["text"] as? String, let encoded = text.data(using: .utf8),
              let result = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else { throw Failure.invalidResponse }
        return result
    }

    static func crop(_ reference: FrameRequest) throws -> Data {
        guard let seed = reference.seedRect, seed.count == 4,
              let image = CIImage(data: reference.jpeg) else { throw Failure.invalidImage }
        let extent = image.extent
        // Wire coordinates are top-left native pixels; Core Image is bottom-left.
        let bounds = CGRect(x: extent.minX + seed[0] * extent.width,
                            y: extent.minY + (1 - seed[1] - seed[3]) * extent.height,
                            width: seed[2] * extent.width, height: seed[3] * extent.height).integral.intersection(extent)
        guard !bounds.isEmpty else { throw Failure.invalidImage }
        let cropped = image.cropped(to: bounds)
        let scale = min(1, 512 / max(bounds.width, bounds.height))
        let resized = cropped.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext(options: [.cacheIntermediates: false])
        guard let cg = context.createCGImage(resized, from: resized.extent) else { throw Failure.invalidImage }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { throw Failure.invalidImage }
        CGImageDestinationAddImage(destination, cg, [kCGImagePropertyOrientation: 1, kCGImageDestinationLossyCompressionQuality: 0.75] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw Failure.invalidImage }
        return data as Data
    }
}
