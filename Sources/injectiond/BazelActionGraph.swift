//
//  BazelActionGraph.swift
//  InjectionIII
//
//  Created by Karim Alweheshy on 20/07/2025.
//  Copyright © 2025 John Holdsworth. All rights reserved.
//
//  $Id: //depot/HotReloading/Sources/injectiond/BazelActionGraph.swift#1 $
//
//  Data structures for parsing Bazel aquery JSON proto output.
//  Based on analysis.ActionGraphContainer protobuf schema.
//

import Foundation

/// Errors that can occur during action graph parsing
public enum ActionGraphError: Error, LocalizedError {
    case invalidJSON(String)
    case missingRequiredField(String)
    case actionNotFound(String)
    case artifactNotFound(String)
    case invalidActionStructure(String)
    
    public var errorDescription: String? {
        switch self {
        case .invalidJSON(let message):
            return "Invalid JSON in action graph: \(message)"
        case .missingRequiredField(let field):
            return "Missing required field in action graph: \(field)"
        case .actionNotFound(let actionId):
            return "Action not found: \(actionId)"
        case .artifactNotFound(let artifactId):
            return "Artifact not found: \(artifactId)"
        case .invalidActionStructure(let message):
            return "Invalid action structure: \(message)"
        }
    }
}

/// Top-level container for Bazel action graph data (analysis.ActionGraphContainer)
public struct ActionGraphContainer: Codable {
    public let actions: [Action]
    public let artifacts: [Artifact]
    public let targets: [Target]
    public let depSetOfFiles: [DepSetOfFiles]
    public let configuration: [Configuration]
    public let aspectDescriptors: [AspectDescriptor]?
    public let ruleClassDescriptors: [RuleClassDescriptor]?
    
    enum CodingKeys: String, CodingKey {
        case actions
        case artifacts
        case targets
        case depSetOfFiles = "depSetOfFiles"
        case configuration
        case aspectDescriptors = "aspectDescriptors"
        case ruleClassDescriptors = "ruleClassDescriptors"
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        self.actions = try container.decodeIfPresent([Action].self, forKey: .actions) ?? []
        self.artifacts = try container.decodeIfPresent([Artifact].self, forKey: .artifacts) ?? []
        self.targets = try container.decodeIfPresent([Target].self, forKey: .targets) ?? []
        self.depSetOfFiles = try container.decodeIfPresent([DepSetOfFiles].self, forKey: .depSetOfFiles) ?? []
        self.configuration = try container.decodeIfPresent([Configuration].self, forKey: .configuration) ?? []
        self.aspectDescriptors = try container.decodeIfPresent([AspectDescriptor].self, forKey: .aspectDescriptors)
        self.ruleClassDescriptors = try container.decodeIfPresent([RuleClassDescriptor].self, forKey: .ruleClassDescriptors)
    }
}

/// Represents a Bazel build action
public struct Action: Codable {
    public let targetId: String?
    public let actionKey: String?
    public let mnemonic: String
    public let configurationId: String?
    public let arguments: [String]
    public let inputDepSetIds: [String]
    public let outputIds: [String]
    public let discoversInputs: Bool?
    public let executionInfo: [String: String]?
    public let environmentVariables: [EnvironmentVariable]?
    public let executionPlatform: String?
    public let templateContent: String?
    public let substitutions: [KeyValuePair]?
    public let fileContents: String?
    public let undeclaredOutputs: Bool?
    
