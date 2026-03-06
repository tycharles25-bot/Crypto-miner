//
//  ContributeConfig.swift
//  Crypto miner
//
//  Client-side contribution: share Gecko data with server for crowdsourced indexing
//

import Foundation

enum ContributeConfig {
    private static let serverURLKey = "contribute_server_url"
    private static let enabledKey = "contribute_enabled"

    static var serverBaseURL: String {
        get { UserDefaults.standard.string(forKey: serverURLKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: serverURLKey) }
    }

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static var contributeURL: URL? {
        let base = serverBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return nil }
        let urlStr = base.hasSuffix("/") ? base + "contribute" : base + "/contribute"
        return URL(string: urlStr)
    }
}
