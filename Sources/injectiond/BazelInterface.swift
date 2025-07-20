//
//  BazelInterface.swift
//  InjectionIII
//
//  Created by Karim Alweheshy on 18/07/2025.
//  Copyright © 2025 John Holdsworth. All rights reserved.
//
//  $Id: //depot/HotReloading/Sources/injectiond/BazelInterface.swift#1 $
//
//  Interface for communicating with Bazel build system.
//  Provides query, build, and hot reload dylib generation capabilities.
//

import Foundation
import os

/// Errors that can occur during Bazel operations
public enum BazelError: Error, LocalizedError {
    case workspaceNotFound
    case bazelNotFound
    case queryFailed(String)
    case buildFailed(String)
    case invalidTarget(String)
    case noBuildOutput
    case dylibNotFound
    
    public var errorDescription: String? {
        switch self {
        case .workspaceNotFound:
            return "Bazel workspace not found. Looking for MODULE or MODULE.bazel file."
        case .bazelNotFound:
            return "Bazel executable not found. Make sure Bazel is installed and in PATH."
        case .queryFailed(let message):
            return "Bazel query failed: \(message)"
        case .buildFailed(let message):
            return "Bazel build failed: \(message)"
        case .invalidTarget(let target):
            return "Invalid Bazel target: \(target)"
        case .noBuildOutput:
            return "No build output found from Bazel"
        case .dylibNotFound:
            return "Generated dylib not found in Bazel outputs"
        }
    }
}

/// Interface for Bazel build system operations
public class BazelInterface {
    private let workspaceRoot: URL
    private let bazelExecutable: String
    
    /// Cache for source file to target mappings
    private var sourceToTargetCache: [String: String] = [:]
    private let cacheLock = OSAllocatedUnfairLock()
    
    /// Debug logging function
    private let debug: (Any...) -> Void
    
    public init(workspaceRoot: URL, bazelExecutable: String = "bazel", debug: @escaping (Any...) -> Void = { _ in }) {
        self.workspaceRoot = workspaceRoot
        self.bazelExecutable = bazelExecutable
        self.debug = debug
    }
    
    /// Find the Bazel workspace root by looking for MODULE files (Bazel 6.0+ with bzlmod)
    public static func findWorkspaceRoot(from path: URL) -> URL? {
        var currentDir = path
        
        // Walk up directory tree looking for MODULE or MODULE.bazel (modern Bazel with bzlmod)
        while currentDir.path != "/" {
            let module = currentDir.appendingPathComponent("MODULE")
            let moduleBazel = currentDir.appendingPathComponent("MODULE.bazel")
            
            if FileManager.default.fileExists(atPath: module.path) ||
               FileManager.default.fileExists(atPath: moduleBazel.path) {
                return currentDir
            }
            
            currentDir = currentDir.deletingLastPathComponent()
        }
        
        return nil
    }
    
    /// Check if Bazel is available in the system
    public static func isBazelAvailable() -> Bool {
        let task = Process()
        task.launchPath = "/usr/bin/which"
        task.arguments = ["bazel"]
        task.launch()
        task.waitUntilExit()
        return task.terminationStatus == 0
    }
    
    /// Maps a source file to its Bazel target
    public func findTarget(for sourceFile: String) async throws -> String? {
        // Check cache first
        if let cachedTarget = cacheLock.withLock({ sourceToTargetCache[sourceFile] }) {
            debug("Found cached target for \(sourceFile): \(cachedTarget)")
            return cachedTarget
        }
        
        let relativePath = sourceFile.replacingOccurrences(of: workspaceRoot.path + "/", with: "")
        debug("Finding target for relative path:", relativePath)
        
        // Use Bazel query to find targets that include this source file
        let query = "attr(srcs, '.*\(relativePath.replacingOccurrences(of: ".", with: "\\."))', //...)"
        
        do {
            let result = try await runBazelQuery(query)
            let targets = result.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
            
            if let target = targets.first {
                debug("Found target for \(sourceFile): \(target)")
                
                // Cache the result
                cacheLock.withLock {
                    sourceToTargetCache[sourceFile] = target
                }
                
                return target
            }
        } catch {
            debug("Query failed for \(sourceFile):", error.localizedDescription)
        }
        
        debug("No target found for \(sourceFile)")
        return nil
    }
    
