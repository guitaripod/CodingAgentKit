import Foundation

/// What the operating system of the machine a server runs on lets its agents touch.
///
/// A Mac asks a person before a process reads their Documents, Desktop, Downloads, another app's
/// data or a network volume, and it asks on the Mac's own screen. A server is a daemon nobody is
/// watching, so a grant that was never given is a turn that stalls behind a dialog across the room
/// or fails the read outright. The server reads its own grants without ever raising a prompt; a
/// client shows them and can ask the server to open the right pane on the machine, but the switch
/// is always the person's to flip.
public struct MachinePermissions: Sendable, Hashable, Codable {
    public enum Platform: String, Sendable, Hashable, Codable {
        case macOS = "macos"
        case linux
    }

    public struct Grant: Sendable, Hashable, Codable, Identifiable {
        public enum Kind: String, Sendable, Hashable, Codable {
            case fullDiskAccess
        }

        public enum State: String, Sendable, Hashable, Codable {
            case granted
            case missing
        }

        public var id: String
        public var state: State

        public var kind: Kind? { Kind(rawValue: id) }

        public init(id: String, state: State) {
            self.id = id
            self.state = state
        }

        public init(_ kind: Kind, state: State) {
            self.init(id: kind.rawValue, state: state)
        }
    }

    public var platform: Platform?
    /// The machine's own name, for "System Settings is open on …".
    public var host: String?
    /// The server's binary, which is what the person drags into the list.
    public var executable: String?
    public var grants: [Grant]
    /// When a client last asked the machine to open a grant's pane, from any device.
    public var requestedAt: Date?

    public init(
        platform: Platform?, host: String? = nil, executable: String? = nil, grants: [Grant],
        requestedAt: Date? = nil
    ) {
        self.platform = platform
        self.host = host
        self.executable = executable
        self.grants = grants
        self.requestedAt = requestedAt
    }

    /// The grants this client knows how to explain, in the order they are shown.
    public var known: [Grant] { grants.filter { $0.kind != nil } }

    public var missing: [Grant] { known.filter { $0.state == .missing } }

    public var isComplete: Bool { missing.isEmpty }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        platform = try? container.decodeIfPresent(Platform.self, forKey: .platform)
        host = try container.decodeIfPresent(String.self, forKey: .host)
        executable = try container.decodeIfPresent(String.self, forKey: .executable)
        grants = (try? container.decodeIfPresent([LenientGrant].self, forKey: .grants))?
            .compactMap(\.grant) ?? []
        requestedAt = try container.decodeIfPresent(Date.self, forKey: .requestedAt)
    }

    /// A grant state this build has never heard of is dropped rather than failing the whole
    /// answer, so a newer server can add states without silencing every older client.
    private struct LenientGrant: Decodable {
        let grant: Grant?

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: Grant.CodingKeys.self)
            guard let id = try? container.decode(String.self, forKey: .id),
                let state = try? container.decode(Grant.State.self, forKey: .state)
            else {
                grant = nil
                return
            }
            grant = Grant(id: id, state: state)
        }
    }
}

extension MachinePermissions.Grant {
    fileprivate enum CodingKeys: String, CodingKey {
        case id, state
    }
}

/// A backend whose server can report the operating-system grants its agents run under, and open
/// the pane that gives one. Every method returns nil for a server too old for the routes, which is
/// *cannot say* and is shown as nothing rather than as an error.
public protocol PermissionReportingBackend: CodingAgentBackend {
    func machinePermissions() async throws -> MachinePermissions?
    /// Opens the grant's pane on the server's own screen and returns the status as it stands.
    func requestMachinePermission(_ kind: MachinePermissions.Grant.Kind) async throws
        -> MachinePermissions?
}
