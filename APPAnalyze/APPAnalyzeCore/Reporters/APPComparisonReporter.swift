//
//  APPComparisonReporter.swift
//  APPAnalyzeCore
//

import Foundation
import Darwin

enum ComponentChangeStatus: String, Encodable, Equatable {
    case added
    case removed
    case changed
    case unchanged
}

enum SizeDetailKind: String, Encodable, Equatable {
    case binary
    case resource
    case asset
}

struct SizeIncrement: Encodable, Equatable {
    let baselineSize: Int
    let comparisonSize: Int
    let deltaSize: Int
    let deltaPercent: Double?
}

struct ComponentSizeIncrement: Encodable, Equatable {
    let name: String
    let status: ComponentChangeStatus
    let total: SizeIncrement
    let binary: SizeIncrement
    let resource: SizeIncrement
}

struct SizeDetailIncrement: Encodable, Equatable {
    let module: String
    let container: String
    let name: String
    let kind: SizeDetailKind
    let status: ComponentChangeStatus
    let size: SizeIncrement
}

struct APPSizeComparisonReport: Encodable, Equatable {
    let baselineApp: String
    let comparisonApp: String
    let total: SizeIncrement
    let binary: SizeIncrement
    let resource: SizeIncrement
    let components: [ComponentSizeIncrement]
    let binaryDetails: [SizeDetailIncrement]
    let resourceDetails: [SizeDetailIncrement]
}

struct LinkMapObjectSize: Equatable {
    let module: String
    let container: String
    let name: String
    var size: Int
}

enum LinkMapParserError: LocalizedError {
    case unreadableFile(String)
    case missingObjectFiles(String)
    case architectureMismatch(expected: String, actual: String)

    var errorDescription: String? {
        switch self {
        case .unreadableFile(let path):
            return "无法读取 Link Map：\(path)"
        case .missingObjectFiles(let path):
            return "Link Map 缺少 Object files 或 Symbols 段：\(path)"
        case .architectureMismatch(let expected, let actual):
            return "Link Map 架构为 \(actual)，与 --arch \(expected) 不一致"
        }
    }
}

