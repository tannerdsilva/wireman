import RapidLMDB
import Foundation
import AddressKit

private let homePath = URL(fileURLWithPath:String(cString:getpwuid(getuid())!.pointee.pw_dir))
let buildVersion:UInt64 = 1

class WireguardDatabase {
	enum WireguardError:Error {
		case internalFailure
		case addressNotInSubnet
		case subnetOverlaps
		case nameExistsInSubnet
		case addressAlreadyAssigned
	}
	class func databasePath() -> String {
		return homePath.appendingPathComponent(".wireman-db").path
	}
	enum Metadatas:String {
		case dbVersion = "databaseVersion" //UInt64
		case primaryInterface = "primaryWGInterface" //string
		case server_endpoint_domain = "server_endpoint_domain" //String
		case listenPort = "server_public_listenPort" //UInt16
		case ipv4_scope = "server_ipv4_scope" //(OPTIONAL) NetworkV4 where address == servers own internal IP
		case ipv6_scope = "server_ipv6_scope" //networkV6 where address == servers own internal IP
		case serverPublicKey = "server_public_key" //string
	}
	func primaryInterfaceName() throws -> String {
		return try self.metadata.get(type:String.self, forKey:Metadatas.primaryInterface.rawValue, tx:nil)!
	}
	func getPublicEndpointDomain() throws -> String {
		try env.transact(readOnly:true) { someTrans in
			let domain = try self.metadata.get(type:String.self, forKey:Metadatas.server_endpoint_domain.rawValue, tx:someTrans)!
			let port = try self.metadata.get(type:UInt16.self, forKey:Metadatas.listenPort.rawValue, tx:someTrans)!
			return domain + ":" + String(port)
		}
	}
	func getServerEndpointListenPort() throws -> UInt16 {
		return try self.metadata.get(type:UInt16.self, forKey:Metadatas.listenPort.rawValue, tx:nil)!
	}
	func ipv6Scope() throws -> NetworkV6 {
		return try self.metadata.get(type:NetworkV6.self, forKey:Metadatas.ipv6_scope.rawValue, tx:nil)!
	}
	func ipv4Scope() throws -> NetworkV4? {
		do {
			return try self.metadata.get(type:NetworkV4.self, forKey:Metadatas.ipv4_scope.rawValue, tx:nil)!
		} catch LMDBError.notFound {
			return nil
		}
	}
	func getServerPublicKey() throws -> String {
		return try self.metadata.get(type:String.self, forKey:Metadatas.serverPublicKey.rawValue, tx:nil)!
	}
	
	var needsInitialConfiguration:Bool {
		get {
			do {
				if try metadata.contains(key:Metadatas.primaryInterface.rawValue, tx:nil) == true {
					return false
				}
				return true
			} catch LMDBError.notFound {
				return true
			} catch _ {
				return false
			}
		}
	}
	
	let env:Environment
	let metadata:Database
	
	let subnetName_subnetNetworkV6:Database // string -> NetworkV6
	
	let clientPub_subnetName:Database
	let clientPub_clientName:Database

	let clientPub_clientIPv6:Database
	let clientIPv6_clientPub:Database
	
	init() throws {
		let makeEnv = try Environment(path:Self.databasePath(), flags:[.noSubDir])
		self.env = makeEnv
		
		let dbs = try makeEnv.transact(readOnly:false) { someTrans -> [Database] in
			let meta = try makeEnv.openDatabase(named:"metadata", flags:[.create], tx:someTrans)
			let subName_cidrV6 = try makeEnv.openDatabase(named:"subName_subnetV6", flags:[.create], tx:someTrans)
			
			let pub_sub = try makeEnv.openDatabase(named:"pub_sub", flags:[.create], tx:someTrans)
			let pub_name = try makeEnv.openDatabase(named:"pub_name", flags:[.create], tx:someTrans)
			
			let pub_ipv6 = try makeEnv.openDatabase(named:"pub_ipv6", flags:[.create], tx:someTrans)
			let ipv6_pub = try makeEnv.openDatabase(named:"ipv6_pub", flags:[.create], tx:someTrans)
			
			func migrateDatabase(version:UInt64?) throws -> UInt64 {
					switch version! {
						case nil:
							try meta.delete(key:Metadatas.ipv4_scope.rawValue, tx:someTrans)
							return 1
						//no other versions to handle at this time
						default:
							return 1
					}
			}
			var curVersion:UInt64? = nil
			repeat {
				curVersion = try migrateDatabase(version:try? meta.get(type:UInt64.self, forKey:Metadatas.dbVersion.rawValue, tx:someTrans)!)
			} while curVersion == buildVersion
			
			return [meta, subName_cidrV6, pub_sub, pub_name, pub_ipv6, ipv6_pub]
		}
		
		self.metadata = dbs[0]
		self.subnetName_subnetNetworkV6 = dbs[1]
		self.clientPub_subnetName = dbs[2]
		self.clientPub_clientName = dbs[3]
		self.clientPub_clientIPv6 = dbs[4]
		self.clientIPv6_clientPub = dbs[5]
	}
	