    /// Gets all dependencies for a target
    public func getDependencies(for target: String) async throws -> [String] {
        debug("Getting dependencies for target:", target)
        
        let query = "deps(\(target))"
        let result = try await runBazelQuery(query)
        
        let dependencies = result.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        debug("Found \(dependencies.count) dependencies for \(target)")
        
        return dependencies
    }
    
    /// Gets reverse dependencies (targets that depend on this target)
    public func getReverseDependencies(for target: String) async throws -> [String] {
        debug("Getting reverse dependencies for target:", target)
        
        let query = "rdeps(//..., \(target))"
        let result = try await runBazelQuery(query)
        
        let reverseDeps = result.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        debug("Found \(reverseDeps.count) reverse dependencies for \(target)")
        
        return reverseDeps
    }
    
    /// Runs an incremental build with BEP output
    public func buildWithBEP(target: String, bepOutput: URL) async throws {
        debug("Building target with BEP:", target, "output:", bepOutput.path)
        
        let args = [
            "build",
            target,
            "--compilation_mode=fastbuild",
            "--features=swift.use_global_module_cache",
            "--build_event_json_file=\(bepOutput.path)",
            "--experimental_build_event_json_file_path_conversion=false",
            "--noshow_progress",
            "--output_groups=+compilation_outputs"
        ]
        
        try await runBazel(args)
        debug("Build completed for target:", target)
    }
    
    /// Build a target for hot reload (optimized for fast iteration)
    public func buildForHotReload(target: String, bepOutput: URL) async throws {
        debug("Building target for hot reload:", target)
        
        let args = [
            "build",
            target,
            "--compilation_mode=fastbuild",
            "--features=swift.use_global_module_cache",
            "--build_event_json_file=\(bepOutput.path)",
            "--experimental_build_event_json_file_path_conversion=false",
            "--noshow_progress",
            "--output_groups=+compilation_outputs,+dynamic_library",
            // Fast iteration flags
            "--keep_going",
            "--jobs=auto"
        ]
        
        try await runBazel(args)
        debug("Hot reload build completed for target:", target)
    }
    
    /// Build a hot reload dylib for a specific source file
    public func buildHotReloadDylib(for sourceFile: String, target: String) async throws -> URL? {
        debug("Building hot reload dylib for:", sourceFile, "in target:", target)
        
        // Extract the hot reload target name based on source file
        let fileName = URL(fileURLWithPath: sourceFile).deletingPathExtension().lastPathComponent
        let hotReloadTarget = "\(target)_hot_reload_\(fileName)"
        
        let bepOutput = URL(fileURLWithPath: "/tmp/hot_reload_\(UUID().uuidString).json")
        
        let args = [
            "build",
            hotReloadTarget,
            "--compilation_mode=fastbuild",
            "--build_event_json_file=\(bepOutput.path)",
            "--experimental_build_event_json_file_path_conversion=false",
            "--noshow_progress",
            "--output_groups=+default"
        ]
        
        do {
            try await runBazel(args)
            
            // Parse BEP output to find the generated dylib
            let parser = BazelBuildEventParser(debug: debug)
            let commands = try parser.parseBEPStream(from: bepOutput)
            
            // Find dylib in the output files
            for command in commands {
                for outputFile in command.outputFiles {
                    if outputFile.hasSuffix(".dylib") {
                        let resolvedPath = resolveBazelPath(outputFile)
                        debug("Found hot reload dylib:", resolvedPath)
                        return URL(fileURLWithPath: resolvedPath)
                    }
                }
            }
            
            // Clean up BEP file
            try? FileManager.default.removeItem(at: bepOutput)
            
        } catch {
            debug("Hot reload dylib build failed:", error.localizedDescription)
            throw BazelError.buildFailed(error.localizedDescription)
        }
        
        throw BazelError.dylibNotFound
    }
    
    /// Resolves sandbox paths to actual file system paths
    public func resolveBazelPath(_ path: String) -> String {
        if path.contains("bazel-out") {
            // Get output base and workspace name
            do {
                let outputBase = try runBazelSync(["info", "output_base"])
                let workspaceName = try runBazelSync(["info", "workspace"])
                
                let resolved = path.replacingOccurrences(
                    of: "bazel-out",
                    with: "\(outputBase.trimmingCharacters(in: .whitespacesAndNewlines))/execroot/\(workspaceName.trimmingCharacters(in: .whitespacesAndNewlines))/bazel-out"
                )
                debug("Resolved Bazel path:", path, "->", resolved)
                return resolved
            } catch {
                debug("Failed to resolve Bazel path:", path, error.localizedDescription)
            }
        }
        
        return path
    }
    