    enum CodingKeys: String, CodingKey {
        case targetId
        case actionKey
        case mnemonic
        case configurationId
        case arguments
        case inputDepSetIds
        case outputIds
        case discoversInputs
        case executionInfo
        case environmentVariables
        case executionPlatform
        case templateContent
        case substitutions
        case fileContents
        case undeclaredOutputs
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        self.targetId = try container.decodeIfPresent(String.self, forKey: .targetId)
        self.actionKey = try container.decodeIfPresent(String.self, forKey: .actionKey)
        self.mnemonic = try container.decode(String.self, forKey: .mnemonic)
        self.configurationId = try container.decodeIfPresent(String.self, forKey: .configurationId)
        self.arguments = try container.decodeIfPresent([String].self, forKey: .arguments) ?? []
        self.inputDepSetIds = try container.decodeIfPresent([String].self, forKey: .inputDepSetIds) ?? []
        self.outputIds = try container.decodeIfPresent([String].self, forKey: .outputIds) ?? []
        self.discoversInputs = try container.decodeIfPresent(Bool.self, forKey: .discoversInputs)
        self.executionInfo = try container.decodeIfPresent([String: String].self, forKey: .executionInfo)
        self.environmentVariables = try container.decodeIfPresent([EnvironmentVariable].self, forKey: .environmentVariables)
        self.executionPlatform = try container.decodeIfPresent(String.self, forKey: .executionPlatform)
        self.templateContent = try container.decodeIfPresent(String.self, forKey: .templateContent)
        self.substitutions = try container.decodeIfPresent([KeyValuePair].self, forKey: .substitutions)
        self.fileContents = try container.decodeIfPresent(String.self, forKey: .fileContents)
        self.undeclaredOutputs = try container.decodeIfPresent(Bool.self, forKey: .undeclaredOutputs)
    }
}

/// Environment variable in an action
public struct EnvironmentVariable: Codable {
    public let name: String
    public let value: String
    
    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

/// Key-value pair for substitutions
public struct KeyValuePair: Codable {
    public let key: String
    public let value: String
    
    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

/// Represents a build artifact (input or output file)
public struct Artifact: Codable {
    public let id: String
    public let execPath: String?
    public let isTreeArtifact: Bool?
    public let isMiddlemanArtifact: Bool?
    
    enum CodingKeys: String, CodingKey {
        case id
        case execPath
        case isTreeArtifact
        case isMiddlemanArtifact
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        self.id = try container.decode(String.self, forKey: .id)
        self.execPath = try container.decodeIfPresent(String.self, forKey: .execPath)
        self.isTreeArtifact = try container.decodeIfPresent(Bool.self, forKey: .isTreeArtifact)
        self.isMiddlemanArtifact = try container.decodeIfPresent(Bool.self, forKey: .isMiddlemanArtifact)
    }
}

/// Represents a build target
public struct Target: Codable {
    public let id: String
    public let label: String?
    public let ruleClassId: String?
    
    public init(id: String, label: String?, ruleClassId: String?) {
        self.id = id
        self.label = label
        self.ruleClassId = ruleClassId
    }
}

/// Represents a set of files (dependency set)
public struct DepSetOfFiles: Codable {
    public let id: String
    public let directArtifactIds: [String]
    public let transitiveDepSetIds: [String]
    
    enum CodingKeys: String, CodingKey {
        case id
        case directArtifactIds
        case transitiveDepSetIds
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        self.id = try container.decode(String.self, forKey: .id)
        self.directArtifactIds = try container.decodeIfPresent([String].self, forKey: .directArtifactIds) ?? []
        self.transitiveDepSetIds = try container.decodeIfPresent([String].self, forKey: .transitiveDepSetIds) ?? []
    }
}

/// Build configuration information
public struct Configuration: Codable {
    public let id: String
    public let mnemonic: String?
    public let platformName: String?
    public let cpu: String?
    public let makeVariables: [KeyValuePair]?
    
    enum CodingKeys: String, CodingKey {
        case id
        case mnemonic
        case platformName
        case cpu
        case makeVariables
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        self.id = try container.decode(String.self, forKey: .id)
        self.mnemonic = try container.decodeIfPresent(String.self, forKey: .mnemonic)
        self.platformName = try container.decodeIfPresent(String.self, forKey: .platformName)
        self.cpu = try container.decodeIfPresent(String.self, forKey: .cpu)
        self.makeVariables = try container.decodeIfPresent([KeyValuePair].self, forKey: .makeVariables)
    }
}

/// Aspect descriptor
public struct AspectDescriptor: Codable {
    public let id: String
    public let name: String?
    
    public init(id: String, name: String?) {
        self.id = id
        self.name = name
    }
}

/// Rule class descriptor
public struct RuleClassDescriptor: Codable {
    public let id: String
    public let name: String?
    
    public init(id: String, name: String?) {
        self.id = id
        self.name = name
    }
}

/// Enhanced compilation command with action graph context
public struct CompilationCommand: Codable {
    public let compiler: String
    public let arguments: [String]
    public let environmentVariables: [String: String]
    public let outputFiles: [String]
    public let inputFiles: [String]
    public let sourceFile: String
    public let workingDirectory: String?
    public let targetLabel: String?
    public let actionKey: String?
    public let configurationId: String?
    
