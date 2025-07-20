//
//  AQueryCache.swift
//  InjectionIII
//
//  Created by Karim Alweheshy on 20/07/2025.
//  Copyright © 2025 John Holdsworth. All rights reserved.
//
//  $Id: //depot/HotReloading/Sources/injectiond/AQueryCache.swift#1 $
//
//  High-performance caching layer for Bazel aquery results and compilation commands.
//  Reduces repeated Bazel calls and improves hot reload iteration speed.
//

import Foundation
import os

/// Cache key for action graph results
public struct ActionGraphCacheKey: Hashable, Codable {
    let target: String
    let query: String
    let bazelVersion: String?
    let workspaceHash: String
    
    public init(target: String, query: String, bazelVersion: String?, workspaceHash: String) {
        self.target = target
        self.query = query
        self.bazelVersion = bazelVersion
        self.workspaceHash = workspaceHash
    }
}

/// Cache key for compilation commands
public struct CompilationCommandCacheKey: Hashable, Codable {
    let sourceFile: String
    let target: String
    let fileModificationTime: TimeInterval
    let buildConfigHash: String
    
    public init(sourceFile: String, target: String, fileModificationTime: TimeInterval, buildConfigHash: String) {
        self.sourceFile = sourceFile
        self.target = target
        self.fileModificationTime = fileModificationTime
        self.buildConfigHash = buildConfigHash
    }
}

/// Cached action graph with metadata
public struct CachedActionGraph: Codable {
    let actionGraph: ActionGraphContainer
    let cacheTime: Date
    let bazelVersion: String?
    let target: String
    
    /// Check if the cached data is still valid
    public func isValid(maxAge: TimeInterval = 300) -> Bool { // 5 minutes default
        return Date().timeIntervalSince(cacheTime) < maxAge
    }
}

/// Cached compilation command with metadata
public struct CachedCompilationCommand: Codable {
    let command: CompilationCommand
    let cacheTime: Date
    let sourceFileModTime: TimeInterval
    
    /// Check if the cached command is still valid
    public func isValid(currentSourceModTime: TimeInterval, maxAge: TimeInterval = 600) -> Bool { // 10 minutes default
        return Date().timeIntervalSince(cacheTime) < maxAge && 
               abs(sourceFileModTime - currentSourceModTime) < 1.0 // Allow 1 second tolerance
    }
}

/// High-performance cache for Bazel aquery results
public class AQueryCache {
    
    /// Cache storage
    private var actionGraphCache: [ActionGraphCacheKey: CachedActionGraph] = [:]
    private var compilationCommandCache: [CompilationCommandCacheKey: CachedCompilationCommand] = [:]
    private var targetToSourceFileCache: [String: Set<String>] = [:]
    
    /// Cache metadata
    private let workspaceRoot: URL
    private let maxActionGraphAge: TimeInterval
    private let maxCompilationCommandAge: TimeInterval
    private let maxCacheSize: Int
    
    /// Thread safety
    private let cacheLock = OSAllocatedUnfairLock()
    
    /// Workspace hash for cache invalidation
    private var workspaceHash: String?
    private var bazelVersion: String?
    
    /// Debug logging
    private let debug: (Any...) -> Void
    
    /// Cache statistics
    public struct CacheStats {
        public let actionGraphHits: Int
        public let actionGraphMisses: Int
        public let compilationCommandHits: Int
        public let compilationCommandMisses: Int
        public let cacheSize: Int
        
        public var actionGraphHitRate: Double {
            let total = actionGraphHits + actionGraphMisses
            return total > 0 ? Double(actionGraphHits) / Double(total) : 0.0
        }
        
        public var compilationCommandHitRate: Double {
            let total = compilationCommandHits + compilationCommandMisses
            return total > 0 ? Double(compilationCommandHits) / Double(total) : 0.0
        }
    }
    
    private var stats = CacheStats(actionGraphHits: 0, actionGraphMisses: 0, 
                                  compilationCommandHits: 0, compilationCommandMisses: 0, cacheSize: 0)
    
