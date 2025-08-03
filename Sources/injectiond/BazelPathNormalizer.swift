//
//  BazelPathNormalizer.swift
//  InjectionIII
//
//  Created by Karim Alweheshy on 20/07/2025.
//  Copyright © 2025 John Holdsworth. All rights reserved.
//
//  $Id: //depot/HotReloading/Sources/injectiond/BazelPathNormalizer.swift#1 $
//
//  Normalizes Bazel execution paths to absolute paths usable outside Bazel context.
//  Handles bazel-out/, external/, and other Bazel-specific path formats.
//

import Foundation
import os

/// Errors that can occur during path normalization
public enum PathNormalizationError: Error, LocalizedError {
    case bazelInfoFailed(String)
    case invalidBazelPath(String)
    case executionRootNotFound
    case workspaceNotFound
    case pathResolutionFailed(String)
    
    public var errorDescription: String? {
        switch self {
        case .bazelInfoFailed(let message):
            return "Bazel info command failed: \(message)"
        case .invalidBazelPath(let path):
            return "Invalid Bazel path format: \(path)"
        case .executionRootNotFound:
            return "Could not determine Bazel execution root"
        case .workspaceNotFound:
            return "Could not find Bazel workspace"
        case .pathResolutionFailed(let path):
            return "Failed to resolve path: \(path)"
        }
    }
}

/// Information about Bazel workspace and execution environment
public struct BazelPathInfo {
    public let workspaceRoot: String
    public let executionRoot: String
    public let outputBase: String
    public let outputPath: String
    public let binDir: String
    public let genfilesDir: String
    
    public init(
        workspaceRoot: String,
        executionRoot: String,
        outputBase: String,
        outputPath: String,
        binDir: String,
        genfilesDir: String
    ) {
        self.workspaceRoot = workspaceRoot
        self.executionRoot = executionRoot
        self.outputBase = outputBase
        self.outputPath = outputPath
        self.binDir = binDir
        self.genfilesDir = genfilesDir
    }
}

/// Normalizes Bazel paths to absolute filesystem paths
public class BazelPathNormalizer {
    private let workspaceRoot: URL
    private let bazelExecutable: String
    
    /// Cached Bazel path information
    private var bazelPathInfo: BazelPathInfo?
    private let pathInfoLock = OSAllocatedUnfairLock()
    
    /// Cache for resolved paths
    private var pathCache: [String: String] = [:]
    private let cacheLock = OSAllocatedUnfairLock()
    
    /// Debug logging function
    private let debug: (Any...) -> Void
    
    public init(workspaceRoot: URL, bazelExecutable: String = "bazel", debug: @escaping (Any...) -> Void = { _ in }) {
        self.workspaceRoot = workspaceRoot
        self.bazelExecutable = bazelExecutable
        self.debug = debug
    }
    
    /// Initialize Bazel path information
    public func initializePathInfo() async throws {
        if pathInfoLock.withLock({ bazelPathInfo }) != nil {
            return // Already initialized
        }
        
        debug("Initializing Bazel path information")
        
        let pathInfo = try await gatherBazelPathInfo()
        
        pathInfoLock.withLock {
            self.bazelPathInfo = pathInfo
        }
        
        debug("Bazel path info initialized:", pathInfo.executionRoot)
    }
    
    /// Normalize a single path from Bazel execution format to absolute path
    public func normalizePath(_ path: String) async throws -> String {
        // Check cache first
        if let cachedPath = cacheLock.withLock({ pathCache[path] }) {
            return cachedPath
        }
        
        // Ensure path info is initialized
        try await initializePathInfo()
        
        guard let pathInfo = pathInfoLock.withLock({ bazelPathInfo }) else {
            throw PathNormalizationError.executionRootNotFound
        }
        
        let normalizedPath = try resolvePathWithInfo(path, pathInfo: pathInfo)
        
        // Cache the result
        cacheLock.withLock {
            pathCache[path] = normalizedPath
        }
        
        return normalizedPath
    }
    
    /// Normalize multiple paths efficiently
    public func normalizePaths(_ paths: [String]) async throws -> [String] {
        // Initialize once for batch operation
        try await initializePathInfo()
        
        var normalizedPaths: [String] = []
        
        for path in paths {
            let normalizedPath = try await normalizePath(path)
            normalizedPaths.append(normalizedPath)
        }
        
        return normalizedPaths
    }
    
