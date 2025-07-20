//
//  SwiftCommandBuilder.swift
//  InjectionIII
//
//  Created by Karim Alweheshy on 20/07/2025.
//  Copyright © 2025 John Holdsworth. All rights reserved.
//
//  $Id: //depot/HotReloading/Sources/injectiond/SwiftCommandBuilder.swift#1 $
//
//  Extracts and reconstructs Swift compilation commands from Bazel action graph data.
//  Converts Bazel's internal SwiftCompile actions into executable compilation commands.
//

import Foundation

/// Errors that can occur during Swift command building
public enum SwiftCommandError: Error, LocalizedError {
    case noSwiftCompileActions
    case sourceFileNotFound(String)
    case invalidCompilerPath(String)
    case missingRequiredArguments(String)
    case pathNormalizationFailed(String)
    case environmentResolutionFailed(String)
    
    public var errorDescription: String? {
        switch self {
        case .noSwiftCompileActions:
            return "No SwiftCompile actions found in action graph"
        case .sourceFileNotFound(let file):
            return "Source file not found in any SwiftCompile action: \(file)"
        case .invalidCompilerPath(let path):
            return "Invalid compiler path: \(path)"
        case .missingRequiredArguments(let description):
            return "Missing required Swift compiler arguments: \(description)"
        case .pathNormalizationFailed(let path):
            return "Failed to normalize Bazel path: \(path)"
        case .environmentResolutionFailed(let variable):
            return "Failed to resolve environment variable: \(variable)"
        }
    }
}

/// Builds executable Swift compilation commands from Bazel action graph data
public class SwiftCommandBuilder {
    private let workspaceRoot: URL
    private let actionGraphParser: ActionGraphParser
    private let pathNormalizer: BazelPathNormalizer
    
    /// Debug logging function
    private let debug: (Any...) -> Void
    
    public init(workspaceRoot: URL, debug: @escaping (Any...) -> Void = { _ in }) {
        self.workspaceRoot = workspaceRoot
        self.actionGraphParser = ActionGraphParser(debug: debug)
        self.pathNormalizer = BazelPathNormalizer(workspaceRoot: workspaceRoot, debug: debug)
        self.debug = debug
    }
    
    /// Extract compilation command for a specific source file from action graph
    public func extractCompilationCommand(
        for sourceFile: String,
        from actionGraph: ActionGraphContainer
    ) async throws -> CompilationCommand {
        // Find all SwiftCompile actions
        let swiftActions = actionGraphParser.findSwiftCompileActions(in: actionGraph)
        
        guard !swiftActions.isEmpty else {
            throw SwiftCommandError.noSwiftCompileActions
        }
        
        debug("Found \(swiftActions.count) SwiftCompile actions, searching for source file: \(sourceFile)")
        
        // Find the action that compiles our source file
        guard let targetAction = findActionForSourceFile(sourceFile, in: swiftActions, actionGraph: actionGraph) else {
            throw SwiftCommandError.sourceFileNotFound(sourceFile)
        }
        
        debug("Found SwiftCompile action for \(sourceFile)")
        
        // Build the compilation command
        return try await buildCompilationCommand(from: targetAction, sourceFile: sourceFile, actionGraph: actionGraph)
    }
    
    /// Find the SwiftCompile action that handles the specific source file
    private func findActionForSourceFile(
        _ sourceFile: String,
        in actions: [Action],
        actionGraph: ActionGraphContainer
    ) -> Action? {
        let relativePath = makeRelativePath(sourceFile)
        
        for action in actions {
            // Check if the source file is mentioned in the arguments
            if action.arguments.contains(where: { arg in
                arg.contains(relativePath) || arg.contains(sourceFile)
            }) {
                debug("Found action with source file in arguments")
                return action
            }
            
            // Check input artifacts
            let (inputs, _) = actionGraphParser.getActionArtifacts(for: action, in: actionGraph)
            for artifact in inputs {
                if let execPath = artifact.execPath,
                   (execPath.contains(relativePath) || execPath.contains(sourceFile)) {
                    debug("Found action with source file in input artifacts: \(execPath)")
                    return action
                }
            }
        }
        
        return nil
    }
    