    public init(
        workspaceRoot: URL,
        maxActionGraphAge: TimeInterval = 300, // 5 minutes
        maxCompilationCommandAge: TimeInterval = 600, // 10 minutes
        maxCacheSize: Int = 1000,
        debug: @escaping (Any...) -> Void = { _ in }
    ) {
        self.workspaceRoot = workspaceRoot
        self.maxActionGraphAge = maxActionGraphAge
        self.maxCompilationCommandAge = maxCompilationCommandAge
        self.maxCacheSize = maxCacheSize
        self.debug = debug
        
        // Initialize workspace hash and Bazel version
        Task {
            await initializeCacheMetadata()
        }
    }
    
    // MARK: - Action Graph Caching
    
    /// Get cached action graph or return nil if not available/valid
    public func getCachedActionGraph(for target: String, query: String) async -> ActionGraphContainer? {
        return cacheLock.withLock {
            guard let workspaceHash = self.workspaceHash else { return nil }
            
            let key = ActionGraphCacheKey(
                target: target,
                query: query,
                bazelVersion: self.bazelVersion,
                workspaceHash: workspaceHash
            )
            
            if let cached = actionGraphCache[key], cached.isValid(maxAge: maxActionGraphAge) {
                stats = CacheStats(
                    actionGraphHits: stats.actionGraphHits + 1,
                    actionGraphMisses: stats.actionGraphMisses,
                    compilationCommandHits: stats.compilationCommandHits,
                    compilationCommandMisses: stats.compilationCommandMisses,
                    cacheSize: stats.cacheSize
                )
                debug("Action graph cache HIT for target: \(target)")
                return cached.actionGraph
            }
            
            stats = CacheStats(
                actionGraphHits: stats.actionGraphHits,
                actionGraphMisses: stats.actionGraphMisses + 1,
                compilationCommandHits: stats.compilationCommandHits,
                compilationCommandMisses: stats.compilationCommandMisses,
                cacheSize: stats.cacheSize
            )
            debug("Action graph cache MISS for target: \(target)")
            return nil
        }
    }
    
    /// Cache an action graph result
    public func cacheActionGraph(_ actionGraph: ActionGraphContainer, for target: String, query: String) async {
        cacheLock.withLock {
            guard let workspaceHash = self.workspaceHash else { return }
            
            let key = ActionGraphCacheKey(
                target: target,
                query: query,
                bazelVersion: self.bazelVersion,
                workspaceHash: workspaceHash
            )
            
            let cached = CachedActionGraph(
                actionGraph: actionGraph,
                cacheTime: Date(),
                bazelVersion: self.bazelVersion,
                target: target
            )
            
            actionGraphCache[key] = cached
            
            // Update target to source file mapping
            updateTargetSourceMapping(target: target, actionGraph: actionGraph)
            
            // Enforce cache size limits
            enforceActionGraphCacheSize()
            
            updateCacheSize()
            debug("Cached action graph for target: \(target)")
        }
    }
    
    // MARK: - Compilation Command Caching
    
    /// Get cached compilation command or return nil if not available/valid
    public func getCachedCompilationCommand(for sourceFile: String, target: String) async -> CompilationCommand? {
        return cacheLock.withLock {
            guard let sourceModTime = getFileModificationTime(sourceFile),
                  let buildConfigHash = getBuildConfigurationHash() else {
                return nil
            }
            
            let key = CompilationCommandCacheKey(
                sourceFile: sourceFile,
                target: target,
                fileModificationTime: sourceModTime,
                buildConfigHash: buildConfigHash
            )
            
            if let cached = compilationCommandCache[key], 
               cached.isValid(currentSourceModTime: sourceModTime, maxAge: maxCompilationCommandAge) {
                stats = CacheStats(
                    actionGraphHits: stats.actionGraphHits,
                    actionGraphMisses: stats.actionGraphMisses,
                    compilationCommandHits: stats.compilationCommandHits + 1,
                    compilationCommandMisses: stats.compilationCommandMisses,
                    cacheSize: stats.cacheSize
                )
                debug("Compilation command cache HIT for: \(sourceFile)")
                return cached.command
            }
            
            stats = CacheStats(
                actionGraphHits: stats.actionGraphHits,
                actionGraphMisses: stats.actionGraphMisses,
                compilationCommandHits: stats.compilationCommandHits,
                compilationCommandMisses: stats.compilationCommandMisses + 1,
                cacheSize: stats.cacheSize
            )
            debug("Compilation command cache MISS for: \(sourceFile)")
            return nil
        }
    }
    
