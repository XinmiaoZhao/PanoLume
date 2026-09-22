import Foundation

public enum RuntimeEnvironment {
    public static func normalized(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        #if PANOLUME_PRIVATE_EXTENSIONS
        return applyPrivateEnvironmentAliases(environment)
        #else
        return environment
        #endif
    }
}
