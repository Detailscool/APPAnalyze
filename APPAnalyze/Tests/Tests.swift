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

}