    /// Normalize all paths in compilation command arguments
    public func normalizeCompilationCommand(_ command: CompilationCommand) async throws -> CompilationCommand {
        debug("Normalizing compilation command paths")
        
        // Normalize compiler path
        let normalizedCompiler = try await normalizePath(command.compiler)
        
        // Normalize arguments
        let normalizedArguments = try await normalizePaths(command.arguments)
        
        // Normalize file paths
        let normalizedOutputFiles = try await normalizePaths(command.outputFiles)
        let normalizedInputFiles = try await normalizePaths(command.inputFiles)
        let normalizedSourceFile = try await normalizePath(command.sourceFile)
        
        // Normalize working directory if present
        let normalizedWorkingDirectory: String?
        if let workingDir = command.workingDirectory {
            normalizedWorkingDirectory = try await normalizePath(workingDir)
        } else {
            normalizedWorkingDirectory = nil
        }
        
        return CompilationCommand(
            compiler: normalizedCompiler,
            arguments: normalizedArguments,
            environmentVariables: command.environmentVariables,
            outputFiles: normalizedOutputFiles,
            inputFiles: normalizedInputFiles,
            sourceFile: normalizedSourceFile,
            workingDirectory: normalizedWorkingDirectory,
            targetLabel: command.targetLabel,
            actionKey: command.actionKey,
            configurationId: command.configurationId
        )
    }
    
    // MARK: - Private Methods
    
    /// Gather Bazel path information using bazel info commands
    private func gatherBazelPathInfo() async throws -> BazelPathInfo {
        let infoCommands = [
            "workspace",
            "execution_root",
            "output_base",
            "output_path",
            "bazel-bin",
            "bazel-genfiles"
        ]
        
        var infoResults: [String: String] = [:]
        
        for command in infoCommands {
            do {
                let result = try await runBazelInfo(command)
                infoResults[command] = result.trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                debug("Failed to get Bazel info for \(command):", error)
                throw PathNormalizationError.bazelInfoFailed("Failed to get \(command): \(error)")
            }
        }
        
        guard let workspace = infoResults["workspace"],
              let executionRoot = infoResults["execution_root"],
              let outputBase = infoResults["output_base"],
              let outputPath = infoResults["output_path"],
              let binDir = infoResults["bazel-bin"],
              let genfilesDir = infoResults["bazel-genfiles"] else {
            throw PathNormalizationError.bazelInfoFailed("Missing required Bazel info")
        }
        
        return BazelPathInfo(
            workspaceRoot: workspace,
            executionRoot: executionRoot,
            outputBase: outputBase,
            outputPath: outputPath,
            binDir: binDir,
            genfilesDir: genfilesDir
        )
    }
    
    /// Run a bazel info command
    private func runBazelInfo(_ infoType: String) async throws -> String {
        let process = Process()
        process.launchPath = bazelExecutable
        process.arguments = ["info", infoType]
        process.currentDirectoryPath = workspaceRoot.path
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    process.launch()
                    process.waitUntilExit()
                    
                    if process.terminationStatus != 0 {
                        continuation.resume(throwing: PathNormalizationError.bazelInfoFailed("Process exit code: \(process.terminationStatus)"))
                        return
                    }
                    
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: data, encoding: .utf8) ?? ""
                    continuation.resume(returning: output)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    /// Resolve a path using gathered Bazel path information
    private func resolvePathWithInfo(_ path: String, pathInfo: BazelPathInfo) throws -> String {
        // If already absolute, return as-is
        if path.hasPrefix("/") {
            return path
        }
        
        // Handle different Bazel path formats
        if path.hasPrefix("bazel-out/") {
            return resolveOutputPath(path, pathInfo: pathInfo)
        } else if path.hasPrefix("external/") {
            return resolveExternalPath(path, pathInfo: pathInfo)
        } else if path.hasPrefix("../") {
            return resolveRelativePath(path, pathInfo: pathInfo)
        } else if path.contains("/") {
            // Workspace-relative path
            return URL(fileURLWithPath: pathInfo.workspaceRoot).appendingPathComponent(path).path
        } else {
            // Simple filename or tool name - check if it exists in execution root
            let executionRootPath = URL(fileURLWithPath: pathInfo.executionRoot).appendingPathComponent(path).path
            if FileManager.default.fileExists(atPath: executionRootPath) {
                return executionRootPath
            }
            
            // Check workspace root
            let workspacePath = URL(fileURLWithPath: pathInfo.workspaceRoot).appendingPathComponent(path).path
            if FileManager.default.fileExists(atPath: workspacePath) {
                return workspacePath
            }
            
            // Return as-is (might be a system tool)
            return path
        }
    }
    
