//
//  AutoId.swift
//  AutoDB
//
//  Created by Olof Andersson-Thorén on 2026-04-16.
//

import Foundation

/// AutoId is just a basic unsigned int, with the last 4 bits untouched for Swift-optimizations
public typealias AutoId = UInt64
public extension AutoId {
	static func generateId() -> AutoId {
		
		let random = random(in: 1..<AutoId.max)
		return random >> 4  //save some bits for Swift's optimisations
	}
}

/// Server ids need to be 128 bits, a better id type for AutoDB:
/// Sore like: id BINARY(16) NOT NULL,
public struct AutoId128: Codable, Hashable, Sendable {
	public let rawValue: Data
	
	public init(rawValue: Data) {
		if rawValue.count < 16 {
			let padding = Data(repeating: 0, count: 16 - rawValue.count)
			self.rawValue = padding + rawValue
		} else if rawValue.count > 16 {
			self.rawValue = rawValue[0..<16]
		} else {
			self.rawValue = rawValue
		}
	}
	
	public static func random() -> AutoId128 {
		var bytes = [UInt8](repeating: 0, count: 16)
		_ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
		return AutoId128(rawValue: Data(bytes))
	}
}

extension AutoId128: SQLColumnWrappable, SQLStorableAsData {
	public func unifiedRepresentation() -> Data {
		rawValue
	}
	
	public static func from(unifiedRepresentation: Data) -> AutoId128 {
		AutoId128(rawValue: unifiedRepresentation)
	}
	
	public static func fromValue(_ value: SQLValue) -> AutoId128? {
		value.dataValue.map(AutoId128.init(rawValue:))
	}
}
