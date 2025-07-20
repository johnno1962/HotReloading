//
//  BazelPathResolver.swift
//  InjectionIII
//
//  Created by Karim Alweheshy on 20/07/2025.
//  Copyright © 2025 John Holdsworth. All rights reserved.
//
//  $Id: //depot/HotReloading/Sources/injectiond/BazelPathResolver.swift#1 $
//
//  Converts filesystem paths to Bazel labels and discovers package boundaries.
//  Handles the complex relationship between file paths and Bazel target labels.
//

import Foundation
import os

/// Errors that can occur during path resolution
public enum BazelPathError: Error, LocalizedError {
    case workspaceRootNotFound
    case fileNotInWorkspace(String)
    case buildFileNotFound(String)
    case invalidPackageStructure(String)
    case labelConversionFailed(String)
    case invalidPath(String)
    
    public var errorDescription: String? {
        switch self {
        case .workspaceRootNotFound:
            return "Bazel workspace root not found"
        case .fileNotInWorkspace(let path):
            return "File not in workspace: \(path)"
        case .buildFileNotFound(let path):
            return "No BUILD file found for path: \(path)"
        case .invalidPackageStructure(let path):
            return "Invalid package structure for path: \(path)"
        case .labelConversionFailed(let path):
            return "Failed to convert path to Bazel label: \(path)"
        case .invalidPath(let path):
            return "Invalid file path: \(path)"
        }
    }
}

/// Resolves filesystem paths to Bazel labels and manages package discovery
public class BazelPathResolver {
    private let workspaceRoot: URL
    private let bazelExecutable: String
    
    /// Cache for package boundaries: directory path -> package path
    private var packageCache: [String: String] = [:]
    
    /// Cache for BUILD file locations
    private var buildFileCache: Set<String> = []
    
    /// Cache access queue for thread safety
    private let cacheLock = OSAllocatedUnfairLock()
    
    /// Debug logging function
    private let debug: (Any...) -> Void
    
    public init(workspaceRoot: URL, bazelExecutable: String = "bazel", debug: @escaping (Any...) -> Void = { _ in }) {
        self.workspaceRoot = workspaceRoot
        self.bazelExecutable = bazelExecutable
        self.debug = debug
    }
    
    /// Discover all BUILD files in the workspace and cache package boundaries
    public func discoverBuildFiles() async throws {
        debug("Discovering BUILD files in workspace:", workspaceRoot.path)
        
        let buildFiles = try await findAllBuildFiles()
        
        cacheLock.withLock {
            self.buildFileCache = Set(buildFiles)
            self.packageCache.removeAll()
            
            // Cache package paths for each BUILD file
            for buildFile in buildFiles {
                let packageDir = URL(fileURLWithPath: buildFile).deletingLastPathComponent().path
                let packagePath = self.makeRelative(packageDir)
                self.packageCache[packageDir] = packagePath
            }
        }
        
        debug("Discovered \(buildFiles.count) BUILD files, cached \(packageCache.count) packages")
    }
    
    /// Convert a filesystem path to a Bazel label
    public func convertToLabel(_ filePath: String) throws -> String {
        // Normalize the path
        let normalizedPath = URL(fileURLWithPath: filePath).standardized.path
        
        // Ensure the file is within the workspace
        guard normalizedPath.hasPrefix(workspaceRoot.path) else {
            throw BazelPathError.fileNotInWorkspace(filePath)
        }
        
        // Get relative path from workspace root
        let relativePath = makeRelative(normalizedPath)
        
        // Find the package containing this file
        let packagePath = try findPackage(for: normalizedPath)
        
        // Construct the label
        return try constructLabel(packagePath: packagePath, relativePath: relativePath)
    }
    
    /// Find the package that contains the given file path
    public func findPackage(for filePath: String) throws -> String {
        let normalizedPath = URL(fileURLWithPath: filePath).standardized.path
        
        // Check cache first
        if let cachedPackage = cacheLock.withLock({ findCachedPackage(for: normalizedPath) }) {
            debug("Found cached package for \(filePath): \(cachedPackage)")
            return cachedPackage
        }
        
        // Find the nearest BUILD file by walking up the directory tree
        guard let buildFilePath = findNearestBuildFile(from: normalizedPath) else {
            throw BazelPathError.buildFileNotFound(filePath)
        }
        
        let packageDir = URL(fileURLWithPath: buildFilePath).deletingLastPathComponent().path
        let packagePath = makeRelative(packageDir)
        
        // Cache the result
        cacheLock.withLock {
            self.packageCache[packageDir] = packagePath
        }
        
        debug("Found package for \(filePath): \(packagePath)")
        return packagePath
    }
    
    /// Check if the given path represents a file target (vs a rule target)
    public func isFileTarget(_ path: String) throws -> Bool {
        let normalizedPath = URL(fileURLWithPath: path).standardized.path
        
        // A path is a file target if it points to an actual file
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: normalizedPath, isDirectory: &isDirectory)
        