enum LinkMapParser {
    static func parse(path: String, appName: String, expectedArch: String) throws -> [LinkMapObjectSize] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            throw LinkMapParserError.unreadableFile(path)
        }
        // 部分链接产物的对象文件路径包含非 UTF-8 字节。Link Map 的结构字段均为
        // ASCII，容错解码只会替换异常的文件名字符，不影响索引及尺寸解析。
        let content = String(decoding: data, as: UTF8.self)
        return try parse(content: content, source: path, appName: appName, expectedArch: expectedArch)
    }

    static func parse(
        content: String,
        source: String = "Link Map",
        appName: String,
        expectedArch: String
    ) throws -> [LinkMapObjectSize] {
        var objectPaths: [Int: String] = [:]
        var objectSizes: [Int: Int] = [:]
        var inObjectFiles = false
        var inSymbols = false
        var foundObjectFiles = false
        var foundSymbols = false

        for rawLine in content.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("# Arch:") {
                let actualArch = String(line.dropFirst("# Arch:".count)).trimmingCharacters(in: .whitespaces)
                if !actualArch.isEmpty, actualArch != expectedArch {
                    throw LinkMapParserError.architectureMismatch(expected: expectedArch, actual: actualArch)
                }
                continue
            }
            if line == "# Object files:" {
                inObjectFiles = true
                inSymbols = false
                foundObjectFiles = true
                continue
            }
            if line == "# Symbols:" {
                inObjectFiles = false
                inSymbols = true
                foundSymbols = true
                continue
            }
            if line.hasPrefix("# Dead Stripped Symbols:") {
                inSymbols = false
                continue
            }
            if line.hasPrefix("#") {
                // Link Map 在 Object files/Symbols 标题后紧跟一行以 `#` 开头的列名，
                // 只有新的段标题（以冒号结尾）才结束当前段。
                if line.hasSuffix(":") {
                    inObjectFiles = false
                    inSymbols = false
                }
                continue
            }
            if inObjectFiles, let entry = indexedValue(line) {
                objectPaths[entry.index] = entry.value
            } else if inSymbols, let entry = symbolSize(line) {
                objectSizes[entry.index, default: 0] += entry.size
            }
        }

        guard foundObjectFiles, foundSymbols else {
            throw LinkMapParserError.missingObjectFiles(source)
        }

        var result: [String: LinkMapObjectSize] = [:]
        for (index, size) in objectSizes where size > 0 {
            guard let path = objectPaths[index], path != "linker synthesized" else {
                continue
            }
            let identity = objectIdentity(path: path, appName: appName)
            let key = [identity.module, identity.container, identity.name].joined(separator: "\u{0}")
            if var existing = result[key] {
                existing.size += size
                result[key] = existing
            } else {
                result[key] = LinkMapObjectSize(
                    module: identity.module,
                    container: identity.container,
                    name: identity.name,
                    size: size
                )
            }
        }
        return result.values.sorted {
            if $0.module != $1.module { return $0.module < $1.module }
            if $0.container != $1.container { return $0.container < $1.container }
            return $0.name < $1.name
        }
    }

    private static func indexedValue(_ line: String) -> (index: Int, value: String)? {
        guard line.first == "[", let closingBracket = line.firstIndex(of: "]") else {
            return nil
        }
        let indexText = line[line.index(after: line.startIndex)..<closingBracket]
            .trimmingCharacters(in: .whitespaces)
        guard let index = Int(indexText) else {
            return nil
        }
        let value = line[line.index(after: closingBracket)...].trimmingCharacters(in: .whitespaces)
        return (index, value)
    }

    private static func symbolSize(_ line: String) -> (index: Int, size: Int)? {
        let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard fields.count >= 4,
              let size = Int(fields[1].dropFirst(2), radix: 16),
              let openingBracket = line.firstIndex(of: "["),
              let closingBracket = line[openingBracket...].firstIndex(of: "]") else {
            return nil
        }
        let indexText = line[line.index(after: openingBracket)..<closingBracket]
            .trimmingCharacters(in: .whitespaces)
        guard let index = Int(indexText) else {
            return nil
        }
        return (index, size)
    }

    private static func objectIdentity(path: String, appName: String) -> (module: String, container: String, name: String) {
        if path.last == ")", let openingParenthesis = path.lastIndex(of: "(") {
            let archivePath = String(path[..<openingParenthesis])
            let objectStart = path.index(after: openingParenthesis)
            let objectEnd = path.index(before: path.endIndex)
            let objectName = String(path[objectStart..<objectEnd])
            let archiveURL = URL(fileURLWithPath: archivePath)
            let archiveName = archiveURL.lastPathComponent
            let frameworkURL = archiveURL.deletingLastPathComponent()
            let container = frameworkURL.pathExtension == "framework"
                ? "\(frameworkURL.lastPathComponent)/\(archiveName)"
                : archiveName
            var module = archiveName
            if module.hasPrefix("lib") { module.removeFirst(3) }
            if module.hasSuffix(".a") { module.removeLast(2) }
            if frameworkURL.pathExtension == "framework" {
                module = frameworkURL.deletingPathExtension().lastPathComponent
            }
            let pathParts = archiveURL.pathComponents
            if let buildProductsIndex = pathParts.lastIndex(of: "BuildProductsPath"),
               buildProductsIndex + 2 < pathParts.count {
                let productName = pathParts[buildProductsIndex + 2]
                if productName != archiveName, !productName.hasSuffix(".framework"),
                   !productName.hasSuffix(".a") {
                    module = productName
                }
            }
            return (module.isEmpty ? appName : module, container, objectName)
        }
        return (appName, "", URL(fileURLWithPath: path).lastPathComponent)
    }
}

private struct SizeDetailItem {
    let module: String
    let container: String
    let name: String
    let kind: SizeDetailKind
    var size: Int