	//bootstrapping
	func assignInitialConfiguration(primaryInterface:String, publicEndpoint:String, publicListenPort:UInt16, ipv4Scope:NetworkV4?, ipv6Scope:NetworkV6, publicKey:String) throws {
		try env.transact(readOnly:false) { someTrans in
			try self.metadata.set(value:primaryInterface, forKey:Metadatas.primaryInterface.rawValue, tx:someTrans)
			try self.metadata.set(value:publicEndpoint, forKey:Metadatas.server_endpoint_domain.rawValue, tx:someTrans)
			try self.metadata.set(value:publicListenPort, forKey:Metadatas.listenPort.rawValue, tx:someTrans)
			if (ipv4Scope != nil) {
				try self.metadata.set(value:ipv4Scope!, forKey:Metadatas.ipv4_scope.rawValue, tx:someTrans)
			}
			try self.metadata.set(value:ipv6Scope, forKey:Metadatas.ipv6_scope.rawValue, tx:someTrans)
			try self.metadata.set(value:publicKey, forKey:Metadatas.serverPublicKey.rawValue, tx:someTrans)
		}
	}
	
	//managing subnets
	func createSubnet(name:String, subnet:NetworkV6) throws {
		try env.transact(readOnly:false) { someTrans in
			//validate no overlapping subnets
			let subnetCursor = try subnetName_subnetNetworkV6.cursor(tx:someTrans)
			for kv in subnetCursor {
				guard let curNet = NetworkV6(data:kv.value) else {
					throw WireguardError.internalFailure
				}
				guard curNet.overlapsWith(subnet) == false else {
					throw WireguardError.subnetOverlaps
				}
			}
			try subnetCursor.set(value:subnet, forKey:name, flags:[.noOverwrite])
		}
	}
	func getSubnets() throws -> [String:NetworkV6] {
		try env.transact(readOnly:true) { someTrans in
			let subnetCursor = try self.subnetName_subnetNetworkV6.cursor(tx:someTrans)
			var buildResult = [String:NetworkV6]()
			for kv in subnetCursor {
				if let curName = String(data:kv.key), let curRange = NetworkV6(data:kv.value) {
					buildResult[curName] = curRange
				}
			}
			return buildResult
		}
	}
	func revokeSubnet(name:String) throws -> Set<String> {
		try env.transact(readOnly:false) { someTrans in
			var buildPublicKeys = Set<String>()
			let nameData = name.exportData()
			try self.subnetName_subnetNetworkV6.delete(key:nameData, tx:someTrans)
			let subNameCursor = try clientPub_subnetName.cursor(tx:someTrans)
			let cliNameCursor = try clientPub_clientName.cursor(tx:someTrans)
			let pubIPCursor = try clientPub_clientIPv6.cursor(tx:someTrans)
			let ipPubCursor = try clientIPv6_clientPub.cursor(tx:someTrans)
						
			func revoke(pubKey:Data) throws {			
				let cliName = try cliNameCursor.get(.setKey, key:pubKey).value
				try cliNameCursor.deleteCurrent()
			
				let addr = try pubIPCursor.get(.setKey, key:pubKey).value
				try pubIPCursor.deleteCurrent()
			
				_ = try ipPubCursor.get(.setKey, key:addr)
				try ipPubCursor.deleteCurrent()
			}
			
			for kv in subNameCursor {
				if kv.value == nameData {
					guard let asString = String(data:kv.key) else {
						throw WireguardError.internalFailure
					}
					try revoke(pubKey:kv.key)
					try subNameCursor.deleteCurrent()
					buildPublicKeys.update(with:asString)
				}
			}
			
			return buildPublicKeys
		}
	}
	
	//managing clients
	struct ClientInfo:Hashable {
		let name:String
		let subnet:String
		let address:AddressV6
		let publicKey:String
		
		func hash(into hasher:inout Hasher) {
			hasher.combine(publicKey)
		}
		
