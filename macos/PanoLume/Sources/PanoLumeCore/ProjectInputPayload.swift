import Foundation

/// An injectable byte reader; format parsing remains independent of storage containers.
public typealias ProjectInputDecoder = @Sendable (Data) throws -> ProjectInputPayload

public struct ProjectInputPayload: Sendable {
    public let data: Data
    public let container: String

    public init(data: Data, container: String) {
        self.data = data
        self.container = container
    }

    public static func plaintext(_ data: Data) throws -> ProjectInputPayload {
        guard !data.contains(0), (try? JSONSerialization.jsonObject(with: data)) != nil else {
            throw PTSImportError.invalidContainer("Only plaintext JSON projects are supported by this reader.")
        }
        return ProjectInputPayload(data: data, container: "plaintext")
    }

    public static func read(_ data: Data) throws -> ProjectInputPayload {
        #if PANOLUME_PRIVATE_EXTENSIONS
        return try PrivateProjectInputDecoder.decode(data)
        #else
        return try plaintext(data)
        #endif
    }
}