    var key: String {
        return [module, container, kind.rawValue, name].joined(separator: "\u{0}")
    }
}

private struct PackageFile {
    let path: String
    let size: Int
    let isBinary: Bool
    let assetImages: [IbiuComponentSizeResourceAsset]

    var bundleName: String {
        path.split(separator: "/").first(where: { $0.hasSuffix(".bundle") }).map(String.init) ?? MainBundleName
    }
}

private enum PackageSizeError: LocalizedError {
    case invalidApp(String)
    case unreadableFile(String)

    var errorDescription: String? {
        switch self {
        case .invalidApp(let path): return "APP 目录不存在或无法读取：\(path)"
        case .unreadableFile(let path): return "无法读取 APP 文件：\(path)"
        }
    }
}

enum APPComparisonReporter {
    /// 对比模式以 APP 内每个文件的实际字节数为准；符号和素材分析只用于明细。
    static func packageSize(appPath: String) throws -> AppPackageSize {
        let appURL = URL(fileURLWithPath: appPath).resolvingSymlinksInPath().standardizedFileURL
        let appName = appURL.deletingPathExtension().lastPathComponent
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: appURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw PackageSizeError.invalidApp(appPath)
        }

        var enumerationError: Error?
        guard let enumerator = fileManager.enumerator(
            at: appURL,
            includingPropertiesForKeys: nil,
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw PackageSizeError.invalidApp(appPath)
        }

        var filesByModule: [String: [PackageFile]] = [:]
        for case let url as URL in enumerator {
            var fileStatus = stat()
            guard lstat(url.path, &fileStatus) == 0 else {
                throw PackageSizeError.unreadableFile(url.path)
            }
            let fileType = fileStatus.st_mode & mode_t(S_IFMT)
            guard fileType == mode_t(S_IFREG) || fileType == mode_t(S_IFLNK) else {
                continue
            }
            let relativePath = url.pathComponents.suffix(enumerator.level).joined(separator: "/")
            let parts = relativePath.split(separator: "/").map(String.init)
            let module = moduleName(for: parts, appName: appName)
            let isBinary: Bool
            if fileType == mode_t(S_IFREG) {
                isBinary = try isMachO(at: url)
            } else {
                isBinary = false
            }
            let assetImages: [IbiuComponentSizeResourceAsset]
            if !isBinary, url.lastPathComponent == "Assets.car", try isAssetCatalog(at: url) {
                let (imageSets, _) = AssetsCarTool.parseAssets(path: url.path)
                assetImages = imageSets.map {
                    IbiuComponentSizeResourceAsset(name: $0.name, size: $0.size)
                }.sorted { $0.name < $1.name }
            } else {
                assetImages = []
            }
            filesByModule[module, default: []].append(PackageFile(
                path: relativePath,
                size: Int(fileStatus.st_size),
                isBinary: isBinary,
                assetImages: assetImages
            ))
        }
        if let enumerationError {
            throw enumerationError
        }

        var totalBinary = 0
        var totalResource = 0
        var components: [ModulePackageSize] = []
        for (name, files) in filesByModule {
            let component = componentSize(name: name, files: files)
            components.append(component)
            totalBinary += component.size - component.resource.size
            totalResource += component.resource.size
        }
        components.sort { $0.size == $1.size ? $0.name < $1.name : $0.size > $1.size }

