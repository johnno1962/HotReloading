//
//  BazelBuildEventParser.swift
//  InjectionIII
//
//  Created by Karim Alweheshy on 18/07/2025.
//  Copyright © 2025 John Holdsworth. All rights reserved.
//
//  $Id: //depot/HotReloading/Sources/injectiond/BazelBuildEventParser.swift#1 $
//
//  Bazel Build Event Protocol parser for hot reloading integration.
//  Parses BEP JSON stream to extract Swift compilation commands.
//

import Foundation

/// Represents a compilation command extracted from BEP
public struct CompilationCommand {
    public let compiler: String
    public let arguments: [String]
    public let outputFiles: [String]
    public let sourceFile: String?
    
    public var fullCommand: String {
        return ([compiler] + arguments).joined(separator: " ")
    }
    
    public init(compiler: String, arguments: [String], outputFiles: [String], sourceFile: String?) {
        self.compiler = compiler
        self.arguments = arguments
        self.outputFiles = outputFiles
        self.sourceFile = sourceFile
    }
}

/// Represents a Bazel target involved in the build
public struct BazelTarget {
    public let label: String
    public let configuration: String
    public let outputFiles: [String]
    
    public init(label: String, configuration: String, outputFiles: [String]) {
        self.label = label
        self.configuration = configuration
        self.outputFiles = outputFiles
    }
}

/// Bazel Build Event Protocol structures
public struct BazelBuildEvent: Codable {
    public struct Id: Codable {
        public var targetCompleted: TargetCompleted?
        public var actionExecuted: ActionExecuted?
        public var namedSetOfFiles: NamedSetOfFiles?
        
        public struct TargetCompleted: Codable {
            public let label: String
            public let configuration: Configuration?
            
            public struct Configuration: Codable {
                public let mnemonic: String?
                public let platformName: String?
                public let cpu: String?
            }
        }
        
        public struct ActionExecuted: Codable {
            public let label: String?
            public let configuration: Configuration?
            
            public struct Configuration: Codable {
                public let mnemonic: String?
                public let platformName: String?
                public let cpu: String?
            }
        }
        
        public struct NamedSetOfFiles: Codable {
            public let id: String
        }
    }
    
    public struct CompletedTarget: Codable {
        public let success: Bool
        public let outputGroup: [OutputGroup]?
        
        public struct OutputGroup: Codable {
            public let name: String
            public let fileSets: [FileSet]?
            
            public struct FileSet: Codable {
                public let id: String
            }
        }
    }
    
    public struct ExecutedAction: Codable {
        public let success: Bool
        public let commandLine: [String]?
        public let outputFiles: [String]?
        public let mnemonic: String?
        public let stdout: String?
        public let stderr: String?
    }
    
    public struct FileSet: Codable {
        public let files: [File]?
        
        public struct File: Codable {
            public let name: String
            public let path: String
            public let pathFragment: [String]?
        }
    }
    
    public var id: Id?
    public var completed: CompletedTarget?
    public var action: ExecutedAction?
    public var namedSetOfFiles: FileSet?
}

/// Parser for Bazel Build Event Protocol streams
public class BazelBuildEventParser {
    private var buildEvents: [BazelBuildEvent] = []
    private var fileMapping: [String: BazelTarget] = [:]
    private var targetOutputs: [String: [String]] = [:]
    private var namedFileSets: [String: [String]] = [:]
    
    /// Debug logging function
    private let debug: (Any...) -> Void
    
    public init(debug: @escaping (Any...) -> Void = { _ in }) {
        self.debug = debug
    }
    