    /// Get build information from Bazel
    public func getBuildInfo() async throws -> [String: String] {
        debug("Getting Bazel build info")
        
        let commands = ["output_base", "workspace", "execution_root", "output_path"]
        var info: [String: String] = [:]
        
        for command in commands {
            do {
                let result = try await runBazel(["info", command])
                info[command] = result.trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                debug("Failed to get \(command):", error.localizedDescription)
            }
        }
        
        return info
    }
    
    /// Clear the source-to-target cache
    public func clearCache() {
        cacheLock.withLock {
            sourceToTargetCache.removeAll()
        }
        debug("Cleared Bazel interface cache")
    }
    
    /// Run a Bazel command asynchronously
    private func runBazel(_ arguments: [String]) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    let result = try self.runBazelSync(arguments)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    /// Run a Bazel command synchronously
    private func runBazelSync(_ arguments: [String]) throws -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: bazelExecutable)
        task.arguments = arguments
        task.currentDirectoryURL = workspaceRoot
        
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        task.standardOutput = outputPipe
        task.standardError = errorPipe
        
        debug("Running Bazel command:", ([bazelExecutable] + arguments).joined(separator: " "))
        
        try task.run()
        task.waitUntilExit()
        
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        
        let output = String(data: outputData, encoding: .utf8) ?? ""
        let error = String(data: errorData, encoding: .utf8) ?? ""
        
        guard task.terminationStatus == 0 else {
            let errorMessage = error.isEmpty ? "Unknown error" : error
            debug("Bazel command failed:", errorMessage)
            throw BazelError.buildFailed(errorMessage)
        }
        
        return output
    }
    
    /// Run a Bazel query command
    private func runBazelQuery(_ query: String) async throws -> String {
        debug("Running Bazel query:", query)
        return try await runBazel(["query", query])
    }
    
    /// Validate that the workspace is a valid Bazel workspace
    public func validateWorkspace() throws {
        let moduleFile = workspaceRoot.appendingPathComponent("MODULE")
        let moduleBazelFile = workspaceRoot.appendingPathComponent("MODULE.bazel")
        
        guard FileManager.default.fileExists(atPath: moduleFile.path) ||
              FileManager.default.fileExists(atPath: moduleBazelFile.path) else {
            throw BazelError.workspaceNotFound
        }
        
        // Check if bazel is available
        let whichTask = Process()
        whichTask.launchPath = "/usr/bin/which"
        whichTask.arguments = [bazelExecutable]
        whichTask.launch()
        whichTask.waitUntilExit()
        
        guard whichTask.terminationStatus == 0 else {
            throw BazelError.bazelNotFound
        }
    }
    
    /// Get the workspace name
    public func getWorkspaceName() async throws -> String {
        let result = try await runBazel(["info", "workspace"])
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    /// Get output base directory
    public func getOutputBase() async throws -> String {
        let result = try await runBazel(["info", "output_base"])
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    /// Check if a target exists
    public func targetExists(_ target: String) async throws -> Bool {
        do {
            let result = try await runBazelQuery("kind(rule, \(target))")
            return !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } catch {
            return false
        }
    }
    
    /// Get all Swift targets in the workspace
    public func getSwiftTargets() async throws -> [String] {
        let query = "kind(swift_library, //...)"
        let result = try await runBazelQuery(query)
        
        return result.split(separator: "\n")
            .map(String.init)
            .filter { !$0.isEmpty }
    }
}

/// Extension for convenient async operations
extension BazelInterface {
    /// Build multiple targets concurrently
    public func buildTargets(_ targets: [String], bepOutput: URL) async throws {
        let targetString = targets.joined(separator: " ")
        debug("Building multiple targets:", targetString)
        
        let args = [
            "build",
            targetString,
            "--compilation_mode=fastbuild",
            "--features=swift.use_global_module_cache",
            "--build_event_json_file=\(bepOutput.path)",
            "--experimental_build_event_json_file_path_conversion=false",
            "--noshow_progress",
            "--output_groups=+compilation_outputs"
        ]
        
        try await runBazel(args)
    }
    
    /// Find all source files in a target
    public func getSourceFiles(for target: String) async throws -> [String] {
        let query = "attr(srcs, '.*\\.swift', \(target))"
        let result = try await runBazelQuery(query)
        
        // This is a simplified approach - in practice you'd need to parse the target definition
        return result.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }
}