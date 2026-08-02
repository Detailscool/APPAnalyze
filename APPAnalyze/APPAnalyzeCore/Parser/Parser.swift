//
//  IParser.swift
//  APPAnalyzeCore
//
//  Created by hexiao on 2023/11/6.
//

import Foundation

/// 解析器协议
///
/// 默认提供`IPAParser`和`ModuleFileParser`解析器。可以根据组件化工程特点自定义实现
public protocol Parser {
    func parse() async -> [ModuleInfo]
}

/// 模块信息
public struct ModuleInfo: Decodable {
    
    /// 名字
    let name: String
    
    /// 版本
    let version: String?
    
    /// framework 列表文件路径
    let frameworks: Set<String>
    
    /// library 列表文件路径
    let libraries: Set<String>
    
    /// 资源列表文件路径
    let resources: Set<String>
    
    /// 子依赖
    var dependencies: Set<String>
    
    var mainModule: Bool

    private enum CodingKeys: String, CodingKey {
        case name
        case version
        case frameworks
        case libraries
        case resources
        case dependencies
        case mainModule
    }

    public init(name: String, version: String?, frameworks: Set<String>, libraries: Set<String>, resources: Set<String>, dependencies: Set<String>, mainModule: Bool) {
        self.name = name
        self.version = version
        self.frameworks = frameworks
        self.libraries = libraries
        self.resources = resources
        self.dependencies = dependencies
        self.mainModule = mainModule
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        version = try container.decodeIfPresent(String.self, forKey: .version)
        frameworks = try container.decode(Set<String>.self, forKey: .frameworks)
        libraries = try container.decode(Set<String>.self, forKey: .libraries)
        resources = try container.decode(Set<String>.self, forKey: .resources)
        dependencies = try container.decode(Set<String>.self, forKey: .dependencies)
        mainModule = try container.decodeIfPresent(Bool.self, forKey: .mainModule) ?? false
    }
}

extension ModuleInfo: Encodable {
    
}
