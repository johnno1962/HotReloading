//
//  BazelFileWatcher.swift
//  InjectionIII
//
//  Created by Karim Alweheshy on 18/07/2025.
//  Copyright © 2025 John Holdsworth. All rights reserved.
//
//  $Id: //depot/HotReloading/Sources/injectiond/BazelFileWatcher.swift#1 $
//
//  Bazel-aware file watcher for hot reloading.
//  Maps file changes to Bazel targets and triggers appropriate builds.
//

import Foundation

/// Represents a file change event
public struct FileChange {
    public let path: String
    public let changeType: ChangeType
    public let timestamp: TimeInterval
    
    public enum ChangeType {
        case created
        case modified
        case deleted
        case renamed
    }
    
    public init(path: String, changeType: ChangeType, timestamp: TimeInterval = Date().timeIntervalSince1970) {
        self.path = path
        self.changeType = changeType
        self.timestamp = timestamp
    }
}

/// Bazel-aware file watcher that maps file changes to targets
public class BazelFileWatcher: FileWatcher {
    
    private let bazelInterface: BazelInterface
    private var sourceToTargetCache: [String: String] = [:]
    private var targetToSourcesCache: [String: Set<String>] = [:]
    private let cacheQueue = DispatchQueue(label: "bazel.cache.queue")
    
    /// Callback for when Bazel file changes are detected
    public var bazelFileChangeCallback: ((String, String) -> Void)?
    
    /// Debug logging function
    private let debug: (Any...) -> Void
    
    public init(bazelInterface: BazelInterface, debug: @escaping (Any...) -> Void = { _ in }) {
        self.bazelInterface = bazelInterface
        self.debug = debug
        super.init()
    }
    
    /// Start watching directories with Bazel awareness
    public func startWatching(roots: [String], callback: @escaping ([String], String) -> Void) {
        debug("Starting Bazel file watcher for roots:", roots)
        
        // Store the callback for later use
        self.bazelFileChangeCallback = { [weak self] path, target in
            callback([path], "")
        }
        
        // Initialize file watchers for each root
        for root in roots {
            let watcher = FileWatcher(roots: [root]) { [weak self] changes, ideProcPath in
                self?.handleFileChanges(changes as! [String], ideProcPath: ideProcPath)
            }
            // Store the watcher to keep it alive
            // Note: In a real implementation, you'd want to store these watchers properly
        }
    }
    
    /// Handle file changes with Bazel target mapping
    private func handleFileChanges(_ changes: [String], ideProcPath: String) {
        debug("Handling file changes:", changes)
        
        Task {
            await processFileChanges(changes, ideProcPath: ideProcPath)
        }
    }
    
    /// Process file changes asynchronously
    private func processFileChanges(_ changes: [String], ideProcPath: String) async {
        var processedChanges: [String] = []
        
        for change in changes {
            await handleSingleFileChange(change, processedChanges: &processedChanges)
        }
        
        // Call the original callback if there are processed changes
        if !processedChanges.isEmpty {
            bazelFileChangeCallback?(processedChanges[0], "")
        }
    }
    
    /// Handle a single file change
    private func handleSingleFileChange(_ changePath: String, processedChanges: inout [String]) async {
        guard changePath.hasSuffix(".swift") || changePath.hasSuffix(".m") || changePath.hasSuffix(".mm") else {
            debug("Ignoring non-source file:", changePath)
            return
        }
        
        debug("Processing file change:", changePath)
        
        // Check cache first
        let cachedTarget = cacheQueue.sync { sourceToTargetCache[changePath] }
        
        let target: String
        if let cached = cachedTarget {
            target = cached
            debug("Found cached target for \(changePath): \(target)")
        } else {
            // Find target for the changed file
            do {
                if let found = try await bazelInterface.findTarget(for: changePath) {
                    target = found
                    // Cache the mapping
                    cacheQueue.sync {
                        sourceToTargetCache[changePath] = found
                        var sources = targetToSourcesCache[found] ?? Set<String>()
                        sources.insert(changePath)
                        targetToSourcesCache[found] = sources
                    }
                    debug("Found and cached target for \(changePath): \(target)")
                } else {
                    debug("No Bazel target found for \(changePath)")
                    return
                }
            } catch {
                debug("Error finding target for \(changePath):", error.localizedDescription)
                return
            }
        }
        
        // Check if we should process this change
        if shouldProcessChange(changePath, target: target) {
            processedChanges.append(changePath)
            debug("Queued \(changePath) for processing (target: \(target))")
            
            // Notify about the Bazel file change
            bazelFileChangeCallback?(changePath, target)
        }
    }
    
    /// Determine if a file change should be processed
    private func shouldProcessChange(_ path: String, target: String) -> Bool {
        // For now, process all Swift and Objective-C files
        // In the future, we could add more sophisticated filtering
        return path.hasSuffix(".swift") || path.hasSuffix(".m") || path.hasSuffix(".mm")
    }
    
    /// Get target for a specific source file
    public func getTarget(for sourceFile: String) -> String? {
        return cacheQueue.sync { sourceToTargetCache[sourceFile] }
    }
    
    /// Get all source files for a target
    public func getSourceFiles(for target: String) -> Set<String> {
        return cacheQueue.sync { targetToSourcesCache[target] ?? Set<String>() }
    }
    
