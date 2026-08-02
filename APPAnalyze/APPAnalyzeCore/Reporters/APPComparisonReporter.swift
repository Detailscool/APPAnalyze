//
//  APPComparisonReporter.swift
//  APPAnalyzeCore
//

import Foundation

enum ComponentChangeStatus: String, Encodable, Equatable {
    case added
    case removed
    case changed
    case unchanged
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

struct APPSizeComparisonReport: Encodable, Equatable {
    let baselineApp: String
    let comparisonApp: String
    let total: SizeIncrement
    let binary: SizeIncrement
    let resource: SizeIncrement
    let components: [ComponentSizeIncrement]
}

enum APPComparisonReporter {
    static func compare(
        baseline: AppPackageSize,
        comparison: AppPackageSize,
        baselineApp: String,
        comparisonApp: String
    ) -> APPSizeComparisonReport {
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
            components: components
        )
    }

    static func generateReport(_ report: APPSizeComparisonReport) {
        APPAnalyze.shared.reporterManager.generateReport(data: report.data, fileName: "comparison.json")
        let data = try! JSONEncoder().encode(report)
        let json = String(data: data, encoding: .utf8)!
        let html = """
        <!doctype html><html><head><meta charset="utf-8"/><meta name="viewport" content="width=device-width,initial-scale=1.0"/><title>APP 包体积增量</title><style>body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;margin:28px;color:#222}table{border-collapse:collapse;width:100%;margin:12px 0 28px}th,td{border:1px solid #ddd;padding:8px 10px;text-align:right}th{background:#f6f7f8}th:nth-child(2),td:nth-child(2){text-align:left}.positive{color:#c62828}.negative{color:#188038}.zero{color:#666}.tag{padding:2px 7px;border-radius:10px;background:#eee;font-size:12px}code{background:#f4f4f4;padding:2px 5px}</style><script>const report=\(json);function size(value){const sign=value>0?'+':value<0?'-':'';let n=Math.abs(value);if(n<1000)return sign+n+'B';n=n/1000;if(n<1000)return sign+n.toFixed(1)+'KB';return sign+(n/1000).toFixed(2)+'MB'}function percent(item){if(item.deltaPercent===null||item.deltaPercent===undefined)return'-';const sign=item.deltaPercent>0?'+':'';return sign+item.deltaPercent.toFixed(2)+'%'}function cls(value){return value>0?'positive':value<0?'negative':'zero'}function summaryRow(name,item){return `<tr><td>${name}</td><td>${size(item.baselineSize)}</td><td>${size(item.comparisonSize)}</td><td class="${cls(item.deltaSize)}">${size(item.deltaSize)}</td><td class="${cls(item.deltaSize)}">${percent(item)}</td></tr>`}function onLoad(){document.getElementById('apps').textContent=report.baselineApp+' → '+report.comparisonApp;document.getElementById('summary').innerHTML=summaryRow('总大小',report.total)+summaryRow('二进制',report.binary)+summaryRow('资源',report.resource);const status={added:'新增',removed:'删除',changed:'变化',unchanged:'未变化'};document.getElementById('components').innerHTML=report.components.map((item,index)=>`<tr><td>${index+1}</td><td>${item.name}</td><td><span class="tag">${status[item.status]}</span></td><td>${size(item.total.baselineSize)}</td><td>${size(item.total.comparisonSize)}</td><td class="${cls(item.total.deltaSize)}">${size(item.total.deltaSize)}</td><td class="${cls(item.binary.deltaSize)}">${size(item.binary.deltaSize)}</td><td class="${cls(item.resource.deltaSize)}">${size(item.resource.deltaSize)}</td><td>${percent(item.total)}</td></tr>`).join('')}</script></head><body onload="onLoad()"><h1>APP 包体积增量报告</h1><p id="apps"></p><h2>总体变化</h2><table><thead><tr><th>类型</th><th>基线</th><th>对比</th><th>增量</th><th>增幅</th></tr></thead><tbody id="summary"></tbody></table><h2>模块变化</h2><table><thead><tr><th>#</th><th>模块</th><th>状态</th><th>基线大小</th><th>对比大小</th><th>总增量</th><th>二进制增量</th><th>资源增量</th><th>增幅</th></tr></thead><tbody id="components"></tbody></table></body></html>
        """
        APPAnalyze.shared.reporterManager.generateReport(text: html, fileName: "comparison.html")
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