    /// Full command line for debugging
    public var fullCommand: String {
        let envPrefix = environmentVariables.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        let command = ([compiler] + arguments).joined(separator: " ")
        return envPrefix.isEmpty ? command : "\(envPrefix) \(command)"
    }
    
    public init(
        compiler: String,
        arguments: [String],
        environmentVariables: [String: String] = [:],
        outputFiles: [String] = [],
        inputFiles: [String] = [],
        sourceFile: String,
        workingDirectory: String? = nil,
        targetLabel: String? = nil,
        actionKey: String? = nil,
        configurationId: String? = nil
    ) {
        self.compiler = compiler
        self.arguments = arguments
        self.environmentVariables = environmentVariables
        self.outputFiles = outputFiles
        self.inputFiles = inputFiles
        self.sourceFile = sourceFile
        self.workingDirectory = workingDirectory
        self.targetLabel = targetLabel
        self.actionKey = actionKey
        self.configurationId = configurationId
    }
}

/// Parser for Bazel action graph JSON data
public class ActionGraphParser {
    /// Debug logging function
    private let debug: (Any...) -> Void
    
    public init(debug: @escaping (Any...) -> Void = { _ in }) {
        self.debug = debug
    }
    
    /// Parse action graph JSON data
    public func parseActionGraph(from data: Data) throws -> ActionGraphContainer {
        do {
            let decoder = JSONDecoder()
            let actionGraph = try decoder.decode(ActionGraphContainer.self, from: data)
            
            debug("Parsed action graph with \(actionGraph.actions.count) actions, \(actionGraph.artifacts.count) artifacts")
            return actionGraph
            
        } catch let decodingError as DecodingError {
            debug("JSON decoding error:", decodingError)
            throw ActionGraphError.invalidJSON(decodingError.localizedDescription)
        } catch {
            debug("Unexpected parsing error:", error)
            throw ActionGraphError.invalidJSON(error.localizedDescription)
        }
    }
    
    /// Find SwiftCompile actions in the action graph
    public func findSwiftCompileActions(in actionGraph: ActionGraphContainer) -> [Action] {
        let swiftActions = actionGraph.actions.filter { $0.mnemonic == "SwiftCompile" }
        debug("Found \(swiftActions.count) SwiftCompile actions")
        return swiftActions
    }
    
    /// Find action by action key
    public func findAction(by actionKey: String, in actionGraph: ActionGraphContainer) -> Action? {
        return actionGraph.actions.first { $0.actionKey == actionKey }
    }
    
    /// Find artifact by ID
    public func findArtifact(by id: String, in actionGraph: ActionGraphContainer) -> Artifact? {
        return actionGraph.artifacts.first { $0.id == id }
    }
    
    /// Get artifacts for an action (inputs and outputs)
    public func getActionArtifacts(for action: Action, in actionGraph: ActionGraphContainer) -> (inputs: [Artifact], outputs: [Artifact]) {
        let outputArtifacts = action.outputIds.compactMap { outputId in
            findArtifact(by: outputId, in: actionGraph)
        }
        
        // Get input artifacts from dep sets
        var inputArtifacts: [Artifact] = []
        for depSetId in action.inputDepSetIds {
            if let depSet = actionGraph.depSetOfFiles.first(where: { $0.id == depSetId }) {
                let artifacts = depSet.directArtifactIds.compactMap { artifactId in
                    findArtifact(by: artifactId, in: actionGraph)
                }
                inputArtifacts.append(contentsOf: artifacts)
            }
        }
        
        return (inputs: inputArtifacts, outputs: outputArtifacts)
    }
    
    /// Get target label for an action
    public func getTargetLabel(for action: Action, in actionGraph: ActionGraphContainer) -> String? {
        guard let targetId = action.targetId else { return nil }
        return actionGraph.targets.first { $0.id == targetId }?.label
    }
    
    /// Get configuration for an action
    public func getConfiguration(for action: Action, in actionGraph: ActionGraphContainer) -> Configuration? {
        guard let configId = action.configurationId else { return nil }
        return actionGraph.configuration.first { $0.id == configId }
    }
}