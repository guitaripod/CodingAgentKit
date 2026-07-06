import Foundation

public struct ModelSelection: Sendable, Hashable, Codable {
    public var providerID: String
    public var modelID: String

    public init(providerID: String, modelID: String) {
        self.providerID = providerID
        self.modelID = modelID
    }

    /// Parses a `providerID/modelID` string; returns nil if either side is empty.
    public init?(string: String) {
        guard let slash = string.firstIndex(of: "/") else { return nil }
        let provider = String(string[..<slash])
        let model = String(string[string.index(after: slash)...])
        guard !provider.isEmpty, !model.isEmpty else { return nil }
        self.init(providerID: provider, modelID: model)
    }

    public var rawValue: String { "\(providerID)/\(modelID)" }
}

public struct PromptAttachment: Sendable, Hashable, Codable {
    public var mime: String
    public var filename: String?
    public var data: Data?
    public var url: String?

    public init(mime: String, filename: String? = nil, data: Data? = nil, url: String? = nil) {
        self.mime = mime
        self.filename = filename
        self.data = data
        self.url = url
    }
}

public struct SendPrompt: Sendable {
    public var text: String
    public var model: ModelSelection?
    public var agent: String?
    public var attachments: [PromptAttachment]

    public init(
        text: String,
        model: ModelSelection? = nil,
        agent: String? = nil,
        attachments: [PromptAttachment] = []
    ) {
        self.text = text
        self.model = model
        self.agent = agent
        self.attachments = attachments
    }
}

public struct ModelInfo: Identifiable, Sendable, Hashable, Codable {
    public let id: String
    public var name: String
    public var providerID: String

    public init(id: String, name: String, providerID: String) {
        self.id = id
        self.name = name
        self.providerID = providerID
    }

    public var selection: ModelSelection { ModelSelection(providerID: providerID, modelID: id) }
}

public struct Provider: Identifiable, Sendable, Hashable, Codable {
    public let id: String
    public var name: String
    public var models: [ModelInfo]
    public var defaultModelID: String?

    public init(id: String, name: String, models: [ModelInfo], defaultModelID: String? = nil) {
        self.id = id
        self.name = name
        self.models = models
        self.defaultModelID = defaultModelID
    }
}
