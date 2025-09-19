//
//  SettingsKey.swift
//  AutoDB
//
//  Created by Olof Andersson-Thorén on 2025-09-16.
//


public enum SettingsKey: Sendable, Hashable {
		case regular
		case cache
		case memory
		case specific(AutoDBSettings)
		
		public static func == (lhs: SettingsKey, rhs: SettingsKey) -> Bool {
			switch (lhs, rhs) {
				case (.regular, .regular), (.cache, .cache), (.memory, .memory):
					return true
				case (.specific(let lhsValue), .specific(let rhsValue)):
					return lhsValue == rhsValue
				default:
					return false
			}
		}
	}