    /// Resolve bazel-out/ paths
    private func resolveOutputPath(_ path: String, pathInfo: BazelPathInfo) -> String {
        // bazel-out/config/bin/... -> execution_root/bazel-out/config/bin/...
        return URL(fileURLWithPath: pathInfo.executionRoot).appendingPathComponent(path).path
    }
    
    /// Resolve external/ paths
    private func resolveExternalPath(_ path: String, pathInfo: BazelPathInfo) -> String {
        // external/dep/... -> execution_root/external/dep/...
        return URL(fileURLWithPath: pathInfo.executionRoot).appendingPathComponent(path).path
    }
    
    /// Resolve ../ relative paths
    private func resolveRelativePath(_ path: String, pathInfo: BazelPathInfo) -> String {
        // Resolve relative to execution root
        let executionRootURL = URL(fileURLWithPath: pathInfo.executionRoot)
        return executionRootURL.appendingPathComponent(path).standardized.path
    }
    
    /// Clear all cached path information
    public func clearCache() {
        cacheLock.withLock {
            pathCache.removeAll()
        }
        pathInfoLock.withLock {
            bazelPathInfo = nil
        }
    }
    
    /// Get current Bazel path information (if initialized)
    public func getCurrentPathInfo() -> BazelPathInfo? {
        return pathInfoLock.withLock { bazelPathInfo }
    }
}

// MARK: - Utilities

extension BazelPathNormalizer {
    
    /// Check if a path is a Bazel execution path
    public static func isBazelExecutionPath(_ path: String) -> Bool {
        return path.hasPrefix("bazel-out/") ||
               path.hasPrefix("external/") ||
               path.contains("bazel-") ||
               path.hasPrefix("../")
    }
    
    /// Extract configuration from bazel-out path
    public static func extractConfiguration(from path: String) -> String? {
        // bazel-out/ios-fastbuild/bin/... -> ios-fastbuild
        if path.hasPrefix("bazel-out/") {
            let components = path.components(separatedBy: "/")
            if components.count >= 2 {
                return components[1]
            }
        }
        return nil
    }
    
    /// Check if path represents a generated file
    public static func isGeneratedFile(_ path: String) -> Bool {
        return path.contains("bazel-out/") ||
               path.contains("bazel-bin/") ||
               path.contains("bazel-genfiles/")
    }
    
    /// Convert workspace-relative path to execution-relative path
    public func workspaceToExecutionPath(_ path: String) -> String {
        guard let pathInfo = getCurrentPathInfo() else {
            return path
        }
        
        // If path is under workspace, make it relative to execution root
        let workspaceURL = URL(fileURLWithPath: pathInfo.workspaceRoot)
        let pathURL = URL(fileURLWithPath: path)
        
        if let relativePath = pathURL.relativePath(from: workspaceURL) {
            return relativePath
        }
        
        return path
    }
}

// MARK: - URL Extension for Relative Paths

private extension URL {
    func relativePath(from base: URL) -> String? {
        // Get the path components
        let pathComponents = self.standardized.pathComponents
        let baseComponents = base.standardized.pathComponents
        
        // Find common prefix
        let commonLength = zip(pathComponents, baseComponents).prefix { $0.0 == $0.1 }.count
        
        // Make sure base is actually a prefix
        guard commonLength == baseComponents.count else {
            return nil
        }
        
        // Get the relative components
        let relativeComponents = Array(pathComponents.dropFirst(commonLength))
        
        if relativeComponents.isEmpty {
            return "."
        }
        
        return relativeComponents.joined(separator: "/")
    }
}