import Foundation

/// The version of the conversation between a client and a preview host. A client that needs a
/// newer one than the host reports says so in words instead of guessing from a 404.
public enum PreviewProto {
    public static let current = 1
}

/// How previewd encodes and reads every JSON body, so a host and a client cannot disagree on dates.
public enum PreviewJSON {
    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    public static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

public struct PreviewStatus: Codable, Sendable, Equatable {
    public var proto: Int
    public var version: String
    public var host: HostFacts
    public var xcode: XcodeFacts?
    public var runtimes: [RuntimeFact]
    public var streaming: StreamingFacts
    public var access: String?

    public init(
        proto: Int = PreviewProto.current, version: String, host: HostFacts, xcode: XcodeFacts?,
        runtimes: [RuntimeFact], streaming: StreamingFacts, access: String? = nil
    ) {
        self.proto = proto
        self.version = version
        self.host = host
        self.xcode = xcode
        self.runtimes = runtimes
        self.streaming = streaming
        self.access = access
    }
}

public struct HostFacts: Codable, Sendable, Equatable {
    public var name: String
    public var os: String
    public var arch: String

    public init(name: String, os: String, arch: String) {
        self.name = name
        self.os = os
        self.arch = arch
    }
}

public struct XcodeFacts: Codable, Sendable, Equatable {
    public var version: String
    public var build: String
    public var path: String

    public init(version: String, build: String, path: String) {
        self.version = version
        self.build = build
        self.path = path
    }
}

public struct RuntimeFact: Codable, Sendable, Equatable {
    public var identifier: String
    public var name: String
    public var platform: String
    public var version: String
    public var available: Bool
    public var deviceTypes: [DeviceTypeFact]

    public init(
        identifier: String, name: String, platform: String, version: String, available: Bool,
        deviceTypes: [DeviceTypeFact]
    ) {
        self.identifier = identifier
        self.name = name
        self.platform = platform
        self.version = version
        self.available = available
        self.deviceTypes = deviceTypes
    }
}

public struct DeviceTypeFact: Codable, Sendable, Equatable {
    public var identifier: String
    public var name: String

    public init(identifier: String, name: String) {
        self.identifier = identifier
        self.name = name
    }
}

/// What the host can stream and at what ceiling, stated rather than implied: the simulator draws
/// at most 60 pictures a second, and touch is only offered when a touch transport is installed.
public struct StreamingFacts: Codable, Sendable, Equatable {
    public var encodings: [String]
    public var maximumFramesPerSecond: Int
    public var touch: Bool
    public var tool: String?

    public init(encodings: [String], maximumFramesPerSecond: Int, touch: Bool, tool: String?) {
        self.encodings = encodings
        self.maximumFramesPerSecond = maximumFramesPerSecond
        self.touch = touch
        self.tool = tool
    }
}

/// One line of the checklist the app draws while it sets a Mac up. The host proves each one; the
/// client only draws the state.
public struct DoctorCheck: Codable, Sendable, Equatable, Identifiable {
    public enum State: String, Codable, Sendable {
        case ok
        case working
        case fixable
        case needsYou
        case failed
    }

    public var id: String
    public var title: String
    public var state: State
    public var detail: String?
    public var fix: String?

    public init(id: String, title: String, state: State, detail: String? = nil, fix: String? = nil) {
        self.id = id
        self.title = title
        self.state = state
        self.detail = detail
        self.fix = fix
    }
}

public struct FixJob: Codable, Sendable, Equatable, Identifiable {
    public enum State: String, Codable, Sendable {
        case running
        case done
        case failed
    }

    public var id: String
    public var check: String
    public var state: State
    public var message: String?
    public var fraction: Double?

    public init(id: String, check: String, state: State, message: String? = nil, fraction: Double? = nil) {
        self.id = id
        self.check = check
        self.state = state
        self.message = message
        self.fraction = fraction
    }
}

public struct ProjectFound: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case workspace
        case project
        case generated
    }

    public var path: String
    public var kind: Kind
    public var name: String
    public var schemes: [String]

    public init(path: String, kind: Kind, name: String, schemes: [String]) {
        self.path = path
        self.kind = kind
        self.name = name
        self.schemes = schemes
    }
}

public struct ProjectRef: Codable, Sendable, Equatable {
    public var path: String
    public var scheme: String?

