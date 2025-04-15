//
//  URLErrorExtension.swift
//  AutoDB
//
//  Created by Olof Andersson-Thorén on 2025-04-09.
//

import Foundation

public extension Error {
	
	/// things out of our control, try again at a later date
	var serverOrNetworkError: Bool {
		let nsError = self as NSError
		
		guard nsError.domain == NSURLErrorDomain else {
			return false
		}
		
		//NSURLErrorUnsupportedURL, NSURLErrorBadURL:
		
		switch nsError.code {
			case NSURLErrorTimedOut,
				NSURLErrorCannotFindHost,
				NSURLErrorCannotConnectToHost,
				NSURLErrorDNSLookupFailed,
				NSURLErrorHTTPTooManyRedirects,
				NSURLErrorResourceUnavailable,
				NSURLErrorRedirectToNonExistentLocation,
				NSURLErrorBadServerResponse,
				NSURLErrorZeroByteResource,
				NSURLErrorCannotDecodeRawData,
				NSURLErrorCannotDecodeContentData,
				NSURLErrorCannotParseResponse,
				NSURLErrorUserCancelledAuthentication,
				NSURLErrorUserAuthenticationRequired,
				NSURLErrorNotConnectedToInternet,
				NSURLErrorNetworkConnectionLost,
				
				// ssl errors
				NSURLErrorSecureConnectionFailed,
				NSURLErrorServerCertificateHasBadDate,
				NSURLErrorServerCertificateUntrusted,
				NSURLErrorServerCertificateHasUnknownRoot,
				NSURLErrorServerCertificateNotYetValid,
				NSURLErrorClientCertificateRejected,
				NSURLErrorClientCertificateRequired,
				NSURLErrorCannotLoadFromNetwork,
				
				// Download and file I/O errors - perhaps remove these?
				NSURLErrorCannotCreateFile,
				NSURLErrorCannotOpenFile,
				NSURLErrorCannotCloseFile,
				NSURLErrorCannotWriteToFile,
				NSURLErrorCannotRemoveFile,
				NSURLErrorCannotMoveFile,
				NSURLErrorDownloadDecodingFailedMidStream,
				NSURLErrorDownloadDecodingFailedToComplete,
				
				// client errors that needs retry in a while
				NSURLErrorInternationalRoamingOff,
				NSURLErrorCallIsActive,
				NSURLErrorDataNotAllowed,
				NSURLErrorRequestBodyStreamExhausted,
				NSURLErrorBackgroundSessionRequiresSharedContainer,
				NSURLErrorBackgroundSessionInUseByAnotherProcess,
				NSURLErrorBackgroundSessionWasDisconnected:
				
				return true
				
			default:
				return false
		}
	}
}