        return AppPackageSize(
            allSize: totalBinary + totalResource,
            binarySize: totalBinary,
            resourceSize: totalResource,
            components: components
        )
    }

    private static func componentSize(name: String, files: [PackageFile]) -> ModulePackageSize {
        var libraries: [MobuleLibrarySize] = []
        var resourceFilesByBundle: [String: [IbiuComponentSizeResourceFile]] = [:]
        var assetCatalogs: [IbiuComponentSizeResourceBundle] = []
        for file in files {
            if file.isBinary {
                libraries.append(MobuleLibrarySize(name: file.path, size: file.size, files: [], frameworks: []))
            } else {
                resourceFilesByBundle[file.bundleName, default: []].append(
                    IbiuComponentSizeResourceFile(name: file.path, size: file.size)
                )
                if !file.assetImages.isEmpty {
                    assetCatalogs.append(IbiuComponentSizeResourceBundle(
                        name: file.path,
                        size: 0,
                        files: [],
                        assets: file.assetImages
                    ))
                }
            }
        }
        libraries.sort { $0.name < $1.name }
        let binarySize = libraries.reduce(0) { $0 + $1.size }
        var bundles: [IbiuComponentSizeResourceBundle] = []
        for (bundleName, var resourceFiles) in resourceFilesByBundle {
            resourceFiles.sort { $0.name < $1.name }
            let size = resourceFiles.reduce(0) { $0 + $1.size }
            bundles.append(IbiuComponentSizeResourceBundle(
                name: bundleName,
                size: size,
                files: resourceFiles,
                assets: []
            ))
        }
        bundles.append(contentsOf: assetCatalogs)
        bundles.sort { $0.name < $1.name }
        let resourceSize = bundles.reduce(0) { $0 + $1.size }
        return ModulePackageSize(
            name: name,
            version: nil,
            size: binarySize + resourceSize,
            libraries: libraries,
            resource: ModuleResourceSize(bundles: bundles, size: resourceSize)
        )
    }

    private static func moduleName(for parts: [String], appName: String) -> String {
        guard parts.count > 1 else { return appName }
        if parts[0] == "Frameworks" {
            if parts[1].hasSuffix(".framework") {
                return String(parts[1].dropLast(".framework".count))
            }
            if parts[1].hasSuffix(".dylib") {
                return parts[1]
            }
        }
        if ["PlugIns", "Watch", "AppClips"].contains(parts[0]) {
            return "\(parts[0])/\(parts[1])"
        }
        return appName
    }

    private static func isMachO(at url: URL) throws -> Bool {
        guard let handle = FileHandle(forReadingAtPath: url.path) else {
            throw PackageSizeError.unreadableFile(url.path)
        }
        defer { handle.closeFile() }
        let magic = [UInt8](handle.readData(ofLength: 4))
        return magic == [0xfe, 0xed, 0xfa, 0xce]
            || magic == [0xce, 0xfa, 0xed, 0xfe]
            || magic == [0xfe, 0xed, 0xfa, 0xcf]
            || magic == [0xcf, 0xfa, 0xed, 0xfe]
            || magic == [0xca, 0xfe, 0xba, 0xbe]
            || magic == [0xbe, 0xba, 0xfe, 0xca]
            || magic == [0xca, 0xfe, 0xba, 0xbf]
            || magic == [0xbf, 0xba, 0xfe, 0xca]
    }

    private static func isAssetCatalog(at url: URL) throws -> Bool {
        guard let handle = FileHandle(forReadingAtPath: url.path) else {
            throw PackageSizeError.unreadableFile(url.path)
        }
        defer { handle.closeFile() }
        return handle.readData(ofLength: 8) == Data("BOMStore".utf8)
    }

    static func compare(
        baseline: AppPackageSize,
        comparison: AppPackageSize,
        baselineApp: String,
        comparisonApp: String,
        baselineLinkMap: [LinkMapObjectSize]? = nil,
        comparisonLinkMap: [LinkMapObjectSize]? = nil,
        incrementThreshold: Int = 100
    ) -> APPSizeComparisonReport {
        let incrementThreshold = max(0, incrementThreshold)
        let baselineComponents = Dictionary(
            baseline.components.map { ($0.name, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let comparisonComponents = Dictionary(
            comparison.components.map { ($0.name, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let componentNames = Set(baselineComponents.keys).union(comparisonComponents.keys)
        var components = componentNames.map { name in
            let baselineComponent = baselineComponents[name]
            let comparisonComponent = comparisonComponents[name]
            let baselineTotal = baselineComponent?.size ?? 0
            let comparisonTotal = comparisonComponent?.size ?? 0
            let baselineResource = baselineComponent?.resource.size ?? 0
            let comparisonResource = comparisonComponent?.resource.size ?? 0
            let status: ComponentChangeStatus
            if baselineComponent == nil {
                status = .added
            } else if comparisonComponent == nil {
                status = .removed
            } else if baselineTotal != comparisonTotal || baselineResource != comparisonResource {
                status = .changed
            } else {
                status = .unchanged
            }
            return ComponentSizeIncrement(
                name: name,
                status: status,
                total: increment(baseline: baselineTotal, comparison: comparisonTotal),
                binary: increment(
                    baseline: baselineTotal - baselineResource,
                    comparison: comparisonTotal - comparisonResource
                ),
                resource: increment(baseline: baselineResource, comparison: comparisonResource)
            )
        }
        .filter { component in
            [component.total.deltaSize, component.binary.deltaSize, component.resource.deltaSize]
                .contains { abs($0) >= incrementThreshold }
        }
        components.sort {
            if $0.total.deltaSize == $1.total.deltaSize {
                return $0.name < $1.name
            }
            return $0.total.deltaSize > $1.total.deltaSize
        }

        return APPSizeComparisonReport(
            baselineApp: baselineApp,
            comparisonApp: comparisonApp,
            total: increment(baseline: baseline.allSize, comparison: comparison.allSize),
            binary: increment(baseline: baseline.binarySize, comparison: comparison.binarySize),
            resource: increment(baseline: baseline.resourceSize, comparison: comparison.resourceSize),
            components: components,
            binaryDetails: compareDetails(
                baseline: binaryDetails(package: baseline, linkMap: baselineLinkMap),
                comparison: binaryDetails(package: comparison, linkMap: comparisonLinkMap),
                incrementThreshold: incrementThreshold
            ),
            resourceDetails: compareDetails(
                baseline: resourceDetails(package: baseline),
                comparison: resourceDetails(package: comparison),
                incrementThreshold: incrementThreshold
            )
        )
    }

    static func generateReport(_ report: APPSizeComparisonReport) {
        APPAnalyze.shared.reporterManager.generateReport(data: report.data, fileName: "comparison.json")
        let data = try! JSONEncoder().encode(report)
        let json = String(data: data, encoding: .utf8)!
        let html = """
        <!doctype html>
        <html><head><meta charset="utf-8"/><meta name="viewport" content="width=device-width,initial-scale=1.0"/>
        <title>APP 包体积增量</title>
        <style>
        body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;margin:28px;color:#222}
        table{border-collapse:collapse;width:100%;margin:12px 0 28px}th,td{border:1px solid #ddd;padding:8px 10px;text-align:right}
        th{background:#f6f7f8}.left{text-align:left}.positive{color:#c62828}.negative{color:#188038}.zero{color:#666}
        .tag{display:inline-block;padding:4px 12px;border-radius:999px;font-size:12px;font-weight:600;white-space:nowrap}
        .tag.changed{background:#fff4d6;color:#946200}.tag.added{background:#e5f6ec;color:#137333}
        .tag.removed{background:#fdecea;color:#b3261e}.tag.unchanged{background:#f1f3f4;color:#5f6368}
        .empty{color:#777;padding:12px 0}
        .app-paths{white-space:pre-line;line-height:1.7}
        </style>
        <script>
        const report=\(json);
        const statuses={added:'新增',removed:'删除',changed:'变化',unchanged:'未变化'};
        const kinds={binary:'二进制',resource:'文件',asset:'ImageSet'};
        function size(value,signed=false){const sign=value<0?'-':(signed&&value>0?'+':'');let n=Math.abs(value);if(n<1000)return sign+n+'B';n=n/1000;if(n<1000)return sign+n.toFixed(1)+'KB';return sign+(n/1000).toFixed(2)+'MB'}
        function percent(item){if(item.deltaPercent===null||item.deltaPercent===undefined)return'-';const sign=item.deltaPercent>0?'+':'';return sign+item.deltaPercent.toFixed(2)+'%'}
        function cls(value){return value>0?'positive':value<0?'negative':'zero'}
        function summaryRow(name,item){return `<tr><td class="left">${name}</td><td>${size(item.baselineSize)}</td><td>${size(item.comparisonSize)}</td><td class="${cls(item.deltaSize)}">${size(item.deltaSize,true)}</td><td class="${cls(item.deltaSize)}">${percent(item)}</td></tr>`}
        function detailRows(items,showContainer){if(items.length===0)return `<tr><td colspan="${showContainer?9:8}" class="empty">无增量明细</td></tr>`;return items.map((item,index)=>`<tr><td>${index+1}</td><td class="left">${item.module}</td>${showContainer?`<td class="left">${item.container||'-'}</td>`:''}<td class="left">${item.name}</td><td>${kinds[item.kind]}</td><td><span class="tag ${item.status}">${statuses[item.status]}</span></td><td>${size(item.size.baselineSize)}</td><td>${size(item.size.comparisonSize)}</td><td class="${cls(item.size.deltaSize)}">${size(item.size.deltaSize,true)} (${percent(item.size)})</td></tr>`).join('')}
        function onLoad(){document.getElementById('apps').textContent='基线 APP：'+report.baselineApp+'\\n对比 APP：'+report.comparisonApp;document.getElementById('summary').innerHTML=summaryRow('总大小',report.total)+summaryRow('二进制',report.binary)+summaryRow('资源',report.resource);document.getElementById('components').innerHTML=report.components.map((item,index)=>`<tr><td>${index+1}</td><td class="left">${item.name}</td><td><span class="tag ${item.status}">${statuses[item.status]}</span></td><td>${size(item.total.baselineSize)}</td><td>${size(item.total.comparisonSize)}</td><td class="${cls(item.total.deltaSize)}">${size(item.total.deltaSize,true)}</td><td class="${cls(item.binary.deltaSize)}">${size(item.binary.deltaSize,true)}</td><td class="${cls(item.resource.deltaSize)}">${size(item.resource.deltaSize,true)}</td><td>${percent(item.total)}</td></tr>`).join('');document.getElementById('binaryDetails').innerHTML=detailRows(report.binaryDetails,false);document.getElementById('resourceDetails').innerHTML=detailRows(report.resourceDetails,true)}
        </script></head>
        <body onload="onLoad()"><h1>APP 包体积增量报告</h1><p id="apps" class="app-paths"></p>
        <h2>总体变化</h2><table><thead><tr><th class="left">类型</th><th>基线</th><th>对比</th><th>增量</th><th>增幅</th></tr></thead><tbody id="summary"></tbody></table>
        <h2>模块变化</h2><table><thead><tr><th>#</th><th class="left">模块</th><th>状态</th><th>基线大小</th><th>对比大小</th><th>总增量</th><th>二进制增量</th><th>资源增量</th><th>增幅</th></tr></thead><tbody id="components"></tbody></table>
        <h2>二进制增量明细</h2><table><thead><tr><th>#</th><th class="left">模块</th><th class="left">文件</th><th>类型</th><th>状态</th><th>基线大小</th><th>对比大小</th><th>增量</th></tr></thead><tbody id="binaryDetails"></tbody></table>
        <h2>资源增量明细</h2><p>ImageSet 是 Assets.car 内图片的展开明细，与 Assets.car 文件增量不可叠加。</p><table><thead><tr><th>#</th><th class="left">模块</th><th class="left">Bundle</th><th class="left">资源</th><th>类型</th><th>状态</th><th>基线大小</th><th>对比大小</th><th>增量</th></tr></thead><tbody id="resourceDetails"></tbody></table>
        </body></html>
        """
        APPAnalyze.shared.reporterManager.generateReport(text: html, fileName: "comparison.html")
    }

    private static func binaryDetails(
        package: AppPackageSize,
        linkMap: [LinkMapObjectSize]?
    ) -> [String: SizeDetailItem] {
        var result: [String: SizeDetailItem] = [:]
        var linkMapModules: Set<String> = []
        if let linkMap {
            for object in linkMap {
                if object.container.isEmpty {
                    linkMapModules.insert(object.module)
                }
                insert(
                    SizeDetailItem(
                        module: object.module,
                        container: object.container,
                        name: object.name,
                        kind: .binary,
                        size: object.size
                    ),
                    into: &result
                )
            }
        }
        for component in package.components where !linkMapModules.contains(component.name) {
            for library in component.libraries {
                if library.files.isEmpty, library.frameworks.isEmpty {
                    insert(
                        SizeDetailItem(module: component.name, container: "", name: library.name, kind: .binary, size: library.size),
                        into: &result
                    )
                }
                for file in library.files {
                    insert(
                        SizeDetailItem(module: component.name, container: library.name, name: file.name, kind: .binary, size: file.size),
                        into: &result
                    )
                }
                for framework in library.frameworks {
                    insert(
                        SizeDetailItem(module: component.name, container: library.name, name: framework.name, kind: .binary, size: framework.size),
                        into: &result
                    )
                }
            }
        }
        return result
    }

    private static func resourceDetails(package: AppPackageSize) -> [String: SizeDetailItem] {
        var result: [String: SizeDetailItem] = [:]
        for component in package.components {
            for bundle in component.resource.bundles {
                for file in bundle.files {
                    insert(
                        SizeDetailItem(module: component.name, container: bundle.name, name: file.name, kind: .resource, size: file.size),
                        into: &result
                    )
                }
                for asset in bundle.assets {
                    insert(
                        SizeDetailItem(module: component.name, container: bundle.name, name: asset.name, kind: .asset, size: asset.size),
                        into: &result
                    )
                }
            }
        }
        return result
    }

    private static func insert(_ item: SizeDetailItem, into result: inout [String: SizeDetailItem]) {
        if var existing = result[item.key] {
            existing.size += item.size
            result[item.key] = existing
        } else {
            result[item.key] = item
        }
    }

    private static func compareDetails(
        baseline: [String: SizeDetailItem],
        comparison: [String: SizeDetailItem],
        incrementThreshold: Int
    ) -> [SizeDetailIncrement] {
        let keys = Set(baseline.keys).union(comparison.keys)
        var details = keys.compactMap { key -> SizeDetailIncrement? in
            let baselineItem = baseline[key]
            let comparisonItem = comparison[key]
            let baselineSize = baselineItem?.size ?? 0
            let comparisonSize = comparisonItem?.size ?? 0
            let deltaSize = comparisonSize - baselineSize
            guard deltaSize != 0, abs(deltaSize) >= incrementThreshold else {
                return nil
            }
            let item = comparisonItem ?? baselineItem!
            let status: ComponentChangeStatus
            if baselineItem == nil {
                status = .added
            } else if comparisonItem == nil {
                status = .removed
            } else {
                status = .changed
            }
            return SizeDetailIncrement(
                module: item.module,
                container: item.container,
                name: item.name,
                kind: item.kind,
                status: status,
                size: increment(baseline: baselineSize, comparison: comparisonSize)
            )
        }
        details.sort {
            if $0.size.deltaSize != $1.size.deltaSize {
                return $0.size.deltaSize > $1.size.deltaSize
            }
            if $0.module != $1.module {
                return $0.module < $1.module
            }
            if $0.container != $1.container {
                return $0.container < $1.container
            }
            return $0.name < $1.name
        }
        return details
    }

    private static func increment(baseline: Int, comparison: Int) -> SizeIncrement {
        let delta = comparison - baseline
        let percent = baseline == 0 ? nil : Double(delta) / Double(baseline) * 100
        return SizeIncrement(
            baselineSize: baseline,
            comparisonSize: comparison,
            deltaSize: delta,
            deltaPercent: percent
        )
    }
}
