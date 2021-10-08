import BigInt
import AddressKit
import RapidLMDB
import Foundation

//IPv4
extension AddressV4:DataConvertible {
	public init?(data:Data) {
		guard let asInt = UInt32(data:data) else {
			return nil
		}
		self = AddressV4(asInt)
	}
	public func exportData() -> Data {
		return self.integer.exportData()
	}
}

extension RangeV4:DataConvertible {
	public init?(data:Data) {
		guard let dataAsString = String(data:data, encoding:.utf8), let parsedString = Self(dataAsString) else {
			return nil
		}
		self = parsedString
	}
	
	public func exportData() -> Data {
		return self.string.exportData()
	}
}

extension NetworkV4:DataConvertible {
	public init?(data:Data) {
		guard let dataAsString = String(data:data, encoding:.utf8), let parsedString = Self(cidr:dataAsString) else {
			return nil
		}
		self = parsedString
	}
	
	public func exportData() -> Data {
		return self.cidrString.exportData()
	}
}

//IPv6
extension AddressV6:DataConvertible {
	public init?(data:Data) {
		self = data.withUnsafeBytes { unsafeBuff in
			return AddressV6(BigUInt(unsafeBuff))
		}
	}
	public func exportData() -> Data {
		return self.integer.serialize()
	}
}

extension RangeV6:DataConvertible {
	public init?(data:Data) {
		guard let dataAsString = String(data:data, encoding:.utf8), let parsedString = Self(dataAsString) else {
			return nil
		}
		self = parsedString
	}
	
	public func exportData() -> Data {
		return self.string.exportData()
	}
}

extension NetworkV6:DataConvertible {
	public init?(data:Data) {
		guard let dataAsString = String(data:data, encoding:.utf8), let parsedString = Self(cidr:dataAsString) else {
			return nil
		}
		self = parsedString
	}
	
	public func exportData() -> Data {
		return self.cidrString.exportData()
	}
}