    /// Build a compilation command from a SwiftCompile action
    private func buildCompilationCommand(
        from action: Action,
        sourceFile: String,
        actionGraph: ActionGraphContainer
    ) async throws -> CompilationCommand {
        // Extract compiler from arguments
        let compiler = try extractCompiler(from: action.arguments)
        
        // Extract and process arguments
        let processedArguments = try await processSwiftArguments(
            action.arguments,
            sourceFile: sourceFile
        )
        
        // Get artifacts
        let (inputs, outputs) = actionGraphParser.getActionArtifacts(for: action, in: actionGraph)
        
        // Process environment variables
        let environmentVariables = processEnvironmentVariables(action.environmentVariables ?? [])
        
        // Get additional context
        let targetLabel = actionGraphParser.getTargetLabel(for: action, in: actionGraph)
        let workingDirectory = extractWorkingDirectory(from: action, actionGraph: actionGraph)
        
        let command = CompilationCommand(
            compiler: compiler,
            arguments: processedArguments,
            environmentVariables: environmentVariables,
            outputFiles: outputs.compactMap { $0.execPath },
            inputFiles: inputs.compactMap { $0.execPath },
            sourceFile: sourceFile,
            workingDirectory: workingDirectory,
            targetLabel: targetLabel,
            actionKey: action.actionKey,
            configurationId: action.configurationId
        )
        
        debug("Built compilation command with \(processedArguments.count) arguments")
        return command
    }
    
    /// Extract the Swift compiler path from action arguments
    private func extractCompiler(from arguments: [String]) throws -> String {
        // The first argument is typically the compiler
        guard let firstArg = arguments.first else {
            throw SwiftCommandError.missingRequiredArguments("No arguments found")
        }
        
        // Handle different compiler invocation patterns
        if firstArg.contains("swiftc") || firstArg.contains("swift") {
            return firstArg
        }
        
        // Look for compiler in subsequent arguments
        for arg in arguments {
            if arg.contains("swiftc") || arg.hasSuffix("swift") {
                return arg
            }
        }
        
        throw SwiftCommandError.invalidCompilerPath(firstArg)
    }
    
    /// Process Swift compiler arguments
    private func processSwiftArguments(
        _ arguments: [String],
        sourceFile: String
    ) async throws -> [String] {
        var processedArgs: [String] = []
        var i = 0
        
        while i < arguments.count {
            let arg = arguments[i]
            
            // Skip the compiler itself (first argument)
            if i == 0 {
                i += 1
                continue
            }
            
            // Process different argument types
            if arg.hasPrefix("-") {
                // Compiler flag
                processedArgs.append(arg)
                
                // Check if this flag takes a value
                if needsValue(flag: arg) && i + 1 < arguments.count {
                    i += 1
                    let value = arguments[i]
                    // Process the value (might need path normalization)
                    processedArgs.append(try await processArgumentValue(value))
                }
            } else {
                // Non-flag argument (likely a file path)
                processedArgs.append(try await processArgumentValue(arg))
            }
            
            i += 1
        }
        
        return processedArgs
    }
    
    /// Check if a compiler flag needs a value
    private func needsValue(flag: String) -> Bool {
        let flagsNeedingValues: Set<String> = [
            "-o", "-emit-module-path", "-emit-objc-header-path",
            "-emit-dependencies-path", "-emit-reference-dependencies-path",
            "-serialize-diagnostics-path", "-target", "-sdk",
            "-module-name", "-import-objc-header", "-I", "-F",
            "-L", "-working-directory"
        ]
        
        return flagsNeedingValues.contains(flag)
    }
    
    /// Process argument values (handle path normalization)
    private func processArgumentValue(_ value: String) async throws -> String {
        // Check if this looks like a path that needs normalization
        if BazelPathNormalizer.isBazelExecutionPath(value) {
            return try await pathNormalizer.normalizePath(value)
        }
        
        // If it contains path separators and might be a file path, try normalization
        if value.contains("/") && !value.hasPrefix("-") {
            // Check if the file exists as a Bazel path
            do {
                return try await pathNormalizer.normalizePath(value)
            } catch {
                // If normalization fails, return original value
                debug("Path normalization failed for \(value), using original:", error)
                return value
            }
        }
        
        // For other values (flags, simple names), return as-is
        return value
    }
    
    /// Process environment variables from action
    private func processEnvironmentVariables(_ envVars: [EnvironmentVariable]) -> [String: String] {
        var result: [String: String] = [:]
        
        for envVar in envVars {
            result[envVar.name] = envVar.value
        }
        
        return result
    }
    