    public init(path: String, scheme: String? = nil) {
        self.path = path
        self.scheme = scheme
    }
}

public struct SessionRequest: Codable, Sendable, Equatable {
    public var project: ProjectRef
    public var deviceType: String
    public var runtime: String?
    public var appearance: String?
    public var contentSize: String?
    public var launchArguments: [String]
    public var environment: [String: String]
    public var watch: Bool

    public init(
        project: ProjectRef, deviceType: String, runtime: String? = nil, appearance: String? = nil,
        contentSize: String? = nil, launchArguments: [String] = [], environment: [String: String] = [:],
        watch: Bool = true
    ) {
        self.project = project
        self.deviceType = deviceType
        self.runtime = runtime
        self.appearance = appearance
        self.contentSize = contentSize
        self.launchArguments = launchArguments
        self.environment = environment
        self.watch = watch
    }
}

public enum SessionState: String, Codable, Sendable {
    case preparing
    case building
    case installing
    case launching
    case live
    case failed
    case stopped
}

public struct DeviceInfo: Codable, Sendable, Equatable {
    public var udid: String
    public var name: String
    public var deviceType: String
    public var runtime: String

    public init(udid: String, name: String, deviceType: String, runtime: String) {
        self.udid = udid
        self.name = name
        self.deviceType = deviceType
        self.runtime = runtime
    }
}

public struct AppInfo: Codable, Sendable, Equatable {
    public var name: String
    public var bundleID: String

    public init(name: String, bundleID: String) {
        self.name = name
        self.bundleID = bundleID
    }
}

public struct FrameInfo: Codable, Sendable, Equatable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

public struct BuildIssue: Codable, Sendable, Equatable {
    public enum Severity: String, Codable, Sendable {
        case error
        case warning
    }

    public var severity: Severity
    public var message: String
    public var file: String?
    public var line: Int?
    public var column: Int?

    public init(severity: Severity, message: String, file: String? = nil, line: Int? = nil, column: Int? = nil) {
        self.severity = severity
        self.message = message
        self.file = file
        self.line = line
        self.column = column
    }
}

/// Which way a change reached the picture. The quickest one that worked is the one reported, so a
/// slow update always has a reason a person can read.
public enum ReloadPath: String, Codable, Sendable {
    case first
    case injected
    case rebuilt
    case scratch
}

public struct BuildReport: Codable, Sendable, Equatable {
    public var ok: Bool
    public var path: ReloadPath
    public var trigger: String
    public var seconds: Double
    public var finishedAt: Date
    public var issues: [BuildIssue]

    public init(
        ok: Bool, path: ReloadPath, trigger: String, seconds: Double, finishedAt: Date, issues: [BuildIssue]
    ) {
        self.ok = ok
        self.path = path
        self.trigger = trigger
        self.seconds = seconds
        self.finishedAt = finishedAt
        self.issues = issues
    }
}

public struct SessionInfo: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var state: SessionState
    public var step: String?
    public var device: DeviceInfo
    public var app: AppInfo?
    public var project: ProjectRef
    public var lastBuild: BuildReport?
    public var frame: FrameInfo?
    public var startedAt: Date
    public var restarts: Int

    public init(
        id: String, state: SessionState, step: String?, device: DeviceInfo, app: AppInfo?, project: ProjectRef,
        lastBuild: BuildReport?, frame: FrameInfo?, startedAt: Date, restarts: Int
    ) {
        self.id = id
        self.state = state
        self.step = step
        self.device = device
        self.app = app
        self.project = project
        self.lastBuild = lastBuild
        self.frame = frame
        self.startedAt = startedAt
        self.restarts = restarts
    }
}

/// One thing that happened to a session, in words a client may show: a build starting, a build
/// that landed, the app crashing and being put back on the same screen.
public struct SessionEvent: Codable, Sendable, Equatable {
    public var seq: Int
    public var at: Date
    public var kind: String
    public var message: String?
    public var state: SessionState?
    public var build: BuildReport?

    public init(
        seq: Int, at: Date, kind: String, message: String? = nil, state: SessionState? = nil,
        build: BuildReport? = nil
    ) {
        self.seq = seq
        self.at = at
        self.kind = kind
        self.message = message
        self.state = state
        self.build = build
    }
}
