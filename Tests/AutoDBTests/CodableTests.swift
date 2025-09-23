//
//  CodableTests.swift
//  AutoDB
//
//  Created by Olof Andersson-Thorén on 2025-09-23.
//

public enum Status: UInt, Sendable, Codable {
	case ok = 1
}

// build support for SQLUIntegerEnum
