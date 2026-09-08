import CoreImage
import Foundation
import ImageIO
import RealityGitCore

/// Semantic-only reference labeling. Never supplies geometry or identity confirmation.
enum AstraLabeler {
    typealias Provider = @Sendable (FrameRequest) async throws -> String
    enum Failure: Error { case unavailable, invalidImage, invalidResponse }

    static func label(_ reference: FrameRequest) async throws -> String {
        guard let key = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !key.isEmpty else {
            throw Failure.unavailable
        }
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
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw Failure.unavailable
        }
        return try parse(data)
    }

    static func parse(_ data: Data) throws -> String {
        guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              response["status"] as? String == "completed",
              let output = response["output"] as? [[String: Any]] else { throw Failure.invalidResponse }
        let content = output.flatMap { $0["content"] as? [[String: Any]] ?? [] }
        guard !content.contains(where: { $0["type"] as? String == "refusal" }),
              let text = content.first(where: { $0["type"] as? String == "output_text" })?["text"] as? String,
              let encoded = text.data(using: .utf8),
              let result = try JSONSerialization.jsonObject(with: encoded) as? [String: Any],
              let label = result["label"] as? String else { throw Failure.invalidResponse }
        let clean = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 60, !clean.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw Failure.invalidResponse
        }
        return clean
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
