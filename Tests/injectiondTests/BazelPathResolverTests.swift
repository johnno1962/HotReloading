//
//  BazelPathResolverTests.swift
//  InjectionIII
//
//  Created by Karim Alweheshy on 20/07/2025.
//  Copyright © 2025 John Holdsworth. All rights reserved.
//
//  Unit tests for BazelPathResolver functionality
//

import XCTest
import Foundation
@testable import injectiond

class BazelPathResolverTests: XCTestCase {
    var tempWorkspaceURL: URL!
    var pathResolver: BazelPathResolver!
    
    override func setUp() async throws {
        try await super.setUp()
        
        // Create temporary workspace
        tempWorkspaceURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("BazelPathResolverTests_\(UUID().uuidString)")
        
        try FileManager.default.createDirectory(at: tempWorkspaceURL, 
                                               withIntermediateDirectories: true)
        
        pathResolver = BazelPathResolver(workspaceRoot: tempWorkspaceURL, debug: { print($0) })
    }
    
    override func tearDown() async throws {
        try await super.tearDown()
        
        // Clean up temporary workspace
        if FileManager.default.fileExists(atPath: tempWorkspaceURL.path) {
            try FileManager.default.removeItem(at: tempWorkspaceURL)
        }
    }
    
    // MARK: - Test Helpers
    
    /// Create a BUILD file at the given path relative to workspace root
    private func createBuildFile(at relativePath: String, content: String = "# BUILD file") throws {
        let buildFileURL = tempWorkspaceURL.appendingPathComponent(relativePath)
        let buildDir = buildFileURL.deletingLastPathComponent()
        
        try FileManager.default.createDirectory(at: buildDir, withIntermediateDirectories: true)
        try content.write(to: buildFileURL, atomically: true, encoding: .utf8)
    }
    
    /// Create a source file at the given path relative to workspace root
    private func createSourceFile(at relativePath: String, content: String = "// Source file") throws {
        let sourceFileURL = tempWorkspaceURL.appendingPathComponent(relativePath)
        let sourceDir = sourceFileURL.deletingLastPathComponent()
        
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try content.write(to: sourceFileURL, atomically: true, encoding: .utf8)
    }
    
    // MARK: - Path to Label Conversion Tests
    
    func testSimpleFileToLabel() async throws {
        // Setup: Create root BUILD file and source file
        try createBuildFile(at: "BUILD")
        try createSourceFile(at: "main.swift")
        
        await pathResolver.discoverBuildFiles()
        
        // Test: workspace/main.swift -> //:main.swift
        let filePath = tempWorkspaceURL.appendingPathComponent("main.swift").path
        let label = try pathResolver.convertToLabel(filePath)
        
        XCTAssertEqual(label, "//:main.swift")
    }
    
    func testNestedPackageFileToLabel() async throws {
        // Setup: Create nested BUILD files
        try createBuildFile(at: "a/BUILD")
        try createBuildFile(at: "a/b/BUILD")
        try createSourceFile(at: "a/b/c/file.swift")
        
        await pathResolver.discoverBuildFiles()
        
        // Test: workspace/a/b/c/file.swift with BUILD at a/b -> //a/b:c/file.swift
        let filePath = tempWorkspaceURL.appendingPathComponent("a/b/c/file.swift").path
        let label = try pathResolver.convertToLabel(filePath)
        
        XCTAssertEqual(label, "//a/b:c/file.swift")
    }
    
    func testDirectoryWithBuildFile() async throws {
        // Setup: Create BUILD files in nested structure
        try createBuildFile(at: "src/BUILD")
        try createSourceFile(at: "src/main.swift")
        
        await pathResolver.discoverBuildFiles()
        
        // Test: workspace/src/main.swift -> //src:main.swift
        let filePath = tempWorkspaceURL.appendingPathComponent("src/main.swift").path
        let label = try pathResolver.convertToLabel(filePath)
        
        XCTAssertEqual(label, "//src:main.swift")
    }
    
