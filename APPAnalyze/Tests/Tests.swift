//
//  Tests.swift
//  Tests
//
//  Created by hexiao on 2023/8/21.
//

import XCTest
@testable import APPAnalyzeCore

final class Tests: XCTestCase {

    func testClassDemangling() throws {
        let a = "s16pgHomePageModule06PGMainC16_5009021_SubCell33_C4CD798CB5F3BA52699FDA71B41D3DB3LLC18walletBenefitLabelSo7UILabelCvpfiAGyXEfU_".classDemangling()
        XCTAssert(a.contains("pgHomePageModule.(PGMainPage_5009021_SubCell in _C4CD798CB5F3BA52699FDA71B41D3DB3)"))
        //
        let b = "s20pgPingouDetailModule14ShareInfoModelV4DataCSgWObTm".classDemangling()
        XCTAssert(b == ["pgPingouDetailModule.ShareInfoModel.Data"])
    }

    func testModuleInfoDecodesWithoutMainModuleForBackwardCompatibility() throws {
        let data = Data(#"{"name":"App","frameworks":[],"libraries":[],"resources":[],"dependencies":[]}"#.utf8)

        let module = try JSONDecoder().decode(ModuleInfo.self, from: data)

        XCTAssertFalse(module.mainModule)
    }

    func testModuleFileParserTreatsFirstLegacyModuleAsMainModule() async throws {
        let data = Data(#"[{"name":"App","frameworks":[],"libraries":[],"resources":[],"dependencies":[]}]"#.utf8)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let modules = await ModuleFileParser(path: url.path).parse()

        XCTAssertEqual(modules.count, 1)
        XCTAssertTrue(modules[0].mainModule)
    }

    func testUnusedObjCPropertyRuleIsDisabledByDefault() {
        XCTAssertFalse(Configuration().unusedObjCPropertyRule.enable)
    }

    func testTransitiveDependenciesIncludeEveryLevelAndExcludeSelf() {
        let app = Module()
        app.name = "App"
        app.dependencies = ["Feature"]
        let feature = Module()
        feature.name = "Feature"
        feature.dependencies = ["Service"]
        let service = Module()
        service.name = "Service"
        service.dependencies = ["Core"]
        let core = Module()
        core.name = "Core"
        core.dependencies = ["App"]

        ModuleParser.calculateAllDependencies(modules: [app, feature, service, core])

        XCTAssertEqual(app.allDependencies, ["Feature", "Service", "Core"])
        XCTAssertFalse(app.allDependencies.contains("App"))
    }

    func testPackageComparisonReportsAddedRemovedAndChangedComponents() {
        let baseline = AppPackageSize(
            allSize: 100,
            binarySize: 70,
            resourceSize: 30,
            components: [
                component(name: "Feature", total: 60, resource: 10),
                component(name: "Removed", total: 40, resource: 20),
            ]
        )
        let comparison = AppPackageSize(
            allSize: 130,
            binarySize: 80,
            resourceSize: 50,
            components: [
                component(name: "Feature", total: 80, resource: 20),
                component(name: "Added", total: 50, resource: 30),
            ]
        )

        let report = APPComparisonReporter.compare(
            baseline: baseline,
            comparison: comparison,
            baselineApp: "Baseline.app",
            comparisonApp: "Comparison.app",
            incrementThreshold: 0
        )
        let components = Dictionary(uniqueKeysWithValues: report.components.map { ($0.name, $0) })

        XCTAssertEqual(report.total.deltaSize, 30)
        XCTAssertEqual(report.total.deltaPercent, 30)
        XCTAssertEqual(report.binary.deltaSize, 10)
        XCTAssertEqual(report.resource.deltaSize, 20)
        XCTAssertEqual(components["Feature"]?.status, .changed)
        XCTAssertEqual(components["Feature"]?.total.deltaSize, 20)
        XCTAssertEqual(components["Added"]?.status, .added)
        XCTAssertEqual(components["Added"]?.total.deltaSize, 50)
        XCTAssertEqual(components["Removed"]?.status, .removed)
        XCTAssertEqual(components["Removed"]?.total.deltaSize, -40)
    }

    func testComparisonPackageSizeCountsEveryAppFileOnce() throws {
        let appURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("App.app")
        try FileManager.default.createDirectory(at: appURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: appURL.deletingLastPathComponent()) }

        func write(_ path: String, bytes: [UInt8]) throws {
            let url = appURL.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(bytes).write(to: url)
        }
        let magic: [UInt8] = [0xcf, 0xfa, 0xed, 0xfe]
        try write("App", bytes: magic + Array(repeating: 0, count: 6))
        try write("Assets.car", bytes: Array(repeating: 1, count: 7))
        try write("Launch.storyboardc/Nested/View.nib", bytes: [1, 2, 3])
        try write("_CodeSignature/CodeResources", bytes: [1, 2])
        try write("Frameworks/Kit.framework/Kit", bytes: magic + Array(repeating: 0, count: 4))
        try write("Frameworks/Kit.framework/_CodeSignature/CodeResources", bytes: Array(repeating: 1, count: 9))
        try write("Frameworks/libswift_Test.dylib", bytes: magic + [1, 2])
        try write("PlugIns/Share.appex/Share", bytes: magic + [1])
        try write("PlugIns/Share.appex/Info.plist", bytes: Array(repeating: 1, count: 11))

        let package = try APPComparisonReporter.packageSize(appPath: appURL.path)
        let components = Dictionary(uniqueKeysWithValues: package.components.map { ($0.name, $0) })
        XCTAssertEqual(
            components["App"]?.resource.bundles.flatMap(\.files).map(\.name).sorted(),
            ["Assets.car", "Launch.storyboardc/Nested/View.nib", "_CodeSignature/CodeResources"]
        )
        XCTAssertEqual(package.allSize, 61)
        XCTAssertEqual(package.binarySize, 29)
        XCTAssertEqual(package.resourceSize, 32)
        XCTAssertEqual(components["App"]?.size, 22)
        XCTAssertEqual(components["Kit"]?.size, 17)
        XCTAssertEqual(components["libswift_Test.dylib"]?.size, 6)
        XCTAssertEqual(components["PlugIns/Share.appex"]?.size, 16)

        let empty = AppPackageSize(allSize: 0, binarySize: 0, resourceSize: 0, components: [])
        let report = APPComparisonReporter.compare(
            baseline: empty,
            comparison: package,
            baselineApp: "Empty.app",
            comparisonApp: appURL.path,
            incrementThreshold: 0
        )
        XCTAssertEqual(report.resourceDetails.first { $0.name == "Assets.car" }?.size.deltaSize, 7)
    }

    func testPackageComparisonFiltersIncrementsBelowThreshold() {
        let baseline = AppPackageSize(
            allSize: 600,
            binarySize: 360,
            resourceSize: 240,
            components: [
                detailedComponent(
                    total: 500,
                    librarySize: 300,
                    libraryFiles: [("Small.o", 50), ("Exact.o", 100), ("Removed.o", 150)],
                    resourceSize: 200,
                    resourceFiles: [("Small.dat", 50), ("Removed.dat", 150)],
                    assets: []
                ),
                component(name: "Unchanged", total: 100, resource: 40),
            ]
        )
        let comparison = AppPackageSize(
            allSize: 800,
            binarySize: 560,
            resourceSize: 240,
            components: [
                detailedComponent(
                    total: 700,
                    librarySize: 500,
                    libraryFiles: [("Small.o", 120), ("Exact.o", 200), ("Added.o", 180)],
                    resourceSize: 200,
                    resourceFiles: [("Small.dat", 120), ("Added.dat", 80)],
                    assets: []
                ),
                component(name: "Unchanged", total: 100, resource: 40),
            ]
        )

        let report = APPComparisonReporter.compare(
            baseline: baseline,
            comparison: comparison,
            baselineApp: "Baseline.app",
            comparisonApp: "Comparison.app"
        )
        let binaryDetails = Dictionary(uniqueKeysWithValues: report.binaryDetails.map { ($0.name, $0) })
        let resourceDetails = Dictionary(uniqueKeysWithValues: report.resourceDetails.map { ($0.name, $0) })

        XCTAssertEqual(report.components.map { $0.name }, ["Feature"])
        XCTAssertEqual(Set(binaryDetails.keys), Set(["Added.o", "Exact.o", "Removed.o"]))
        XCTAssertEqual(binaryDetails["Exact.o"]?.size.deltaSize, 100)
        XCTAssertEqual(binaryDetails["Removed.o"]?.size.deltaSize, -150)
        XCTAssertEqual(Set(resourceDetails.keys), Set(["Removed.dat"]))
        XCTAssertEqual(resourceDetails["Removed.dat"]?.size.deltaSize, -150)
    }

    func testPackageComparisonReportsBinaryAndResourceDetails() {
        let baseline = AppPackageSize(
            allSize: 100,
            binarySize: 70,
            resourceSize: 30,
            components: [detailedComponent(
                total: 100,
                librarySize: 70,
                libraryFiles: [("Old.o", 20), ("Same.o", 50)],
                resourceSize: 30,
                resourceFiles: [("old.png", 10), ("same.dat", 5)],
                assets: [("Icon", 15)]
            )]
        )
        let comparison = AppPackageSize(
            allSize: 135,
            binarySize: 80,
            resourceSize: 55,
            components: [detailedComponent(
                total: 135,
                librarySize: 80,
                libraryFiles: [("New.o", 15), ("Same.o", 65)],
                resourceSize: 55,
                resourceFiles: [("new.dat", 30), ("same.dat", 5)],
                assets: [("Icon", 20)]
            )]
        )

        let report = APPComparisonReporter.compare(
            baseline: baseline,
            comparison: comparison,
            baselineApp: "Baseline.app",
            comparisonApp: "Comparison.app",
            incrementThreshold: 0
        )
        let binaryDetails = Dictionary(uniqueKeysWithValues: report.binaryDetails.map { ($0.name, $0) })
        let resourceDetails = Dictionary(uniqueKeysWithValues: report.resourceDetails.map { ($0.name, $0) })

        XCTAssertEqual(binaryDetails["New.o"]?.status, .added)
        XCTAssertEqual(binaryDetails["New.o"]?.size.deltaSize, 15)
        XCTAssertEqual(binaryDetails["Same.o"]?.status, .changed)
        XCTAssertEqual(binaryDetails["Same.o"]?.size.deltaSize, 15)
        XCTAssertEqual(binaryDetails["Old.o"]?.status, .removed)
        XCTAssertEqual(binaryDetails["Old.o"]?.size.deltaSize, -20)
        XCTAssertEqual(resourceDetails["new.dat"]?.status, .added)
        XCTAssertEqual(resourceDetails["Icon"]?.kind, .asset)
        XCTAssertEqual(resourceDetails["Icon"]?.size.deltaSize, 5)
        XCTAssertEqual(resourceDetails["old.png"]?.status, .removed)
        XCTAssertNil(resourceDetails["same.dat"])
    }

    func testComparisonReportContainsDetailSections() throws {
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputURL) }
        APPAnalyze.shared.config.reportOutputPath = outputURL.path
        let package = AppPackageSize(allSize: 0, binarySize: 0, resourceSize: 0, components: [])
        let report = APPComparisonReporter.compare(
            baseline: package,
            comparison: package,
            baselineApp: "Baseline.app",
            comparisonApp: "Comparison.app"
        )