    /// Cache a compilation command
    public func cacheCompilationCommand(_ command: CompilationCommand, for sourceFile: String, target: String) async {
        cacheLock.withLock {
            guard let sourceModTime = getFileModificationTime(sourceFile),
                  let buildConfigHash = getBuildConfigurationHash() else {
                return
            }
            
            let key = CompilationCommandCacheKey(
                sourceFile: sourceFile,
                target: target,
                fileModificationTime: sourceModTime,
                buildConfigHash: buildConfigHash
            )
            
            let cached = CachedCompilationCommand(
                command: command,
                cacheTime: Date(),
                sourceFileModTime: sourceModTime
            )
            
            compilationCommandCache[key] = cached
            
            // Enforce cache size limits
            enforceCompilationCommandCacheSize()
            
            updateCacheSize()
            debug("Cached compilation command for: \(sourceFile)")
        }
    }
    
    // MARK: - Cache Management
    
    /// Clear all caches
    public func clearAll() async {
        cacheLock.withLock {
            actionGraphCache.removeAll()
            compilationCommandCache.removeAll()
            targetToSourceFileCache.removeAll()
            
            stats = CacheStats(actionGraphHits: 0, actionGraphMisses: 0,
                              compilationCommandHits: 0, compilationCommandMisses: 0, cacheSize: 0)
            
            debug("Cleared all caches")
        }
    }
    
    /// Clear cache for specific target
    public func clearTarget(_ target: String) async {
        cacheLock.withLock {
            // Remove action graph entries for this target
            actionGraphCache = actionGraphCache.filter { key, _ in
                key.target != target
            }
            
            // Remove compilation command entries for this target
            compilationCommandCache = compilationCommandCache.filter { key, _ in
                key.target != target
            }
            
            // Remove from target mapping
            targetToSourceFileCache.removeValue(forKey: target)
            
            updateCacheSize()
            debug("Cleared cache for target: \(target)")
        }
    }
    
    /// Clear cache for specific source file
    public func clearSourceFile(_ sourceFile: String) async {
        cacheLock.withLock {
            compilationCommandCache = compilationCommandCache.filter { key, _ in
                key.sourceFile != sourceFile
            }
            
            updateCacheSize()
            debug("Cleared cache for source file: \(sourceFile)")
        }
    }
    
    /// Get cache statistics
    public func getStats() async -> CacheStats {
        return cacheLock.withLock {
            return stats
        }
    }
    
    /// Invalidate cache when workspace changes
    public func invalidateOnWorkspaceChange() async {
        let newWorkspaceHash = await computeWorkspaceHash()
        let newBazelVersion = await getBazelVersionString()
        
        cacheLock.withLock {
            if workspaceHash != newWorkspaceHash || bazelVersion != newBazelVersion {
                debug("Workspace or Bazel version changed, invalidating caches")
                actionGraphCache.removeAll()
                compilationCommandCache.removeAll()
                targetToSourceFileCache.removeAll()
                
                workspaceHash = newWorkspaceHash
                bazelVersion = newBazelVersion
                
                updateCacheSize()
            }
        }
    }
    
    // MARK: - Private Implementation
    
    private func initializeCacheMetadata() async {
        workspaceHash = await computeWorkspaceHash()
        bazelVersion = await getBazelVersionString()
    }
    
    private func computeWorkspaceHash() async -> String {
        // Create a hash based on MODULE/MODULE.bazel and workspace structure
        let moduleFile = workspaceRoot.appendingPathComponent("MODULE")
        let moduleBazelFile = workspaceRoot.appendingPathComponent("MODULE.bazel")
        
        var hashInput = workspaceRoot.path
        
        // Include MODULE file content if it exists
        if let moduleContent = try? String(contentsOf: moduleFile) {
            hashInput += moduleContent
        } else if let moduleBazelContent = try? String(contentsOf: moduleBazelFile) {
            hashInput += moduleBazelContent
        }
        
        return String(hashInput.hashValue)
    }
    