    func testDeepNestedStructure() async throws {
        // Setup: Create complex nested structure
        try createBuildFile(at: "BUILD")
        try createBuildFile(at: "a/BUILD")
        try createBuildFile(at: "a/b/c/BUILD")
        try createSourceFile(at: "a/b/c/d/e/file.swift")
        
        await pathResolver.discoverBuildFiles()
        
        // Test: File should belong to nearest BUILD file at a/b/c
        let filePath = tempWorkspaceURL.appendingPathComponent("a/b/c/d/e/file.swift").path
        let label = try pathResolver.convertToLabel(filePath)
        
        XCTAssertEqual(label, "//a/b/c:d/e/file.swift")
    }
    
    func testBuildBazelFileSupport() async throws {
        // Setup: Use BUILD.bazel instead of BUILD
        try createBuildFile(at: "BUILD.bazel")
        try createBuildFile(at: "src/BUILD.bazel")
        try createSourceFile(at: "src/module/file.swift")
        
        await pathResolver.discoverBuildFiles()
        
        // Test: Should work with BUILD.bazel files
        let filePath = tempWorkspaceURL.appendingPathComponent("src/module/file.swift").path
        let label = try pathResolver.convertToLabel(filePath)
        
        XCTAssertEqual(label, "//src:module/file.swift")
    }
    
    // MARK: - Package Discovery Tests
    
    func testFindPackageForRootFile() async throws {
        try createBuildFile(at: "BUILD")
        try createSourceFile(at: "main.swift")
        
        await pathResolver.discoverBuildFiles()
        
        let filePath = tempWorkspaceURL.appendingPathComponent("main.swift").path
        let package = try pathResolver.findPackage(for: filePath)
        
        XCTAssertEqual(package, "")
    }
    
    func testFindPackageForNestedFile() async throws {
        try createBuildFile(at: "a/b/BUILD")
        try createSourceFile(at: "a/b/c/file.swift")
        
        await pathResolver.discoverBuildFiles()
        
        let filePath = tempWorkspaceURL.appendingPathComponent("a/b/c/file.swift").path
        let package = try pathResolver.findPackage(for: filePath)
        
        XCTAssertEqual(package, "a/b")
    }
    
    func testPackageCaching() async throws {
        try createBuildFile(at: "src/BUILD")
        try createSourceFile(at: "src/file1.swift")
        try createSourceFile(at: "src/file2.swift")
        
        await pathResolver.discoverBuildFiles()
        
        // First call should discover package
        let filePath1 = tempWorkspaceURL.appendingPathComponent("src/file1.swift").path
        let package1 = try pathResolver.findPackage(for: filePath1)
        
        // Second call for same package should use cache
        let filePath2 = tempWorkspaceURL.appendingPathComponent("src/file2.swift").path
        let package2 = try pathResolver.findPackage(for: filePath2)
        
        XCTAssertEqual(package1, "src")
        XCTAssertEqual(package2, "src")
    }
    
    // MARK: - Error Handling Tests
    
    func testFileNotInWorkspace() async throws {
        try createBuildFile(at: "BUILD")
        
        await pathResolver.discoverBuildFiles()
        
        // Test with file outside workspace
        let outsideFile = "/tmp/outside.swift"
        
        XCTAssertThrowsError(try pathResolver.convertToLabel(outsideFile)) { error in
            guard case BazelPathError.fileNotInWorkspace = error else {
                XCTFail("Expected fileNotInWorkspace error, got \(error)")
                return
            }
        }
    }
    
    func testNoBuildFileFound() async throws {
        // Create source file but no BUILD file
        try createSourceFile(at: "src/file.swift")
        
        await pathResolver.discoverBuildFiles()
        
        let filePath = tempWorkspaceURL.appendingPathComponent("src/file.swift").path
        
        XCTAssertThrowsError(try pathResolver.findPackage(for: filePath)) { error in
            guard case BazelPathError.buildFileNotFound = error else {
                XCTFail("Expected buildFileNotFound error, got \(error)")
                return
            }
        }
    }
    
    // MARK: - File Target Detection Tests
    
    func testIsFileTarget() async throws {
        try createSourceFile(at: "src/file.swift")
        try FileManager.default.createDirectory(at: tempWorkspaceURL.appendingPathComponent("src/dir"), 
                                               withIntermediateDirectories: true)
        
        let filePath = tempWorkspaceURL.appendingPathComponent("src/file.swift").path
        let dirPath = tempWorkspaceURL.appendingPathComponent("src/dir").path
        
        XCTAssertTrue(try pathResolver.isFileTarget(filePath))
        XCTAssertFalse(try pathResolver.isFileTarget(dirPath))
    }
    
