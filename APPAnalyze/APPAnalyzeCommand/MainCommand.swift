//
//  MainCommand.swift
//  APPAnalyzeCommand
//
//  Created by hexiao on 2022/4/18.
//

import APPAnalyzeCore
import ArgumentParser
import Foundation

@main
struct MainCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
    )

    @Option(help: "基线 .app 文件路径；需和 --comparison-app 一起使用")
    var baselineApp: String?

    @Option(help: "对比 .app 文件路径；需和 --baseline-app 一起使用")
    var comparisonApp: String?

    @Option(help: "基线 APP 的 Link Map；需和 --comparison-link-map 一起使用")
    var baselineLinkMap: String?

    @Option(help: "对比 APP 的 Link Map；需和 --baseline-link-map 一起使用")
    var comparisonLinkMap: String?

    @Option(help: "增量报告输出阈值，单位为 B，默认 100B；绝对增量小于该值的模块和明细不输出")
    var incrementThreshold: Int = 100
    
#if DEBUG

    var output: String = "/Users/hexiao/Desktop/ipas/pinduoduo3"

    var config: String = "/Users/hexiao/Desktop/ipas/config.json"

    var ipa: String? = "/Users/hexiao/Desktop/ipas/pinduoduo/pinduoduo.app"

    var modules: String?
    
    var arch: String = "arm64"

#endif
    
#if RELEASE

        @Option(help: "输出文件目录")
        var output: String

        @Option(help: "配置JSON文件地址")
        var config: String?

        @Option(help: "ipa.app文件地址")
        var ipa: String?

        @Option(help: "工程文件目录")
        var modules: String?
    
    @Option(help: "指令集架构：arm64、x86_64")
    var arch: String = "arm64"

#endif
    
//    /Users/hexiao/Desktop/ipas/1.2.0/APPAnalyzeCommand --ipa /Users/hexiao/Desktop/ipas/pinduoduo/pinduoduo.app --config /Users/hexiao/Desktop/ipas/config.json --output /Users/hexiao/Desktop/ipas/pinduoduo/APPAnalyze

    mutating func run() async throws {
        let date = Date()
        #if DEBUG
        CommandLine.arguments = ["/Users/hexiao/ibiu_project/test/Example/TestOC", "-ipa", "/Users/hexiao/Desktop/ipas/pinduoduo/pinduoduo.app", "-config", "/Users/hexiao/Desktop/ipas/config.json", "--output", "/Users/hexiao/Desktop/ipas/pinduoduo2"]
        #endif
        //
        log("执行参数：\(CommandLine.arguments)")
        //
        let appAnalyze = APPAnalyze.shared
        // 执行参数配置
        let analyzeConfig = appAnalyze.config
        analyzeConfig.archType = ArchType(rawValue: arch) ?? .arm64
        var currentDirectoryPath = CommandLine.arguments[0]
        var url = URL(fileURLWithPath: currentDirectoryPath)
        url.deleteLastPathComponent()
        currentDirectoryPath = url.absoluteString
        analyzeConfig.currentDirectoryPath = currentDirectoryPath
        analyzeConfig.configPath = config
        analyzeConfig.reportOutputPath = output
        // 解析器和规则配置
        if baselineApp != nil || comparisonApp != nil {
            guard let baselineApp, let comparisonApp else {
                throw ValidationError("--baseline-app 和 --comparison-app 必须同时传入")
            }
            guard (baselineLinkMap == nil) == (comparisonLinkMap == nil) else {
                throw ValidationError("--baseline-link-map 和 --comparison-link-map 必须同时传入")
            }
            guard ipa == nil, modules == nil else {
                throw ValidationError("对比模式不能同时使用 --ipa 或 --modules")
            }
            guard incrementThreshold >= 0 else {
                throw ValidationError("--increment-threshold 不能小于 0")
            }
            try await appAnalyze.compare(
                baselineAppPath: baselineApp,
                comparisonAppPath: comparisonApp,
                baselineLinkMapPath: baselineLinkMap,
                comparisonLinkMapPath: comparisonLinkMap,
                incrementThreshold: incrementThreshold
            )
        } else if let modules = self.modules {
            appAnalyze.parser = ModuleFileParser(path: modules)
            //
            let ruleManager = appAnalyze.ruleManager
            ruleManager.addRule(rule: DuplicateResourceInBundleRule.self)
            ruleManager.addRule(rule: RingDependencyRule.self)
            ruleManager.addRule(rule: UnusedModuleRule.self)
            ruleManager.addRule(rule: GlobalUnusedModuleRule.self)
        } else if let ipa = self.ipa {
            appAnalyze.parser = IPAParser(appPath: ipa)
        } else {
            throw ValidationError("需要传入 --ipa、--modules 或一组 APP 对比参数")
        }
        if baselineApp == nil {
            await appAnalyze.run()
        }
        //
        log("结束执行")
        print("总耗时\(-Int(date.timeIntervalSinceNow))s")
    }
}