        return exists && !isDirectory.boolValue
    }
    
    /// Get the relative path from workspace root
    public func getRelativePath(_ filePath: String) -> String {
        return makeRelative(filePath)
    }
    
    /// Clear all cached data
    public func clearCache() {
        cacheLock.withLock {
            self.packageCache.removeAll()
            self.buildFileCache.removeAll()
        }
    }
    
    /// Invalidate cache for specific paths (useful when files change)
    public func invalidateCache(for paths: [String]) {
        cacheLock.withLock {
            for path in paths {
                // If a BUILD file changed, invalidate package cache for its directory
                if path.contains("BUILD") {
                    let dir = URL(fileURLWithPath: path).deletingLastPathComponent().path
                    self.packageCache.removeValue(forKey: dir)
                    
                    // Also remove from build file cache and re-add if it still exists
                    self.buildFileCache.remove(path)
                    if FileManager.default.fileExists(atPath: path) {
                        self.buildFileCache.insert(path)
                    }
                }
                
                // For any file change, check if we need to invalidate its package cache
                let dir = URL(fileURLWithPath: path).deletingLastPathComponent().path
                if self.packageCache[dir] != nil {
                    // Verify the BUILD file still exists
                    if let buildFile = self.findNearestBuildFile(from: path),
                       !FileManager.default.fileExists(atPath: buildFile) {
                        self.packageCache.removeValue(forKey: dir)
                    }
                }
            }
        }
    }
    
    // MARK: - Private Methods
    
    /// Find all BUILD files in the workspace
    private func findAllBuildFiles() async throws -> [String] {
        var buildFiles: [String] = []
        
        // Use FileManager to recursively find BUILD files
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(at: workspaceRoot, 
                                                     includingPropertiesForKeys: [.isDirectoryKey],
                                                     options: [.skipsHiddenFiles]) else {
            throw BazelPathError.workspaceRootNotFound
        }
        
        for case let fileURL as URL in enumerator {
            let fileName = fileURL.lastPathComponent
            if fileName == "BUILD" || fileName == "BUILD.bazel" {
                buildFiles.append(fileURL.path)
            }
        }
        
        return buildFiles
    }
    
    /// Find the nearest BUILD file by walking up the directory tree
    private func findNearestBuildFile(from filePath: String) -> String? {
        var currentDir = URL(fileURLWithPath: filePath)
        
        // If the path is a file, start from its directory
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: currentDir.path, isDirectory: &isDirectory),
           !isDirectory.boolValue {
            currentDir = currentDir.deletingLastPathComponent()
        }
        
        // Walk up the directory tree
        while currentDir.path.hasPrefix(workspaceRoot.path) && currentDir.path != "/" {
            let buildFile = currentDir.appendingPathComponent("BUILD")
            let buildBazelFile = currentDir.appendingPathComponent("BUILD.bazel")
            
            if FileManager.default.fileExists(atPath: buildFile.path) {
                return buildFile.path
            }
            if FileManager.default.fileExists(atPath: buildBazelFile.path) {
                return buildBazelFile.path
            }
            
            // Move up one directory
            let parentDir = currentDir.deletingLastPathComponent()
            if parentDir.path == currentDir.path {
                break // Reached root
            }
            currentDir = parentDir
        }
        
        return nil
    }
    
    /// Find a cached package for the given path
    private func findCachedPackage(for filePath: String) -> String? {
        var currentDir = URL(fileURLWithPath: filePath)
        
        // If the path is a file, start from its directory
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: currentDir.path, isDirectory: &isDirectory),
           !isDirectory.boolValue {
            currentDir = currentDir.deletingLastPathComponent()
        }
        
        // Check cache for this directory and parent directories
        while currentDir.path.hasPrefix(workspaceRoot.path) && currentDir.path != "/" {
            if let cachedPackage = packageCache[currentDir.path] {
                return cachedPackage
            }
            
            let parentDir = currentDir.deletingLastPathComponent()
            if parentDir.path == currentDir.path {
                break
            }
            currentDir = parentDir
        }
        
        return nil
    }
    
    /// Convert an absolute path to a relative path from workspace root
    private func makeRelative(_ path: String) -> String {
        let normalizedPath = URL(fileURLWithPath: path).standardized.path
        let workspacePath = workspaceRoot.standardized.path
        
        if normalizedPath.hasPrefix(workspacePath + "/") {
            return String(normalizedPath.dropFirst(workspacePath.count + 1))
        } else if normalizedPath == workspacePath {
            return ""
        } else {
            return normalizedPath
        }
    }
    
    /// Construct a Bazel label from package path and relative file path
    private func constructLabel(packagePath: String, relativePath: String) throws -> String {
        // Handle root package
        if packagePath.isEmpty {
            return "//:\(relativePath)"
        }
        
        // Handle file in package directory
        if relativePath.hasPrefix(packagePath + "/") {
            let fileInPackage = String(relativePath.dropFirst(packagePath.count + 1))
            return "//\(packagePath):\(fileInPackage)"
        }
        
        // Handle file that is the package itself or in a parent
        if relativePath == packagePath {
            // This might be a BUILD file or similar
            let fileName = URL(fileURLWithPath: relativePath).lastPathComponent
            return "//\(packagePath):\(fileName)"
        }
        
        // If we get here, there might be an issue with package detection
        debug("Warning: Complex label construction for package=\(packagePath), relative=\(relativePath)")
        
        // Try to construct a reasonable label anyway
        if relativePath.hasPrefix(packagePath) {
            let remainder = String(relativePath.dropFirst(packagePath.count))
            if remainder.hasPrefix("/") {
                return "//\(packagePath):\(String(remainder.dropFirst()))"
            } else {
                return "//\(packagePath):\(remainder)"
            }
        } else {
            // The file might be in a parent package
            return "//\(packagePath):\(relativePath)"
        }
    }
}