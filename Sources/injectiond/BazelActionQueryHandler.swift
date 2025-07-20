//
//  BazelActionQueryHandler.swift
//  InjectionIII
//
//  Created by Karim Alweheshy on 20/07/2025.
//  Copyright © 2025 John Holdsworth. All rights reserved.
//
//  $Id: //depot/HotReloading/Sources/injectiond/BazelActionQueryHandler.swift#1 $
//
//  Primary handler for extracting Swift compilation commands using bazel aquery.
//  Orchestrates target discovery, action querying, and command reconstruction.
//

import Foundation

/// Errors that can occur during action query operations
public enum BazelActionQueryError: Error, LocalizedError {
    case targetNotFound(String)
    case actionNotFound(String, String) // target, mnemonic
    case invalidActionGraph(String)
    case commandExtractionFailed(String)
    case aqueryExecutionFailed(String)
    case sourceFileNotInAction(String)
    case bazelExecutableMissing
    
    public var errorDescription: String? {
        switch self {
        case .targetNotFound(let file):
            return "No Bazel target found containing source file: \(file)"
        case .actionNotFound(let target, let mnemonic):
            return "No \(mnemonic) action found for target: \(target)"
        case .invalidActionGraph(let message):
            return "Invalid action graph data: \(message)"
        case .commandExtractionFailed(let message):
            return "Failed to extract compilation command: \(message)"
        case .aqueryExecutionFailed(let message):
            return "Bazel aquery execution failed: \(message)"
        case .sourceFileNotInAction(let file):
            return "Source file not found in any compilation action: \(file)"
        case .bazelExecutableMissing:
            return "Bazel executable not found or not accessible"
        }
    }
}

/// Strategy for target discovery when multiple targets contain the same source file
public enum TargetSelectionStrategy {
    case first              // Use the first target found
    case mostSpecific       // Use the target with the most specific package path
    case primaryTarget      // Use targets marked as primary (e.g., not test targets)
    case interactive        // Prompt user for selection (not implemented yet)
}

/// Main handler for Bazel action query operations
public class BazelActionQueryHandler {
    private let workspaceRoot: URL
    private let bazelExecutable: String
    private let pathResolver: BazelPathResolver
    private let swiftCommandBuilder: SwiftCommandBuilder
    private let actionGraphParser: ActionGraphParser
    private let cache: AQueryCache
    
    /// Target selection strategy for ambiguous cases
    public var targetSelectionStrategy: TargetSelectionStrategy = .mostSpecific
    
    /// Enable/disable caching
    public var isCachingEnabled: Bool = true
    
    /// Debug logging function
    private let debug: (Any...) -> Void
    
    public init(
        workspaceRoot: URL,
        pathResolver: BazelPathResolver,
        bazelExecutable: String = "bazel",
        debug: @escaping (Any...) -> Void = { _ in }
    ) {
        self.workspaceRoot = workspaceRoot
        self.bazelExecutable = bazelExecutable
        self.pathResolver = pathResolver
        self.swiftCommandBuilder = SwiftCommandBuilder(workspaceRoot: workspaceRoot, debug: debug)
        self.actionGraphParser = ActionGraphParser(debug: debug)
        self.cache = AQueryCache(workspaceRoot: workspaceRoot, debug: debug)
        self.debug = debug
    }
    
    /// Primary method: Get Swift compilation command for a source file
    public func getSwiftCompilationCommand(for sourceFile: String) async throws -> CompilationCommand {
        debug("Getting Swift compilation command for:", sourceFile)
        
        // Step 1: Find target containing the Swift file
        let target = try await findTargetContainingFile(sourceFile)
        debug("Found target for \(sourceFile):", target)
        
        // Step 2: Check cache first if enabled
        if isCachingEnabled {
            if let cachedCommand = await cache.getCachedCompilationCommand(for: sourceFile, target: target) {
                debug("Using cached compilation command for \(sourceFile)")
                return cachedCommand
            }
        }
        
        // Step 3: Query SwiftCompile actions for that target
        let actionGraph = try await querySwiftCompileActions(for: target)
        debug("Retrieved action graph with \(actionGraph.actions.count) actions")
        
        // Step 4: Extract and reconstruct the compilation command
        let command = try await swiftCommandBuilder.extractCompilationCommand(
            for: sourceFile,
            from: actionGraph
        )
        
        // Step 5: Cache the result if enabled
        if isCachingEnabled {
            await cache.cacheCompilationCommand(command, for: sourceFile, target: target)
        }
        
        debug("Successfully extracted compilation command for \(sourceFile)")
        return command
    }
    