        APPComparisonReporter.generateReport(report)

        let html = try String(contentsOf: outputURL.appendingPathComponent("comparison.html"), encoding: .utf8)
        let json = try String(contentsOf: outputURL.appendingPathComponent("comparison.json"), encoding: .utf8)
        XCTAssertTrue(html.contains("二进制增量明细"))
        XCTAssertTrue(html.contains("资源增量明细"))
        XCTAssertFalse(html.contains("<th class=\"left\">库</th>"))
        XCTAssertTrue(html.contains("detailRows(report.binaryDetails,false)"))
        XCTAssertTrue(html.contains("detailRows(report.resourceDetails,true)"))
        XCTAssertTrue(html.contains(".tag.changed{background:#fff4d6"))
        XCTAssertTrue(html.contains(".tag.added{background:#e5f6ec"))
        XCTAssertTrue(html.contains(".tag.removed{background:#fdecea"))
        XCTAssertTrue(html.contains("class=\"tag ${item.status}\""))
        XCTAssertTrue(html.contains("基线 APP："))
        XCTAssertTrue(html.contains("对比 APP："))
        XCTAssertTrue(html.contains("\\n对比 APP："))
        XCTAssertFalse(html.contains(" → "))
        XCTAssertTrue(json.contains("binaryDetails"))
        XCTAssertTrue(json.contains("resourceDetails"))
    }

    func testLinkMapComparisonReportsChangedAddedAndRemovedObjectFiles() throws {
        let baselineLinkMap = """
        # Arch: arm64
        # Object files:
        [  0] linker synthesized
        [  1] /DerivedData/App.build/Objects-normal/arm64/AppDelegate.o
        [  2] /DerivedData/App.build/libFeature.a(Changed.o)
        [  3] /DerivedData/App.build/libFeature.a(Removed.o)
        # Sections:
        # Address Size Segment Section
        # Symbols:
        # Address Size File Name
        0x1000 0x0000000000000010 [  1] _main
        0x1010 0x0000000000000008 [  2] _changed_a
        0x1018 0x0000000000000004 [  2] _changed_b
        0x101C 0x0000000000000006 [  3] _removed
        # Dead Stripped Symbols:
        0x0000 0x0000000000000100 [  1] _unused
        """
        let comparisonLinkMap = """
        # Arch: arm64
        # Object files:
        [  0] linker synthesized
        [  1] /AnotherDerivedData/App.build/Objects-normal/arm64/AppDelegate.o
        [  2] /AnotherDerivedData/App.build/libFeature.a(Changed.o)
        [  3] /AnotherDerivedData/App.build/libFeature.a(Added.o)
        # Sections:
        # Address Size Segment Section
        # Symbols:
        # Address Size File Name
        0x1000 0x0000000000000010 [  1] _main
        0x1010 0x0000000000000014 [  2] _changed
        0x1024 0x0000000000000009 [  3] _added
        """

        let baselineObjects = try LinkMapParser.parse(
            content: baselineLinkMap,
            appName: "App",
            expectedArch: "arm64"
        )
        let comparisonObjects = try LinkMapParser.parse(
            content: comparisonLinkMap,
            appName: "App",
            expectedArch: "arm64"
        )
        let baselinePackage = AppPackageSize(
            allSize: 10,
            binarySize: 10,
            resourceSize: 0,
            components: [binaryComponent(name: "DynamicKit", binary: "DynamicKit", size: 10)]
        )
        let comparisonPackage = AppPackageSize(
            allSize: 15,
            binarySize: 15,
            resourceSize: 0,
            components: [binaryComponent(name: "DynamicKit", binary: "DynamicKit", size: 15)]
        )
        let report = APPComparisonReporter.compare(
            baseline: baselinePackage,
            comparison: comparisonPackage,
            baselineApp: "App.app",
            comparisonApp: "App.app",
            baselineLinkMap: baselineObjects,
            comparisonLinkMap: comparisonObjects,
            incrementThreshold: 0
        )
        let details = Dictionary(uniqueKeysWithValues: report.binaryDetails.map { ($0.name, $0) })

        XCTAssertNil(details["AppDelegate.o"])
        XCTAssertEqual(details["Changed.o"]?.module, "Feature")
        XCTAssertEqual(details["Changed.o"]?.container, "libFeature.a")
        XCTAssertEqual(details["Changed.o"]?.status, .changed)
        XCTAssertEqual(details["Changed.o"]?.size.baselineSize, 12)
        XCTAssertEqual(details["Changed.o"]?.size.comparisonSize, 20)
        XCTAssertEqual(details["Added.o"]?.status, .added)
        XCTAssertEqual(details["Added.o"]?.size.deltaSize, 9)
        XCTAssertEqual(details["Removed.o"]?.status, .removed)
        XCTAssertEqual(details["Removed.o"]?.size.deltaSize, -6)
        XCTAssertEqual(details["DynamicKit"]?.module, "DynamicKit")
        XCTAssertEqual(details["DynamicKit"]?.size.deltaSize, 5)
    }

    func testLinkMapKeepsFrameworkLibraryDistinctFromModule() throws {
        let linkMap = """
        # Arch: arm64
        # Object files:
        [  1] /BuildProductsPath/Release-iphoneos/KGListenModule/KGListenModule.framework/KGListenModule(KGSongCommentInnerVC.o)
        [  2] /BuildProductsPath/Release-iphoneos/FeatureModule/Shared.framework/libShared.a(Other.o)
        # Symbols:
        0x1000 0x000000000000000A [  1] _first
        0x100A 0x000000000000000B [  2] _second
        """

        let objects = try LinkMapParser.parse(content: linkMap, appName: "App", expectedArch: "arm64")
        let details = Dictionary(uniqueKeysWithValues: objects.map { ($0.name, $0) })

        XCTAssertEqual(details["KGSongCommentInnerVC.o"]?.module, "KGListenModule")
        XCTAssertEqual(details["KGSongCommentInnerVC.o"]?.container, "KGListenModule.framework/KGListenModule")
        XCTAssertEqual(details["Other.o"]?.module, "FeatureModule")
        XCTAssertEqual(details["Other.o"]?.container, "Shared.framework/libShared.a")
    }

    func testLinkMapParserRejectsMismatchedArchitecture() {
        let content = """
        # Arch: x86_64
        # Object files:
        # Symbols:
        """

        XCTAssertThrowsError(try LinkMapParser.parse(
            content: content,
            appName: "App",
            expectedArch: "arm64"
        )) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "Link Map 架构为 x86_64，与 --arch arm64 不一致"
            )
        }
    }

    func testLinkMapParserToleratesInvalidUTF8InObjectPath() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var data = Data("""
        # Arch: arm64
        # Object files:
        [  1] /DerivedData/
        """.utf8)
        data.append(0xFF)
        data.append(Data("""
        Broken.o
        # Symbols:
        # Address Size File Name
        0x1000 0x000000000000000A [  1] _symbol
        """.utf8))
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let objects = try LinkMapParser.parse(path: url.path, appName: "App", expectedArch: "arm64")

        XCTAssertEqual(objects.count, 1)
        XCTAssertEqual(objects[0].size, 10)
        XCTAssertTrue(objects[0].name.hasSuffix("Broken.o"))
    }

    private func component(name: String, total: Int, resource: Int) -> ModulePackageSize {
        ModulePackageSize(
            name: name,
            version: nil,
            size: total,
            libraries: [],
            resource: ModuleResourceSize(bundles: [], size: resource)
        )
    }

    private func binaryComponent(name: String, binary: String, size: Int) -> ModulePackageSize {
        ModulePackageSize(
            name: name,
            version: nil,
            size: size,
            libraries: [MobuleLibrarySize(name: binary, size: size, files: [], frameworks: [])],
            resource: ModuleResourceSize(bundles: [], size: 0)
        )
    }

    private func detailedComponent(
        total: Int,
        librarySize: Int,
        libraryFiles: [(String, Int)],
        resourceSize: Int,
        resourceFiles: [(String, Int)],
        assets: [(String, Int)]
    ) -> ModulePackageSize {
        ModulePackageSize(
            name: "Feature",
            version: nil,
            size: total,
            libraries: [MobuleLibrarySize(
                name: "Feature.a",
                size: librarySize,
                files: libraryFiles.map { LibraryFileSize(name: $0.0, size: $0.1) },
                frameworks: []
            )],
            resource: ModuleResourceSize(
                bundles: [IbiuComponentSizeResourceBundle(
                    name: "Feature.bundle",
                    size: resourceSize,
                    files: resourceFiles.map { IbiuComponentSizeResourceFile(name: $0.0, size: $0.1) },
                    assets: assets.map { IbiuComponentSizeResourceAsset(name: $0.0, size: $0.1) }
                )],
                size: resourceSize
            )
        )
    }

}
