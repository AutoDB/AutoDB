//
//  AutoLog.swift
//  AutoDB
//
//  Created by Olof Andersson-Thorén on 2025-04-10.
//

#if canImport(OSLog)
import OSLog
#else
public final class Logger {
	public init(subsystem: String, category: String) {}
	public func info(_ message: String) {
		print(message)
	}
	public func debug(_ message: String) {
		print(message)
	}
	public func error(_ message: String) {
		print(message)
	}
}
#endif
import CoreFoundation

public actor AutoLog {
	
	private static let log = AutoLog()
	private static let subsystem = Bundle.main.bundleIdentifier ?? "AutoDB-noBundle"
	private static let autoDB = Logger(subsystem: subsystem, category: "AutoDB")
	static let dateFormat = Date.FormatStyle().locale(Locale(identifier: "sv_SE"))	// regular standard date format for easy sorting (basically a simpler form of ISO8601).
	var logURL: URL = FileManager.default.temporaryDirectory.appendingPathComponent("Auto.log")
	var fileHandle: FileHandle?
	
	public static func setup(appGroup: String? = nil) {
		Task {
			
			await log.setup(appGroup: appGroup)
		}
	}
	
	func setup(appGroup: String? = nil, truncateLines: Int = 500) {
		if let appGroup {
			self.logURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?.appendingPathComponent("Auto.log") ?? logURL
		}
		
		if FileManager.default.fileExists(atPath: logURL.path) == false {
			FileManager.default.createFile(atPath: logURL.path, contents: nil)
		} else {
			// truncate after x lines
			Task {
				let slize = await listLogs(maxLines: truncateLines)
				let test = slize.reversed().joined(separator: "\n")
				if slize.count >= truncateLines {
					do {
						try slize.reversed().joined(separator: "\n")
							.write(toFile: logURL.path, atomically: true, encoding: .utf8)
					} catch {
						print(error)
					}
				}
			}
		}
	}
	
	public static func listLogs(maxLines: Int = 200) async -> [String] {
		let result = await log.listLogs(maxLines: maxLines)
		return result
	}
	
	public func listLogs(maxLines: Int = 200) async -> [String] {
		let slize = (try? Data(contentsOf: logURL))
			.flatMap { String(data: $0, encoding: .utf8) }?
			.components(separatedBy: .newlines) ?? []
		
		if slize.isEmpty { return [] }
		
		let array = slize.suffix(maxLines)
		if let lastLine = slize.last, lastLine.isEmpty || lastLine == "" {
			return Array(array.dropLast().reversed()) 	// typically ends with a newline
		}
		return Array(array.reversed())
	}
	
	var closeLogTask: Task<Void, Error>?
	func writeToLog(_ string: String) {
		guard let data = string.data(using: .utf8) else { return }
		
		// open log for 10 sec if there is more
		if fileHandle == nil {
			fileHandle = FileHandle(forWritingAtPath: logURL.path)
		}
		
		try? fileHandle?.seekToEnd()
		fileHandle?.write(data)
		
		closeLogTask = Task {
			try await Task.sleep(for: .seconds(10))
			try self.fileHandle?.close()
			self.fileHandle = nil
		}
	}
	
	private static func log(_ message: String) {
		Task {
			await log.writeToLog(message)
		}
	}
	
	// will be deleted at next app-start
	public static func debug(_ message: String, file: StaticString = #file, function: StaticString = #function, line: UInt = #line) {
		autoDB.info("\(function)\(line) :\(message)")
		log("[\(Date.now.formatted(dateFormat))]: \(subsystem):\(function)\(line): \(message)\n")
	}
	
	public static func error(_ message: String, file: StaticString = #file, function: StaticString = #function, line: UInt = #line) {
		autoDB.error("\(file):\(function) \(line):\(message)")
		log("Error [\(Date.now.formatted(dateFormat))]: \(subsystem):\(function)\(line): \(message)\n")
	}
}