    /// Invalidate cache for a specific source file
    public func invalidateCache(for sourceFile: String) {
        cacheQueue.sync {
            if let target = sourceToTargetCache.removeValue(forKey: sourceFile) {
                targetToSourcesCache[target]?.remove(sourceFile)
                if targetToSourcesCache[target]?.isEmpty == true {
                    targetToSourcesCache.removeValue(forKey: target)
                }
            }
        }
        debug("Invalidated cache for:", sourceFile)
    }
    
    /// Invalidate all caches
    public func invalidateAllCaches() {
        cacheQueue.sync {
            sourceToTargetCache.removeAll()
            targetToSourcesCache.removeAll()
        }
        debug("Invalidated all caches")
    }
    
    /// Get cache statistics
    public func getCacheStats() -> (sourceToTarget: Int, targetToSources: Int) {
        return cacheQueue.sync {
            (sourceToTargetCache.count, targetToSourcesCache.count)
        }
    }
    
    /// Preload cache for a set of source files
    public func preloadCache(for sourceFiles: [String]) async {
        debug("Preloading cache for \(sourceFiles.count) source files")
        
        for sourceFile in sourceFiles {
            // Skip if already cached
            if cacheQueue.sync(execute: { sourceToTargetCache[sourceFile] }) != nil {
                continue
            }
            
            do {
                if let target = try await bazelInterface.findTarget(for: sourceFile) {
                    cacheQueue.sync {
                        sourceToTargetCache[sourceFile] = target
                        var sources = targetToSourcesCache[target] ?? Set<String>()
                        sources.insert(sourceFile)
                        targetToSourcesCache[target] = sources
                    }
                    debug("Preloaded cache for \(sourceFile): \(target)")
                }
            } catch {
                debug("Failed to preload cache for \(sourceFile):", error.localizedDescription)
            }
        }
        
        debug("Cache preloading completed")
    }
}

/// Enhanced file watcher with Bazel target tracking
public class BazelTargetWatcher {
    private let bazelInterface: BazelInterface
    private var targetWatchers: [String: FileWatcher] = [:]
    private let debug: (Any...) -> Void
    
    public init(bazelInterface: BazelInterface, debug: @escaping (Any...) -> Void = { _ in }) {
        self.bazelInterface = bazelInterface
        self.debug = debug
    }
    
    /// Start watching a specific Bazel target
    public func watchTarget(_ target: String, callback: @escaping (String, [String]) -> Void) async {
        debug("Starting to watch Bazel target:", target)
        
        do {
            // Get source files for the target
            let sourceFiles = try await bazelInterface.getSourceFiles(for: target)
            
            // Extract directories to watch
            let directories = Set(sourceFiles.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path })
            
            // Create file watcher for these directories
            let watcher = FileWatcher(roots: Array(directories)) { [weak self] changes, ideProcPath in
                let changedFiles = (changes as! [String]).filter { changedFile in
                    sourceFiles.contains(changedFile)
                }
                
                if !changedFiles.isEmpty {
                    self?.debug("Target \(target) files changed:", changedFiles)
                    callback(target, changedFiles)
                }
            }
            
            targetWatchers[target] = watcher
            debug("Started watching target \(target) with \(sourceFiles.count) source files in \(directories.count) directories")
            
        } catch {
            debug("Failed to watch target \(target):", error.localizedDescription)
        }
    }
    
    /// Stop watching a target
    public func stopWatching(_ target: String) {
        if let watcher = targetWatchers.removeValue(forKey: target) {
            // In a real implementation, you'd stop the watcher here
            debug("Stopped watching target:", target)
        }
    }
    
    /// Stop watching all targets
    public func stopWatchingAll() {
        targetWatchers.removeAll()
        debug("Stopped watching all targets")
    }
    
    /// Get currently watched targets
    public func getWatchedTargets() -> [String] {
        return Array(targetWatchers.keys)
    }
}

/// File change aggregator for batching related changes
public class FileChangeAggregator {
    private var pendingChanges: [String: FileChange] = [:]
    private let aggregationDelay: TimeInterval
    private let queue = DispatchQueue(label: "file.change.aggregator")
    private var timer: Timer?
    
    public var onChangesReady: (([FileChange]) -> Void)?
    
    public init(aggregationDelay: TimeInterval = 0.5) {
        self.aggregationDelay = aggregationDelay
    }
    
    /// Add a file change to the aggregator
    public func addChange(_ change: FileChange) {
        queue.sync {
            pendingChanges[change.path] = change
            
            // Reset timer
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: aggregationDelay, repeats: false) { [weak self] _ in
                self?.flushChanges()
            }
        }
    }
    
    /// Flush all pending changes
    private func flushChanges() {
        queue.sync {
            let changes = Array(pendingChanges.values)
            pendingChanges.removeAll()
            
            if !changes.isEmpty {
                DispatchQueue.main.async {
                    self.onChangesReady?(changes)
                }
            }
        }
    }
    
    /// Get count of pending changes
    public func getPendingCount() -> Int {
        return queue.sync { pendingChanges.count }
    }
}

/// Performance monitoring for file watching
public class FileWatcherPerformanceMonitor {
    private var metrics: [String: TimeInterval] = [:]
    private let queue = DispatchQueue(label: "file.watcher.performance")
    
    public func recordMetric(_ name: String, duration: TimeInterval) {
        queue.sync {
            metrics[name] = duration
        }
    }
    
    public func getMetrics() -> [String: TimeInterval] {
        return queue.sync { metrics }
    }
    
    public func clearMetrics() {
        queue.sync {
            metrics.removeAll()
        }
    }
}