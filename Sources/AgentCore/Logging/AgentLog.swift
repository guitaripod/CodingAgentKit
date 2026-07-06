import Logging

public enum AgentLog {
    public static func logger(_ category: String) -> Logger {
        Logger(label: "codingagentkit.\(category)")
    }
}
