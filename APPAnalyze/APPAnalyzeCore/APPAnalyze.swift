//
//  APPAnalyze.swift
//  APPAnalyze
//
//  Created by hexiao on 2021/10/14.
//

import Foundation

/// APPAnalyze 主分析器
public class APPAnalyze {
    
    /// 共享单例
    public static let shared = APPAnalyze()
    
    /// 解析器
    ///
    /// - Warning: 默认为 nil，需要配置
    public var parser: Parser!
    
    /// 扫描配置
    public let config = Configuration()
    
    /// 规则管理器
    public let ruleManager = RuleManager()
    
    /// 报告生成器
    public let reporterManager: ReporterManager = ReporterManager()
    
    /// 开始执行
    public func run() async {
        config.check()
        APP.shared.reset()
        // 解析工程或IPA为模块
        let modules = await parser.parse()
        // 解析模块 macho 和资源
        await ModuleParser.parse(modules: modules)
        // 规则扫描
        await ruleManager.check()
        // 生成数据
        await reporterManager.print()
    }

    /// 对比两个 `.app` 的包体积并生成增量报告。
    public func compare(
        baselineAppPath: String,
        comparisonAppPath: String,
        baselineLinkMapPath: String? = nil,
        comparisonLinkMapPath: String? = nil,
        incrementThreshold: Int = 100
    ) async throws {
        parser = IPAParser(appPath: baselineAppPath)
        config.check()
        let baseline = await packageSize(appPath: baselineAppPath)
        let comparison = await packageSize(appPath: comparisonAppPath)
        let baselineAppName = URL(fileURLWithPath: baselineAppPath).deletingPathExtension().lastPathComponent
        let comparisonAppName = URL(fileURLWithPath: comparisonAppPath).deletingPathExtension().lastPathComponent
        let baselineLinkMap = try baselineLinkMapPath.map {
            try LinkMapParser.parse(path: $0, appName: baselineAppName, expectedArch: config.archType.rawValue)
        }
        let comparisonLinkMap = try comparisonLinkMapPath.map {
            try LinkMapParser.parse(path: $0, appName: comparisonAppName, expectedArch: config.archType.rawValue)
        }
        let report = APPComparisonReporter.compare(
            baseline: baseline,
            comparison: comparison,
            baselineApp: URL(fileURLWithPath: baselineAppPath).standardizedFileURL.path,
            comparisonApp: URL(fileURLWithPath: comparisonAppPath).standardizedFileURL.path,
            baselineLinkMap: baselineLinkMap,
            comparisonLinkMap: comparisonLinkMap,
            incrementThreshold: incrementThreshold
        )
        try FileManager.default.createDirectory(
            atPath: config.reportOutputPath,
            withIntermediateDirectories: true,
            attributes: nil
        )
        APPComparisonReporter.generateReport(report)
    }

    private func packageSize(appPath: String) async -> AppPackageSize {
        APP.shared.reset()
        let modules = await IPAParser(appPath: appPath).parse()
        await ModuleParser.parse(modules: modules, generateModuleReport: false)
        return APPPackageSizeReporter.packageSize()
    }
}
