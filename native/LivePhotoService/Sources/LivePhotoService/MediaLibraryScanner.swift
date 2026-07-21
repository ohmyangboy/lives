import Foundation

enum MediaLibraryScanner {
    private static let supportedExtensions = Set(["mov", "mp4", "m4v"])

    static func scan(path: String) throws -> [String] {
        let root = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ServiceError(
                code: "SOURCE_FOLDER_UNAVAILABLE",
                message: "无法读取这个文件夹",
                recovery: "请重新选择包含视频的文件夹"
            )
        }

        let keys: [URLResourceKey] = [.isRegularFileKey, .isHiddenKey]
        let options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: options
        )
        var paths: [String] = []
        while let file = enumerator?.nextObject() as? URL {
            guard supportedExtensions.contains(file.pathExtension.lowercased()) else { continue }
            let values = try? file.resourceValues(forKeys: Set(keys))
            if values?.isRegularFile == true { paths.append(file.path) }
        }
        paths.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        return paths
    }
}