    /// Extract working directory from action context
    private func extractWorkingDirectory(from action: Action, actionGraph: ActionGraphContainer) -> String? {
        // Check execution info for working directory
        if let workingDir = action.executionInfo?["working-directory"] {
            return workingDir
        }
        
        // Check environment variables
        if let envVars = action.environmentVariables {
            for envVar in envVars {
                if envVar.name == "PWD" || envVar.name == "BUILD_WORKING_DIRECTORY" {
                    return envVar.value
                }
            }
        }
        
        // Default to workspace root
        return workspaceRoot.path
    }
    
    /// Make a file path relative to workspace root
    private func makeRelativePath(_ filePath: String) -> String {
        let normalizedPath = URL(fileURLWithPath: filePath).standardized.path
        let workspacePath = workspaceRoot.standardized.path
        
        if normalizedPath.hasPrefix(workspacePath + "/") {
            return String(normalizedPath.dropFirst(workspacePath.count + 1))
        } else if normalizedPath == workspacePath {
            return ""
        } else {
            return normalizedPath
        }
    }
}

/// Extended functionality for command validation and modification
extension SwiftCommandBuilder {
    
    /// Validate that a compilation command is executable
    public func validateCompilationCommand(_ command: CompilationCommand) throws {
        // Check that compiler exists
        guard FileManager.default.fileExists(atPath: command.compiler) else {
            throw SwiftCommandError.invalidCompilerPath(command.compiler)
        }
        
        // Check that source file exists
        guard FileManager.default.fileExists(atPath: command.sourceFile) else {
            throw SwiftCommandError.sourceFileNotFound(command.sourceFile)
        }
        
        // Validate that we have essential Swift compiler arguments
        let hasOutput = command.arguments.contains { $0 == "-o" }
        let hasModuleName = command.arguments.contains { $0 == "-module-name" }
        
        if !hasOutput {
            debug("Warning: No output file specified in compilation command")
        }
        
        if !hasModuleName {
            debug("Warning: No module name specified in compilation command")
        }
    }
    
    /// Modify compilation command for hot reload (e.g., change output path)
    public func modifyForHotReload(
        _ command: CompilationCommand,
        outputPath: String
    ) -> CompilationCommand {
        var modifiedArguments = command.arguments
        
        // Find and replace output path
        if let outputIndex = modifiedArguments.firstIndex(of: "-o"),
           outputIndex + 1 < modifiedArguments.count {
            modifiedArguments[outputIndex + 1] = outputPath
        } else {
            // Add output specification if not present
            modifiedArguments.append(contentsOf: ["-o", outputPath])
        }
        
        // Ensure we're building a dynamic library for injection
        if !modifiedArguments.contains("-emit-library") {
            modifiedArguments.append("-emit-library")
        }
        
        // Add hot reload specific flags
        let hotReloadFlags = [
            "-Xfrontend", "-enable-dynamic-replacement-chaining",
            "-Xfrontend", "-enable-implicit-dynamic"
        ]
        
        for flag in hotReloadFlags {
            if !modifiedArguments.contains(flag) {
                modifiedArguments.append(flag)
            }
        }
        
        return CompilationCommand(
            compiler: command.compiler,
            arguments: modifiedArguments,
            environmentVariables: command.environmentVariables,
            outputFiles: [outputPath],
            inputFiles: command.inputFiles,
            sourceFile: command.sourceFile,
            workingDirectory: command.workingDirectory,
            targetLabel: command.targetLabel,
            actionKey: command.actionKey,
            configurationId: command.configurationId
        )
    }
    
    /// Extract Swift module name from compilation command
    public func extractModuleName(from command: CompilationCommand) -> String? {
        guard let moduleIndex = command.arguments.firstIndex(of: "-module-name"),
              moduleIndex + 1 < command.arguments.count else {
            return nil
        }
        
        return command.arguments[moduleIndex + 1]
    }
    
    /// Extract target information from compilation command
    public func extractTargetInfo(from command: CompilationCommand) -> (target: String?, sdk: String?) {
        var target: String?
        var sdk: String?
        
        if let targetIndex = command.arguments.firstIndex(of: "-target"),
           targetIndex + 1 < command.arguments.count {
            target = command.arguments[targetIndex + 1]
        }
        
        if let sdkIndex = command.arguments.firstIndex(of: "-sdk"),
           sdkIndex + 1 < command.arguments.count {
            sdk = command.arguments[sdkIndex + 1]
        }
        
        return (target: target, sdk: sdk)
    }
}