    /// Parse a BEP stream from a file URL
    public func parseBEPStream(from url: URL) throws -> [CompilationCommand] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw NSError(domain: "BazelBuildEventParser", code: 1, 
                         userInfo: [NSLocalizedDescriptionKey: "BEP file not found: \(url.path)"])
        }
        
        debug("Parsing BEP stream from:", url.path)
        
        let data = try Data(contentsOf: url)
        let content = String(data: data, encoding: .utf8) ?? ""
        let lines = content.split(separator: "\n")
        
        var commands: [CompilationCommand] = []
        
        for (index, line) in lines.enumerated() {
            let lineStr = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !lineStr.isEmpty else { continue }
            
            do {
                guard let eventData = lineStr.data(using: .utf8) else {
                    debug("Failed to convert line to data:", lineStr.prefix(100))
                    continue
                }
                
                let event = try JSONDecoder().decode(BazelBuildEvent.self, from: eventData)
                buildEvents.append(event)
                
                // Process different event types
                if let action = event.action {
                    if let command = parseSwiftCompilationCommand(from: action) {
                        debug("Found Swift compilation command:", command.fullCommand.prefix(200))
                        commands.append(command)
                    }
                }
                
                if let namedSetOfFiles = event.namedSetOfFiles {
                    processNamedFileSet(namedSetOfFiles, id: event.id?.namedSetOfFiles?.id)
                }
                
                if let completed = event.completed {
                    processCompletedTarget(completed, targetId: event.id?.targetCompleted?.label)
                }
                
            } catch {
                debug("Failed to parse BEP event at line \(index + 1):", error.localizedDescription)
                debug("Line content:", lineStr.prefix(200))
                // Continue parsing other lines
            }
        }
        
        debug("Parsed \(commands.count) Swift compilation commands from \(lines.count) BEP events")
        return commands
    }
    
    /// Extract Swift compilation command from an executed action
    private func parseSwiftCompilationCommand(from action: BazelBuildEvent.ExecutedAction) -> CompilationCommand? {
        guard let commandLine = action.commandLine,
              !commandLine.isEmpty,
              action.success else {
            return nil
        }
        
        // Look for Swift compiler invocations
        let swiftcIndex = commandLine.firstIndex { arg in
            arg.contains("swiftc") || arg.hasSuffix("swift-frontend")
        }
        
        guard let compilerIndex = swiftcIndex else {
            // Check for wrapper scripts that might invoke Swift
            if commandLine.contains(where: { $0.contains("swift") && $0.contains("wrapper") }) {
                return parseWrappedSwiftCommand(from: action)
            }
            return nil
        }
        
        let compiler = commandLine[compilerIndex]
        let arguments = Array(commandLine[(compilerIndex + 1)...])
        let outputFiles = action.outputFiles ?? []
        
        // Extract source file from arguments
        let sourceFile = extractSourceFile(from: arguments)
        
        return CompilationCommand(
            compiler: compiler,
            arguments: arguments,
            outputFiles: outputFiles,
            sourceFile: sourceFile
        )
    }
    
    /// Parse wrapped Swift compilation commands (e.g., from custom build rules)
    private func parseWrappedSwiftCommand(from action: BazelBuildEvent.ExecutedAction) -> CompilationCommand? {
        guard let commandLine = action.commandLine,
              let outputFiles = action.outputFiles,
              !outputFiles.isEmpty else {
            return nil
        }
        
        // For wrapped commands, we might need to extract the actual Swift command from stderr/stdout
        let combinedOutput = [action.stdout, action.stderr].compactMap { $0 }.joined(separator: "\n")
        
        // Look for Swift compiler invocations in the output
        let swiftcPattern = try? NSRegularExpression(pattern: "swiftc\\s+.*", options: [])
        if let match = swiftcPattern?.firstMatch(in: combinedOutput, options: [], 
                                                range: NSRange(location: 0, length: combinedOutput.count)) {
            let swiftCommand = String(combinedOutput[Range(match.range, in: combinedOutput)!])
            let components = swiftCommand.split(separator: " ").map(String.init)
            
            if components.count > 1 {
                let compiler = components[0]
                let arguments = Array(components[1...])
                let sourceFile = extractSourceFile(from: arguments)
                
                return CompilationCommand(
                    compiler: compiler,
                    arguments: arguments,
                    outputFiles: outputFiles,
                    sourceFile: sourceFile
                )
            }
        }
        
        return nil
    }
    
    /// Extract source file path from Swift compiler arguments
    private func extractSourceFile(from arguments: [String]) -> String? {
        // Look for source files in various Swift compiler argument patterns
        for (index, arg) in arguments.enumerated() {
            if arg == "-primary-file" || arg == "-c" {
                // Next argument should be the source file
                if index + 1 < arguments.count {
                    let sourceFile = arguments[index + 1]
                    if sourceFile.hasSuffix(".swift") {
                        return sourceFile
                    }
                }
            } else if arg.hasSuffix(".swift") && !arg.starts(with: "-") {
                // Direct source file argument
                return arg
            }
        }
        
        return nil
    }
    
    /// Process named file sets from BEP events
    private func processNamedFileSet(_ fileSet: BazelBuildEvent.FileSet, id: String?) {
        guard let setId = id,
              let files = fileSet.files else {
            return
        }
        
        let filePaths = files.map { $0.path }
        namedFileSets[setId] = filePaths
        debug("Processed named file set \(setId) with \(filePaths.count) files")
    }
    
    /// Process completed target events
    private func processCompletedTarget(_ completed: BazelBuildEvent.CompletedTarget, targetId: String?) {
        guard let targetLabel = targetId,
              completed.success else {
            return
        }
        
        // Collect output files from various output groups
        var outputFiles: [String] = []
        
        if let outputGroups = completed.outputGroup {
            for group in outputGroups {
                if let fileSets = group.fileSets {
                    for fileSet in fileSets {
                        if let files = namedFileSets[fileSet.id] {
                            outputFiles.append(contentsOf: files)
                        }
                    }
                }
            }
        }
        
        targetOutputs[targetLabel] = outputFiles
        debug("Processed completed target \(targetLabel) with \(outputFiles.count) output files")
    }
    
    /// Get output files for a specific target
    public func getOutputFiles(for targetLabel: String) -> [String] {
        return targetOutputs[targetLabel] ?? []
    }
    
    /// Get all processed targets
    public func getAllTargets() -> [String] {
        return Array(targetOutputs.keys)
    }
    
    /// Find compilation command for a specific source file
    public func findCompilationCommand(for sourceFile: String) -> CompilationCommand? {
        return buildEvents.compactMap { event in
            guard let action = event.action else { return nil }
            return parseSwiftCompilationCommand(from: action)
        }.first { command in
            command.sourceFile == sourceFile
        }
    }
    
    /// Clear all cached data
    public func clearCache() {
        buildEvents.removeAll()
        fileMapping.removeAll()
        targetOutputs.removeAll()
        namedFileSets.removeAll()
    }
}

// MARK: - StringProtocol Extension for Range Support
extension StringProtocol {
    subscript(range: NSRange) -> String? {
        return Range(range, in: String(self)).flatMap { String(self[$0]) }
    }
}