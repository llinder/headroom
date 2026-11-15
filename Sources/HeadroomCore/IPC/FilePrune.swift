import Darwin
import Foundation

public enum FilePrune {
    /// Works through a directory descriptor opened with O_NOFOLLOW, so neither a symlinked directory nor an
    /// entry swapped for a symlink mid-scan can redirect a delete outside the directory.
    public static func pruneOldFiles(in directory: URL, now: Double, maxAge: Double) -> Int {
        var path = directory.path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return 0 }
        guard let dir = fdopendir(fd) else {
            close(fd)
            return 0
        }
        defer { closedir(dir) }
        var deleted = 0
        while let entry = readdir(dir) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                String(decoding: raw.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
            }
            guard name != ".", name != ".." else { continue }
            var st = stat()
            guard fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0, st.st_mode & S_IFMT == S_IFREG,
                Double(st.st_mtimespec.tv_sec) < now - maxAge
            else { continue }
            if unlinkat(fd, name, 0) == 0 { deleted += 1 }
        }
        return deleted
    }
}