    private func getBazelVersionString() async -> String? {
        let process = Process()
        process.launchPath = "/usr/bin/env"
        process.arguments = ["bazel", "version"]
        process.currentDirectoryPath = workspaceRoot.path
        
        let pipe = Pipe()
        process.standardOutput = pipe
        
        do {
            process.launch()
            process.waitUntilExit()
            
            if process.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                
                // Extract version from first line
                if let firstLine = output.split(separator: "\n").first {
                    return String(firstLine)
                }
            }
        } catch {
            debug("Failed to get Bazel version:", error)
        }
        
        return nil
    }
    
    private func getFileModificationTime(_ filePath: String) -> TimeInterval? {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: filePath)
            return (attributes[.modificationDate] as? Date)?.timeIntervalSince1970
        } catch {
            return nil
        }
    }
    
    private func getBuildConfigurationHash() -> String? {
        // Create a hash based on current build configuration
        // This could include compiler version, target platform, etc.
        var hashInput = ""
        
        // Add target platform
        #if os(macOS)
        hashInput += "macos"
        #elseif os(iOS)
        hashInput += "ios"
        #endif
        
        // Add bazel version
        if let version = bazelVersion {
            hashInput += version
        }
        
        return String(hashInput.hashValue)
    }
    
    private func updateTargetSourceMapping(target: String, actionGraph: ActionGraphContainer) {
        var sourceFiles: Set<String> = []
        
        // Extract source files from action graph
        for action in actionGraph.actions {
            for arg in action.arguments {
                if arg.hasSuffix(".swift") {
                    sourceFiles.insert(arg)
                }
            }
        }
        
        targetToSourceFileCache[target] = sourceFiles
    }
    
    private func enforceActionGraphCacheSize() {
        if actionGraphCache.count > maxCacheSize {
            // Remove oldest entries
            let sortedKeys = actionGraphCache.keys.sorted { key1, key2 in
                let cache1 = actionGraphCache[key1]!
                let cache2 = actionGraphCache[key2]!
                return cache1.cacheTime < cache2.cacheTime
            }
            
            let keysToRemove = sortedKeys.prefix(actionGraphCache.count - maxCacheSize)
            for key in keysToRemove {
                actionGraphCache.removeValue(forKey: key)
            }
            
            debug("Evicted \(keysToRemove.count) action graph entries to enforce size limit")
        }
    }
    
    private func enforceCompilationCommandCacheSize() {
        if compilationCommandCache.count > maxCacheSize {
            // Remove oldest entries
            let sortedKeys = compilationCommandCache.keys.sorted { key1, key2 in
                let cache1 = compilationCommandCache[key1]!
                let cache2 = compilationCommandCache[key2]!
                return cache1.cacheTime < cache2.cacheTime
            }
            
            let keysToRemove = sortedKeys.prefix(compilationCommandCache.count - maxCacheSize)
            for key in keysToRemove {
                compilationCommandCache.removeValue(forKey: key)
            }
            
            debug("Evicted \(keysToRemove.count) compilation command entries to enforce size limit")
        }
    }
    
    private func updateCacheSize() {
        let totalSize = actionGraphCache.count + compilationCommandCache.count
        stats = CacheStats(
            actionGraphHits: stats.actionGraphHits,
            actionGraphMisses: stats.actionGraphMisses,
            compilationCommandHits: stats.compilationCommandHits,
            compilationCommandMisses: stats.compilationCommandMisses,
            cacheSize: totalSize
        )
    }
}

// MARK: - Cache Statistics Extension

extension AQueryCache.CacheStats: CustomStringConvertible {
    public var description: String {
        let actionGraphRate = String(format: "%.1f%%", actionGraphHitRate * 100)
        let compilationCommandRate = String(format: "%.1f%%", compilationCommandHitRate * 100)
        
        return """
        AQuery Cache Statistics:
        - Action Graph: \(actionGraphHits) hits, \(actionGraphMisses) misses (\(actionGraphRate) hit rate)
        - Compilation Commands: \(compilationCommandHits) hits, \(compilationCommandMisses) misses (\(compilationCommandRate) hit rate)
        - Total Cache Size: \(cacheSize) entries
        """
    }
}