		static func == (lhs:ClientInfo, rhs:ClientInfo) -> Bool {
			return lhs.publicKey == rhs.publicKey
		}
	}
	func makeClient(_ clientInfo:ClientInfo) throws {
		try env.transact(readOnly:false) { someTrans in
			//validate that the subnet exists
			guard let getNetwork = try self.subnetName_subnetNetworkV6.get(type:NetworkV6.self, forKey:clientInfo.subnet, tx:someTrans) else {
				throw WireguardError.internalFailure
			}
			//validate that the address is within the subnet
			guard getNetwork.contains(clientInfo.address) else {
				throw WireguardError.addressNotInSubnet
			}
			//validate that the name does not already exist in the subnet (equal names are only allowed if the names exist on different subnets)
			let subnetNameCursor = try self.clientPub_subnetName.cursor(tx:someTrans)
			let clientNameCursor = try self.clientPub_clientName.cursor(tx:someTrans)
			for curName in clientNameCursor {
				let checkSubnet = try subnetNameCursor.get(.setKey, key:curName.key)
				guard let clientName = String(data:curName.value), let subnetName = String(data:checkSubnet.value) else {
					throw WireguardError.internalFailure
				}
				guard clientName != clientInfo.name || subnetName != clientInfo.subnet else {
					throw WireguardError.nameExistsInSubnet
				}
			}
			//validate that the address has not already been assigned
			guard try self.clientIPv6_clientPub.contains(key:clientInfo.address, tx:someTrans) == false else {
				throw WireguardError.addressAlreadyAssigned
			}
			
			//validation passed: install the client in the database
			try subnetNameCursor.set(value:clientInfo.subnet, forKey:clientInfo.publicKey)
			try clientNameCursor.set(value:clientInfo.name, forKey:clientInfo.publicKey)
			try self.clientIPv6_clientPub.set(value:clientInfo.publicKey, forKey:clientInfo.address, tx:someTrans)
			try self.clientPub_clientIPv6.set(value:clientInfo.address, forKey:clientInfo.publicKey, tx:someTrans)
		}
	}
	func getClients(subnet:String) throws -> Set<ClientInfo> {
		try env.transact(readOnly:true) { someTrans -> Set<ClientInfo> in
			var buildClients = Set<ClientInfo>()
		
			let subNameCursor = try clientPub_subnetName.cursor(tx:someTrans)
			let cliNameCursor = try clientPub_clientName.cursor(tx:someTrans)
			let clientPubIP = try clientPub_clientIPv6.cursor(tx:someTrans)
			
			for subRecord in subNameCursor {
				guard let subName = String(data:subRecord.value) else {
					throw WireguardError.internalFailure
				}
				//if this client is in the subnet the user is targeting...
				if subName == subnet {
					//fetch all the other data
					let clientName = try cliNameCursor.get(.setKey, key:subRecord.key).value
					let clientIP = try clientPubIP.get(.setKey, key:subRecord.key).value
					guard let pubKeyString = String(data:subRecord.key), let clientNameString = String(data:clientName), let clientIPStruct = AddressV6(data:clientIP) else {
						throw WireguardError.internalFailure
					}
					buildClients.update(with:ClientInfo(name:clientNameString, subnet:subName, address:clientIPStruct, publicKey:pubKeyString))
				}
			}
			return buildClients
		}
	}
	func revokeClient(pubKey:String) throws {
		try env.transact(readOnly:false) { someTrans in
			let subNameCursor = try clientPub_subnetName.cursor(tx:someTrans)
			let cliNameCursor = try clientPub_clientName.cursor(tx:someTrans)
			let pubIPCursor = try clientPub_clientIPv6.cursor(tx:someTrans)
			let ipPubCursor = try clientIPv6_clientPub.cursor(tx:someTrans)
			
			_ = try subNameCursor.get(.setKey, key:pubKey)
			try subNameCursor.deleteCurrent()
			
			let cliName = try cliNameCursor.get(.setKey, key:pubKey).value
			try cliNameCursor.deleteCurrent()
						
			let addr = try pubIPCursor.get(.setKey, key:pubKey).value
			try pubIPCursor.deleteCurrent()
			
			_ = try ipPubCursor.get(.setKey, key:addr)
			try ipPubCursor.deleteCurrent()
		}
	}	

	//validation
	func validateUnused(address:AddressV6) throws -> Bool {
		return try clientIPv6_clientPub.contains(key:address, tx:nil)
	}
	func validateNonOverlapping(subnet:NetworkV6) throws -> Bool {
		try env.transact(readOnly:true) { someTrans in
			//validate no overlapping subnets
			let subnetCursor = try subnetName_subnetNetworkV6.cursor(tx:someTrans)
			for kv in subnetCursor {
				guard let curNet = NetworkV6(data:kv.value) else {
					throw WireguardError.internalFailure
				}
				if curNet.overlapsWith(subnet) == true {
					return false
				}
			}
			return true
		}

	}
}