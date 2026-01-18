import Foundation
import Combine
import AppKit

enum CoreDownloadError: Error {
    case networkError(Error)
    case invalidResponse
    case assetNotFound
    case unzipFailed
    case fileSystemError(Error)
}

final class CoreDownloader: ObservableObject {
    static let shared = CoreDownloader()
    
    @Published var downloadProgress: Double = 0
    @Published var isDownloading = false
    @Published var statusMessage = ""
    @Published var isInstalled = false
    @Published var currentVersion: String?
    
    private init() {
        checkInstallation()
    }
    
    private let repoOwner = "EasyTier"
    private let repoName = "EasyTier"
    
    var installDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Swiftier/bin")
    }
    
    var corePath: String {
        return installDirectory.appendingPathComponent("easytier-core").path
    }
    
    var cliPath: String {
        return installDirectory.appendingPathComponent("easytier-cli").path
    }
    
    func checkInstallation() {
        let exists = FileManager.default.fileExists(atPath: corePath) && FileManager.default.isExecutableFile(atPath: corePath)
        
        if isInstalled != exists {
            DispatchQueue.main.async {
                self.isInstalled = exists
            }
        }
        
        if exists {
            Task {
                let v = await fetchCurrentVersion()
                await MainActor.run { self.currentVersion = v }
            }
        } else {
            DispatchQueue.main.async { self.currentVersion = nil }
        }
    }
    
    
    func installCore(useBeta: Bool = false, useProxy: Bool = true) async throws {
        await MainActor.run {
            self.isDownloading = true
            self.downloadProgress = 0
            self.statusMessage = "正在检查更新 (" + (useBeta ? "Beta" : "Stable") + ")..."
        }
        
        defer {
            Task { @MainActor in self.isDownloading = false }
        }
        
        // 1. Get Release
        let release = try await fetchRelease(useBeta: useBeta)
        
        // 2. Find Asset
        let asset = try findAsset(in: release)
        
        // 3. Download
        await MainActor.run { self.statusMessage = "正在下载内核 (v\(release.tag_name))..." }
        var downloadURLString = asset.browser_download_url
        if useProxy {
             downloadURLString = "https://ghfast.top/" + downloadURLString
        }
        let zipURL = try await download(url: URL(string: downloadURLString)!)
        
        // 4. Unzip and Install
        await MainActor.run { self.statusMessage = "正在安装..." }
        try install(from: zipURL)
        
        // 5. Cleanup
        try? FileManager.default.removeItem(at: zipURL)
        
        await MainActor.run { 
            self.statusMessage = "安装完成"
            self.checkInstallation()
        }
    }
    
    
    private func fetchCurrentVersion() async -> String? {
        guard FileManager.default.fileExists(atPath: corePath) else { return nil }
        
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: self.corePath)
                process.arguments = ["--version"]
                
                let pipe = Pipe()
                process.standardOutput = pipe
                
                do {
                    try process.run()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    
                    if let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) {
                        let components = output.components(separatedBy: " ")
                        if components.count >= 2 {
                            continuation.resume(returning: components[1])
                            return
                        }
                        continuation.resume(returning: output)
                        return
                    }
                } catch {
                     // ignore
                }
                continuation.resume(returning: nil)
            }
        }
    }
    
    // Returns (NewVersion, ReleaseNote) if update available
    func checkForUpdate(useBeta: Bool = false) async throws -> (String, String)? {
        let release = try await fetchRelease(useBeta: useBeta)
        let remoteVersion = release.tag_name.replacingOccurrences(of: "v", with: "")
        
        guard let current = currentVersion else {
            return (release.tag_name, release.body ?? "")
        }
        
        // Simple string comparison (for now) or you can import a SemVer lib
        // Assuming tag is v1.2.3 and current is 1.2.3
        if current.contains(remoteVersion) || remoteVersion.contains(current) {
            return nil
        }
        
        // If different, assume update. Logically should check greater than.
        // But for "Check Update", if strings differ, we return it.
        if current != remoteVersion {
             return (release.tag_name, release.body ?? "")
        }
        return nil
    }

    private struct Release: Decodable {
        let tag_name: String
        let assets: [Asset]
        let body: String?
        let prerelease: Bool?
    }
    
    private struct Asset: Decodable {
        let name: String
        let browser_download_url: String
    }
    
    private func fetchRelease(useBeta: Bool) async throws -> Release {
        if !useBeta {
            let url = URL(string: "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest")!
            let (data, _) = try await URLSession.shared.data(from: url)
            return try JSONDecoder().decode(Release.self, from: data)
        } else {
             // List releases and pick first one (which is newest, including pre-release)
             let url = URL(string: "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases?per_page=1")!
             let (data, _) = try await URLSession.shared.data(from: url)
             let releases = try JSONDecoder().decode([Release].self, from: data)
             guard let first = releases.first else {
                 throw CoreDownloadError.assetNotFound
             }
             return first
        }
    }
    
    private func findAsset(in release: Release) throws -> Asset {
        // Architecture detection
        let arch: String
        #if arch(arm64)
        arch = "aarch64"
        #elseif arch(x86_64)
        arch = "x86_64" // GitHub usually uses x86_64 or amd64
        #endif
        
        // Expected naming: easytier-macos-x86_64-v1.2.3.zip or similar
        // Keywords: "macos" (or "darwin"), arch, and "zip"
        // Avoid "dmg" (GUI)
        
        let keyword1 = "macos"
        let keyword2 = arch
        let exclude = "dmg" 
        
        if let asset = release.assets.first(where: {
            let name = $0.name.lowercased()
            return name.contains(keyword1) && name.contains(keyword2) && !name.contains(exclude) && name.hasSuffix(".zip")
        }) {
            return asset
        }
        
        // Fallback or Strict Check
        throw CoreDownloadError.assetNotFound
    }
    
    private func download(url: URL) async throws -> URL {
        let (localURL, _) = try await URLSession.shared.download(from: url)
        // Move to temporary location with correct extension for unzipping
        let tmpDir = FileManager.default.temporaryDirectory
        let dstURL = tmpDir.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: dstURL)
        try FileManager.default.moveItem(at: localURL, to: dstURL)
        return dstURL
    }
    
    private func install(from zipURL: URL) throws {
        // Unzip logic. macOS has built-in ArchiveUtility but no Swift API. Use `unzip` command.
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("easytier_extracted_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-o", "-q", zipURL.path, "-d", tmpDir.path] // Added -q for quiet
        
        // Silence output
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        
        try process.run()
        process.waitUntilExit()
        
        if process.terminationStatus != 0 {
            throw CoreDownloadError.unzipFailed
        }
        
        // Prepare Install Dir
        try? FileManager.default.createDirectory(at: installDirectory, withIntermediateDirectories: true)
        
        // Move binaries
        // The zip structure might be `easytier-macos.../easytier-core` or flat.
        // Recursive search for `easytier-core`
        let enumerator = FileManager.default.enumerator(at: tmpDir, includingPropertiesForKeys: nil)
        var coreFound = false
        
        while let fileURL = enumerator?.nextObject() as? URL {
            let filename = fileURL.lastPathComponent
            if filename == "easytier-core" || filename == "easytier-cli" {
                let dst = installDirectory.appendingPathComponent(filename)
                try? FileManager.default.removeItem(at: dst)
                try FileManager.default.moveItem(at: fileURL, to: dst)
                
                // chmod +x
                let attributes = try FileManager.default.attributesOfItem(atPath: dst.path)
                var permissions = (attributes[.posixPermissions] as? Int) ?? 0o755
                permissions |= 0o100 // Ensure executable
                try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: dst.path)
                
                // Remove Quarantine Attribute
                removeQuarantine(at: dst.path)
                
                if filename == "easytier-core" { coreFound = true }
            }
        }
        
        try? FileManager.default.removeItem(at: tmpDir)
        
        if !coreFound {
            throw CoreDownloadError.fileSystemError(NSError(domain: "CoreNotFound", code: 1, userInfo: nil))
        }
    }
    
    private func removeQuarantine(at path: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        process.arguments = ["-d", "com.apple.quarantine", path]
        
        // Silence output (ignore "No such xattr" errors)
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        
        try? process.run()
        process.waitUntilExit()
    }
}
