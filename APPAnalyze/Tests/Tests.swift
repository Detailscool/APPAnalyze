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
            comparisonApp: "Comparison.app"
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

    private func component(name: String, total: Int, resource: Int) -> ModulePackageSize {
        ModulePackageSize(
            name: name,
            version: nil,
            size: total,
            libraries: [],
            resource: ModuleResourceSize(bundles: [], size: resource)
        )
    }

}