    // MARK: - Relative Path Tests
    
    func testGetRelativePath() {
        let absolutePath = tempWorkspaceURL.appendingPathComponent("src/file.swift").path
        let relativePath = pathResolver.getRelativePath(absolutePath)
        
        XCTAssertEqual(relativePath, "src/file.swift")
    }
    
    func testGetRelativePathForWorkspaceRoot() {
        let relativePath = pathResolver.getRelativePath(tempWorkspaceURL.path)
        
        XCTAssertEqual(relativePath, "")
    }
    
    // MARK: - Cache Management Tests
    
    func testCacheInvalidation() async throws {
        try createBuildFile(at: "src/BUILD")
        try createSourceFile(at: "src/file.swift")
        
        await pathResolver.discoverBuildFiles()
        
        // First access should cache the package
        let filePath = tempWorkspaceURL.appendingPathComponent("src/file.swift").path
        _ = try pathResolver.findPackage(for: filePath)
        
        // Invalidate cache for BUILD file change
        let buildFilePath = tempWorkspaceURL.appendingPathComponent("src/BUILD").path
        pathResolver.invalidateCache(for: [buildFilePath])
        
        // Should still work after cache invalidation
        let package = try pathResolver.findPackage(for: filePath)
        XCTAssertEqual(package, "src")
    }
    
    func testClearCache() async throws {
        try createBuildFile(at: "src/BUILD")
        try createSourceFile(at: "src/file.swift")
        
        await pathResolver.discoverBuildFiles()
        
        // Access to populate cache
        let filePath = tempWorkspaceURL.appendingPathComponent("src/file.swift").path
        _ = try pathResolver.findPackage(for: filePath)
        
        // Clear cache
        pathResolver.clearCache()
        
        // Should still work after clearing cache
        let package = try pathResolver.findPackage(for: filePath)
        XCTAssertEqual(package, "src")
    }
    
    // MARK: - BUILD File Discovery Tests
    
    func testDiscoverBuildFiles() async throws {
        // Create multiple BUILD files
        try createBuildFile(at: "BUILD")
        try createBuildFile(at: "a/BUILD")
        try createBuildFile(at: "a/b/BUILD.bazel")
        try createBuildFile(at: "c/d/e/BUILD")
        
        await pathResolver.discoverBuildFiles()
        
        // Test that packages are correctly identified
        let testCases = [
            ("main.swift", ""),
            ("a/file.swift", "a"),
            ("a/b/file.swift", "a/b"),
            ("c/d/e/file.swift", "c/d/e")
        ]
        
        for (filePath, expectedPackage) in testCases {
            try createSourceFile(at: filePath)
            let fullPath = tempWorkspaceURL.appendingPathComponent(filePath).path
            let package = try pathResolver.findPackage(for: fullPath)
            XCTAssertEqual(package, expectedPackage, "Failed for file: \(filePath)")
        }
    }
    
    // MARK: - Edge Cases
    
    func testMultipleBuildFilesInHierarchy() async throws {
        // Create BUILD files at multiple levels
        try createBuildFile(at: "BUILD")
        try createBuildFile(at: "a/BUILD")
        try createBuildFile(at: "a/b/BUILD")
        try createSourceFile(at: "a/b/c/file.swift")
        
        await pathResolver.discoverBuildFiles()
        
        // Should pick the nearest BUILD file (a/b/BUILD)
        let filePath = tempWorkspaceURL.appendingPathComponent("a/b/c/file.swift").path
        let package = try pathResolver.findPackage(for: filePath)
        
        XCTAssertEqual(package, "a/b")
    }
    
    func testSpecialCharactersInPath() async throws {
        // Create paths with special characters
        try createBuildFile(at: "test-module/BUILD")
        try createSourceFile(at: "test-module/special_file-name.swift")
        
        await pathResolver.discoverBuildFiles()
        
        let filePath = tempWorkspaceURL.appendingPathComponent("test-module/special_file-name.swift").path
        let label = try pathResolver.convertToLabel(filePath)
        
        XCTAssertEqual(label, "//test-module:special_file-name.swift")
    }
}