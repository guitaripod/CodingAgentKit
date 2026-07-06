public struct ModelSelection: Sendable, Hashable {
    public var providerID: String
    public var modelID: String

    public init(providerID: String, modelID: String) {
        self.providerID = providerID
        self.modelID = modelID
    }
}

public struct SendPrompt: Sendable {
    public var text: String
    public var model: ModelSelection?
    public var agent: String?

    public init(text: String, model: ModelSelection? = nil, agent: String? = nil) {
        self.text = text
        self.model = model
        self.agent = agent
    }
}

public struct ModelInfo: Identifiable, Sendable, Hashable {
    public let id: String
    public var name: String
    public var providerID: String

    public init(id: String, name: String, providerID: String) {
        self.id = id
        self.name = name
        self.providerID = providerID
    }
}

public struct Provider: Identifiable, Sendable, Hashable {
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