    /// Find the Bazel target that contains the given source file
    public func findTargetContainingFile(_ sourceFile: String) async throws -> String {
        debug("Finding target containing file:", sourceFile)
        
        // Strategy 1: Try direct label conversion
        do {
            if let label = try? pathResolver.convertToLabel(sourceFile) {
                if try await verifyTargetExists(label) {
                    debug("Found target via direct label conversion:", label)
                    return label
                }
            }
        } catch {
            debug("Direct label conversion failed:", error)
        }
        
        // Strategy 2: Query for targets containing this file
        let targets = try await queryTargetsContainingFile(sourceFile)
        
        guard !targets.isEmpty else {
            throw BazelActionQueryError.targetNotFound(sourceFile)
        }
        
        // Strategy 3: Select the best target based on strategy
        let selectedTarget = selectBestTarget(targets, for: sourceFile)
        debug("Selected target:", selectedTarget)
        
        return selectedTarget
    }
    
    /// Query for SwiftCompile actions for a specific target
    public func querySwiftCompileActions(for target: String) async throws -> ActionGraphContainer {
        debug("Querying SwiftCompile actions for target:", target)
        
        // Build the aquery command
        let query = "mnemonic(\"SwiftCompile\", \(target))"
        
        // Check cache first if enabled
        if isCachingEnabled {
            if let cachedActionGraph = await cache.getCachedActionGraph(for: target, query: query) {
                debug("Using cached action graph for target: \(target)")
                return cachedActionGraph
            }
        }
        
        // Execute aquery
        let data = try await executeAQuery(query, includeCommandLine: true, includeArtifacts: true)
        
        // Parse the action graph
        let actionGraph = try actionGraphParser.parseActionGraph(from: data)
        
        // Verify we got SwiftCompile actions
        let swiftActions = actionGraphParser.findSwiftCompileActions(in: actionGraph)
        if swiftActions.isEmpty {
            throw BazelActionQueryError.actionNotFound(target, "SwiftCompile")
        }
        
        // Cache the result if enabled
        if isCachingEnabled {
            await cache.cacheActionGraph(actionGraph, for: target, query: query)
        }
        
        return actionGraph
    }
    
    // MARK: - Private Implementation
    
    /// Query for targets that contain a specific source file
    private func queryTargetsContainingFile(_ sourceFile: String) async throws -> [String] {
        let relativePath = pathResolver.getRelativePath(sourceFile)
        let fileName = URL(fileURLWithPath: relativePath).lastPathComponent
        
        // Try multiple query strategies
        let queries = [
            // Exact path match
            "attr(srcs, '\(relativePath)', //...)",
            // Filename match
            "attr(srcs, '.*\(fileName)', //...)",
            // Package-based search
            "//\(try pathResolver.findPackage(for: sourceFile)):*"
        ]
        
        var allTargets: Set<String> = []
        
        for query in queries {
            do {
                let result = try await runBazelQuery(query)
                let targets = result.split(separator: "\n")
                    .map(String.init)
                    .filter { !$0.isEmpty }
                
                allTargets.formUnion(targets)
                
                if !targets.isEmpty {
                    debug("Query '\(query)' found \(targets.count) targets")
                }
            } catch {
                debug("Query failed:", query, error)
                // Continue with other queries
            }
        }
        
        return Array(allTargets)
    }
    
    /// Select the best target from a list of candidates
    private func selectBestTarget(_ targets: [String], for sourceFile: String) -> String {
        guard !targets.isEmpty else {
            fatalError("Cannot select from empty target list")
        }
        
        if targets.count == 1 {
            return targets[0]
        }
        
        switch targetSelectionStrategy {
        case .first:
            return targets[0]
            
        case .mostSpecific:
            // Select the target with the longest package path (most specific)
            return targets.max { target1, target2 in
                let package1 = extractPackage(from: target1)
                let package2 = extractPackage(from: target2)
                return package1.count < package2.count
            } ?? targets[0]
            
        case .primaryTarget:
            // Prefer non-test targets
            let nonTestTargets = targets.filter { !$0.contains("test") && !$0.contains("Test") }
            if !nonTestTargets.isEmpty {
                return selectBestTarget(nonTestTargets, for: sourceFile)
            }
            return targets[0]
            
        case .interactive:
            // TODO: Implement interactive selection
            debug("Interactive selection not implemented, using most specific")
            return selectBestTarget(targets, for: sourceFile)
        }
    }
    
    /// Extract package path from a target label
    private func extractPackage(from target: String) -> String {
        // //path/to/package:target -> path/to/package
        if let colonIndex = target.firstIndex(of: ":") {
            let packagePart = String(target[..<colonIndex])
            if packagePart.hasPrefix("//") {
                return String(packagePart.dropFirst(2))
            }
            return packagePart
        }
        return target
    }
    
    /// Execute a bazel aquery command
    private func executeAQuery(
        _ query: String,
        includeCommandLine: Bool = true,
        includeArtifacts: Bool = true
    ) async throws -> Data {
        var arguments = ["aquery", query, "--output=jsonproto"]
        
        if includeCommandLine {
            arguments.append("--include_commandline")
        }
        
        if includeArtifacts {
            arguments.append("--include_artifacts")
        }
        
        debug("Executing bazel aquery:", arguments.joined(separator: " "))
        
        return try await runBazelCommand(arguments)
    }
    
