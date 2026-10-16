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
    public var accessLogin: String?

    public init(
        proto: Int = PreviewProto.current, version: String, host: HostFacts, xcode: XcodeFacts?,
        runtimes: [RuntimeFact], streaming: StreamingFacts, access: String? = nil, accessLogin: String? = nil
    ) {
        self.proto = proto
        self.version = version
        self.host = host
        self.xcode = xcode
        self.runtimes = runtimes
        self.streaming = streaming
        self.access = access
        self.accessLogin = accessLogin
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
    public var hotReload: Bool

    public init(encodings: [String], maximumFramesPerSecond: Int, touch: Bool, tool: String?, hotReload: Bool = false) {
        self.encodings = encodings
        self.maximumFramesPerSecond = maximumFramesPerSecond
        self.touch = touch
        self.tool = tool
        self.hotReload = hotReload
    }

    enum CodingKeys: String, CodingKey {
        case encodings, maximumFramesPerSecond, touch, tool, hotReload
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        encodings = try values.decode([String].self, forKey: .encodings)
        maximumFramesPerSecond = try values.decode(Int.self, forKey: .maximumFramesPerSecond)
        touch = try values.decode(Bool.self, forKey: .touch)
        tool = try values.decodeIfPresent(String.self, forKey: .tool)
        hotReload = try values.decodeIfPresent(Bool.self, forKey: .hotReload) ?? false
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
    public var optional: Bool?

    public init(
        id: String, title: String, state: State, detail: String? = nil, fix: String? = nil, optional: Bool? = nil
    ) {
        self.id = id
        self.title = title
        self.state = state
        self.detail = detail
        self.fix = fix
        self.optional = optional
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

/// One remembered picture of a session: the screen as it stood once a change had landed, with the
/// words and the road that explain why it was kept.
public struct HistoryInfo: Codable, Sendable, Equatable, Identifiable {
    public var id: Int
    public var at: Date
    public var title: String
    public var path: ReloadPath?
    public var trigger: String
    public var bytes: Int

    public init(id: Int, at: Date, title: String, path: ReloadPath?, trigger: String, bytes: Int) {
        self.id = id
        self.at = at
        self.title = title
        self.path = path
        self.trigger = trigger
        self.bytes = bytes
    }
}

/// A rectangle of the screen that differs between two pictures, in the pixels of the picture.
public struct DiffRegion: Codable, Sendable, Equatable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int
    public var changed: Double

    public init(x: Int, y: Int, width: Int, height: Int, changed: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.changed = changed
    }
}

public struct DiffReport: Codable, Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var changed: Double
    public var regions: [DiffRegion]
    public var sameSize: Bool

    public init(width: Int, height: Int, changed: Double, regions: [DiffRegion], sameSize: Bool) {
        self.width = width
        self.height = height
        self.changed = changed
        self.regions = regions
        self.sameSize = sameSize
    }
}

/// One way to look at the same screen: a name, and whatever it changes about the device or the
/// launch. Anything left out stays as the session had it, and `arguments` are given to the app
/// after the ones the session started it with rather than instead of them, so a variant that asks
/// for another language is still on the screen the session was showing.
public struct VariantSpec: Codable, Sendable, Equatable {
    public var label: String
    public var appearance: String?
    public var contentSize: String?
    public var arguments: [String]?

    public init(label: String, appearance: String? = nil, contentSize: String? = nil, arguments: [String]? = nil) {
        self.label = label
        self.appearance = appearance
        self.contentSize = contentSize
        self.arguments = arguments
    }
}

public struct VariantsRequest: Codable, Sendable, Equatable {
    public var variants: [VariantSpec]
    public var settle: Double?

    public init(variants: [VariantSpec], settle: Double? = nil) {
        self.variants = variants
        self.settle = settle
    }
}

public struct VariantResult: Codable, Sendable, Equatable {
    public var label: String
    public var ok: Bool
    public var bytes: Int
    public var error: String?

    public init(label: String, ok: Bool, bytes: Int, error: String? = nil) {
        self.label = label
        self.ok = ok
        self.bytes = bytes
        self.error = error
    }
}

/// A run of variants as the host reports it while it works and after: how far it is, and what each
/// variant came to.
public struct VariantJob: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable {
        case running
        case done
        case failed
    }

    public var job: String?
    public var state: State
    public var done: Int
    public var total: Int
    public var results: [VariantResult]
    public var message: String?

    public init(
        job: String? = nil, state: State, done: Int, total: Int, results: [VariantResult], message: String? = nil
    ) {
        self.job = job
        self.state = state
        self.done = done
        self.total = total
        self.results = results
        self.message = message
    }
}

/// One touch a person or an agent makes on the picture. Positions are fractions of the picture,
/// from its top-left corner, so the host can turn them into points on whatever screen it has
/// without the client knowing which device that is.
public struct TouchRequest: Codable, Sendable, Equatable {
    public enum Action: String, Codable, Sendable {
        case tap
        case swipe
        case text
        case key
        case button
    }

    public var action: Action
    public var x: Double?
    public var y: Double?
    public var toX: Double?
    public var toY: Double?
    public var seconds: Double?
    public var text: String?
    public var key: String?
    public var button: String?

    public init(
        action: Action, x: Double? = nil, y: Double? = nil, toX: Double? = nil, toY: Double? = nil,
        seconds: Double? = nil, text: String? = nil, key: String? = nil, button: String? = nil
    ) {
        self.action = action
        self.x = x
        self.y = y
        self.toX = toX
        self.toY = toY
        self.seconds = seconds
        self.text = text
        self.key = key
        self.button = button
    }

    public static func tap(x: Double, y: Double) -> TouchRequest {
        TouchRequest(action: .tap, x: x, y: y)
    }

    public static func swipe(x: Double, y: Double, toX: Double, toY: Double, seconds: Double = 0.3) -> TouchRequest {
        TouchRequest(action: .swipe, x: x, y: y, toX: toX, toY: toY, seconds: seconds)
    }

    public static func text(_ text: String) -> TouchRequest {
        TouchRequest(action: .text, text: text)
    }

    public static func key(_ key: String) -> TouchRequest {
        TouchRequest(action: .key, key: key)
    }

    public static func button(_ button: String) -> TouchRequest {
        TouchRequest(action: .button, button: button)
    }
}