    /// Execute a bazel query command
    private func runBazelQuery(_ query: String) async throws -> String {
        let arguments = ["query", query]
        let data = try await runBazelCommand(arguments)
        
        guard let result = String(data: data, encoding: .utf8) else {
            throw BazelActionQueryError.aqueryExecutionFailed("Failed to decode query output")
        }
        
        return result
    }
    
    /// Verify that a target exists
    private func verifyTargetExists(_ target: String) async throws -> Bool {
        do {
            let result = try await runBazelQuery("'\(target)'")
            return !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } catch {
            return false
        }
    }
    
    /// Run a bazel command and return the output data
    private func runBazelCommand(_ arguments: [String]) async throws -> Data {
        // Verify bazel executable exists
        guard FileManager.default.fileExists(atPath: bazelExecutable) || 
              isExecutableInPath(bazelExecutable) else {
            throw BazelActionQueryError.bazelExecutableMissing
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.launchPath = self.bazelExecutable
                process.arguments = arguments
                process.currentDirectoryPath = self.workspaceRoot.path
                
                let outputPipe = Pipe()
                let errorPipe = Pipe()
                process.standardOutput = outputPipe
                process.standardError = errorPipe
                
                do {
                    process.launch()
                    process.waitUntilExit()
                    
                    let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                    
                    if process.terminationStatus != 0 {
                        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                        let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
                        
                        self.debug("Bazel command failed with exit code \(process.terminationStatus):", errorMessage)
                        continuation.resume(throwing: BazelActionQueryError.aqueryExecutionFailed(errorMessage))
                        return
                    }
                    
                    continuation.resume(returning: outputData)
                } catch {
                    continuation.resume(throwing: BazelActionQueryError.aqueryExecutionFailed(error.localizedDescription))
                }
            }
        }
    }
    
    /// Check if an executable exists in PATH
    private func isExecutableInPath(_ executable: String) -> Bool {
        let process = Process()
        process.launchPath = "/usr/bin/which"
        process.arguments = [executable]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        
        process.launch()
        process.waitUntilExit()
        
        return process.terminationStatus == 0
    }
}

// MARK: - Public Convenience Methods

extension BazelActionQueryHandler {
    
    /// Get compilation command with caching support
    public func getCachedCompilationCommand(for sourceFile: String) async throws -> CompilationCommand {
        return try await getSwiftCompilationCommand(for: sourceFile)
    }
    
    /// Batch get compilation commands for multiple source files
    public func getCompilationCommands(for sourceFiles: [String]) async throws -> [String: CompilationCommand] {
        var results: [String: CompilationCommand] = [:]
        
        // Process files sequentially to avoid overwhelming Bazel
        for sourceFile in sourceFiles {
            do {
                let command = try await getSwiftCompilationCommand(for: sourceFile)
                results[sourceFile] = command
            } catch {
                debug("Failed to get compilation command for \(sourceFile):", error)
                // Continue with other files
            }
        }
        
        return results
    }
    
    /// Validate the current Bazel workspace and executable
    public func validateSetup() async throws {
        // Check bazel executable
        guard FileManager.default.fileExists(atPath: bazelExecutable) || 
              isExecutableInPath(bazelExecutable) else {
            throw BazelActionQueryError.bazelExecutableMissing
        }
        
        // Try a simple bazel command
        _ = try await runBazelCommand(["version"])
        
        debug("Bazel setup validation passed")
    }
    
    /// Get information about available Swift targets in the workspace
    public func discoverSwiftTargets() async throws -> [String] {
        debug("Discovering Swift targets in workspace")
        
        let query = "kind(\"swift_.*\", //...)"
        let result = try await runBazelQuery(query)
        
        let targets = result.split(separator: "\n")
            .map(String.init)
            .filter { !$0.isEmpty }
        
        debug("Found \(targets.count) Swift targets")
        return targets
    }
    
    // MARK: - Cache Management
    
    /// Clear all cached data
    public func clearCache() async {
        await cache.clearAll()
        debug("Cleared all cached data")
    }
    
    /// Clear cache for a specific target
    public func clearCacheForTarget(_ target: String) async {
        await cache.clearTarget(target)
        debug("Cleared cache for target: \(target)")
    }
    
    /// Clear cache for a specific source file
    public func clearCacheForSourceFile(_ sourceFile: String) async {
        await cache.clearSourceFile(sourceFile)
        debug("Cleared cache for source file: \(sourceFile)")
    }
    
    /// Get cache statistics
    public func getCacheStats() async -> AQueryCache.CacheStats {
        return await cache.getStats()
    }
    
    /// Invalidate cache when workspace changes
    public func invalidateCacheOnWorkspaceChange() async {
        await cache.invalidateOnWorkspaceChange()
        debug("Invalidated cache due to workspace changes")
    }
    
    /// Enable or disable caching
    public func setCachingEnabled(_ enabled: Bool) {
        isCachingEnabled = enabled
        debug("Caching \(enabled ? "enabled" : "disabled")")
    }
}