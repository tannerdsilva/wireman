import RapidLMDB
import Foundation
import AddressKit
import TToolkit

let buildVersion:UInt64 = 2

class WireguardDatabase {
	enum WireguardError:Error {
		case internalFailure
		case addressNotInSubnet
		case subnetOverlaps
		case nameExistsInSubnet
		case addressAlreadyAssigned
		case addressNotUsable
	}
	enum Metadatas:String {
		case dbVersion = "databaseVersion" //UInt64
		case primaryInterface = "primaryWGInterface" //string
		case server_endpoint_domain = "server_endpoint_domain" //String
		case listenPort = "server_public_listenPort" //UInt16
		case ipv4_scope = "server_ipv4_scope" //NetworkV4 where address == servers own internal IP
		case ipv4_secure_scope = "server_ipv4_secure_scope" //a subset of the ipv4 scope representing a range of IP's which are not to be randomly generated
		case ipv6_scope = "server_ipv6_scope" //networkV6 where address == servers own internal IP
		case serverPublicKey = "server_public_key" //string
	}
	func primaryInterfaceName(_ tx:Transaction? = nil) throws -> String {
		return try self.metadata.get(type:String.self, forKey:Metadatas.primaryInterface.rawValue, tx:tx)!
	}
	func getPublicEndpointDomain(_ tx:Transaction? = nil) throws -> String {
		if tx == nil {
			return try env.transact(readOnly:true) { someTrans in
				let domain = try self.metadata.get(type:String.self, forKey:Metadatas.server_endpoint_domain.rawValue, tx:someTrans)!
				let port = try self.metadata.get(type:UInt16.self, forKey:Metadatas.listenPort.rawValue, tx:someTrans)!
				return domain + ":" + String(port)
			}
		} else {
			let domain = try self.metadata.get(type:String.self, forKey:Metadatas.server_endpoint_domain.rawValue, tx:tx)!
			let port = try self.metadata.get(type:UInt16.self, forKey:Metadatas.listenPort.rawValue, tx:tx)!
			return domain + ":" + String(port)
		}
	}
	func getServerEndpointListenPort(_ tx:Transaction? = nil) throws -> UInt16 {
		return try self.metadata.get(type:UInt16.self, forKey:Metadatas.listenPort.rawValue, tx:tx)!
	}
	func ipv6Scope(_ tx:Transaction? = nil) throws -> NetworkV6 {
		return try self.metadata.get(type:NetworkV6.self, forKey:Metadatas.ipv6_scope.rawValue, tx:tx)!
	}
	func ipv4Scope(_ tx:Transaction? = nil) throws -> NetworkV4 {
		return try self.metadata.get(type:NetworkV4.self, forKey:Metadatas.ipv4_scope.rawValue, tx:tx)!
	}
	func ipv4SecureScope(_ tx:Transaction? = nil) throws -> NetworkV4 {
		return try self.metadata.get(type:NetworkV4.self, forKey:Metadatas.ipv4_secure_scope.rawValue, tx:tx)!
	}
	func getServerPublicKey(_ tx:Transaction? = nil) throws -> String {
		return try self.metadata.get(type:String.self, forKey:Metadatas.serverPublicKey.rawValue, tx:tx)!
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
	
	//subnetting is for ipv6 only
	let subnetName_subnetNetworkV6:Database // string -> NetworkV6
	
	let clientPub_subnetName:Database
	let clientPub_clientName:Database

	//ipv6 addressing required
	let clientPub_clientIPv6:Database
	let clientIPv6_clientPub:Database
	
	//ipv4 addressing not necessary for each client
	let clientPub_clientIPv4:Database
	let clientIPv4_clientPub:Database
	
	let clientPub_email:Database //(optional string)
	let clientPub_createdOn:Database
	
	init(_ dbPath:URL) throws {
		if FileManager.default.fileExists(atPath:dbPath.path) == false {
			let fh = try! POSIX.openFileHandle(path:dbPath.path, flags:[.create, .readWrite], permissions:[.userRead, .userWrite])
			fh.closeFileHandle()
		}
		let makeEnv = try Environment(path:dbPath.path, flags:[.noSubDir])
		self.env = makeEnv
		
		let dbs = try makeEnv.transact(readOnly:false) { someTrans -> [Database] in
			let meta = try makeEnv.openDatabase(named:"metadata", flags:[.create], tx:someTrans)
			let subName_cidrV6 = try makeEnv.openDatabase(named:"subName_subnetV6", flags:[.create], tx:someTrans)
			
			let pub_sub = try makeEnv.openDatabase(named:"pub_sub", flags:[.create], tx:someTrans)
			let pub_name = try makeEnv.openDatabase(named:"pub_name", flags:[.create], tx:someTrans)
			
			let pub_ipv6 = try makeEnv.openDatabase(named:"pub_ipv6", flags:[.create], tx:someTrans)
			let ipv6_pub = try makeEnv.openDatabase(named:"ipv6_pub", flags:[.create], tx:someTrans)
			
			let pub_ipv4 = try makeEnv.openDatabase(named:"pub_ipv4", flags:[.create], tx:someTrans)
			let ipv4_pub = try makeEnv.openDatabase(named:"ipv4_pub", flags:[.create], tx:someTrans)
			
			let pub_email = try makeEnv.openDatabase(named:"pub_email", flags:[.create], tx:someTrans)
			let pub_create = try makeEnv.openDatabase(named:"pub_create", flags:[.create], tx:someTrans)
			
			func migrateDatabase(version:UInt64?) throws -> UInt64 {
				switch version {
					case nil:
						return buildVersion
					case 1:
						let pubNameCursor = try pub_name.cursor(tx:someTrans)
						let pubCreateCursor = try pub_create.cursor(tx:someTrans)
						let baseDate = Date()
						for record in pubNameCursor {
							do {
								try pubCreateCursor.set(value:Date(), forKey:record.key, flags:[.noOverwrite])
							} catch LMDBError.keyExists {}
						}
						return 2
					//no other versions to handle at this time
					default:
						return buildVersion
				}
			}
			var curVersion:UInt64
			repeat {
				curVersion = try migrateDatabase(version:try? meta.get(type:UInt64.self, forKey:Metadatas.dbVersion.rawValue, tx:someTrans)!)
				try meta.set(value:curVersion, forKey:Metadatas.dbVersion.rawValue, tx:someTrans)
			} while curVersion != buildVersion
			
			return [meta, subName_cidrV6, pub_sub, pub_name, pub_ipv6, ipv6_pub, pub_ipv4, ipv4_pub, pub_email, pub_create]
		}
		
		self.metadata = dbs[0]
		self.subnetName_subnetNetworkV6 = dbs[1]
		self.clientPub_subnetName = dbs[2]
		self.clientPub_clientName = dbs[3]
		self.clientPub_clientIPv6 = dbs[4]
		self.clientIPv6_clientPub = dbs[5]
		self.clientPub_clientIPv4 = dbs[6]
		self.clientIPv4_clientPub = dbs[7]
		self.clientPub_email = dbs[8]
		self.clientPub_createdOn = dbs[9]
	}
	
	//bootstrapping
	func assignInitialConfiguration(primaryInterface:String, publicEndpoint:String, publicListenPort:UInt16, ipv4Scope:NetworkV4, ipv4SecureScope:NetworkV4, ipv6Scope:NetworkV6, publicKey:String) throws {
		try env.transact(readOnly:false) { someTrans in
			try self.metadata.set(value:primaryInterface, forKey:Metadatas.primaryInterface.rawValue, flags:[.noOverwrite], tx:someTrans)
			try self.metadata.set(value:publicEndpoint, forKey:Metadatas.server_endpoint_domain.rawValue, flags:[.noOverwrite], tx:someTrans)
			try self.metadata.set(value:publicListenPort, forKey:Metadatas.listenPort.rawValue, flags:[.noOverwrite], tx:someTrans)
			try self.metadata.set(value:ipv4Scope, forKey:Metadatas.ipv4_scope.rawValue, flags:[.noOverwrite], tx:someTrans)
			try self.metadata.set(value:ipv4SecureScope, forKey:Metadatas.ipv4_secure_scope.rawValue, flags:[.noOverwrite], tx:someTrans)
			try self.metadata.set(value:ipv6Scope, forKey:Metadatas.ipv6_scope.rawValue, flags:[.noOverwrite], tx:someTrans)
			try self.metadata.set(value:publicKey, forKey:Metadatas.serverPublicKey.rawValue, flags:[.noOverwrite], tx:someTrans)
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
			let serverAddress = try self.ipv6Scope().address
			guard subnet.contains(serverAddress) == false else {
				throw WireguardError.subnetOverlaps
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
			let pubIP6Cursor = try clientPub_clientIPv6.cursor(tx:someTrans)
			let ip6PubCursor = try clientIPv6_clientPub.cursor(tx:someTrans)
			let pubIP4Cursor = try clientPub_clientIPv4.cursor(tx:someTrans)
			let ip4PubCursor = try clientIPv4_clientPub.cursor(tx:someTrans)
			let pubEmailCursor = try clientPub_email.cursor(tx:someTrans)
			let pubCreatedCursor = try clientPub_createdOn.cursor(tx:someTrans)
			
			func revoke(pubKey:Data) throws {			
				let cliName = try cliNameCursor.get(.setKey, key:pubKey).value
				try cliNameCursor.deleteCurrent()
			
				//delete the ipv6 related data
				let addr6 = try pubIP6Cursor.get(.setKey, key:pubKey).value
				try pubIP6Cursor.deleteCurrent()
			
				_ = try ip6PubCursor.get(.setKey, key:addr6)
				try ip6PubCursor.deleteCurrent()
				
				//delete the ipV4 related data if there has been one assigned
				do {
					let addr4 = try pubIP4Cursor.get(.setKey, key:pubKey).value
					try pubIP4Cursor.deleteCurrent()
					
					_ = try ip4PubCursor.get(.setKey, key:addr4).value
					try ip4PubCursor.deleteCurrent()
				} catch LMDBError.notFound {}
				
				//delete email related data
				do {
					_ = try pubEmailCursor.get(.setKey, key:pubKey).value
					try pubEmailCursor.deleteCurrent()
				} catch LMDBError.notFound {}
				
				_ = try pubCreatedCursor.get(.setKey, key:pubKey).value
				try pubCreatedCursor.deleteCurrent()
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
		let createdOn:Date
		var name:String
		let subnet:String
		let address4:AddressKit.AddressV4?
		let address6:AddressKit.AddressV6
		let publicKey:String
		
		var email:String?
		
		func hash(into hasher:inout Hasher) {
			hasher.combine(publicKey)
		}
		
		static func == (lhs:ClientInfo, rhs:ClientInfo) -> Bool {
			return lhs.publicKey == rhs.publicKey
		}
	}
	func makeClient(_ clientInfo:ClientInfo) throws {
		try env.transact(readOnly:false) { someTrans in
			//validate that the specified subnet name exists
			guard let getNetwork6 = try self.subnetName_subnetNetworkV6.get(type:NetworkV6.self, forKey:clientInfo.subnet, tx:someTrans) else {
				throw WireguardError.internalFailure
			}
			//validate that the address is within the subnet
			guard getNetwork6.contains(clientInfo.address6) else {
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
			//validate that the ipv6 address has not already been assigned
			let serverAddress6 = try self.ipv6Scope(someTrans).address
			guard try self.clientIPv6_clientPub.contains(key:clientInfo.address6, tx:someTrans) == false && serverAddress6 != clientInfo.address6 else {
				throw WireguardError.addressAlreadyAssigned
			}
			
			//validate that the ipv4 address has not already been assigned if one was specified
			if clientInfo.address4 != nil {
				//ipv4 address must be within the usable range of the scop
				guard try self.ipv4Scope(someTrans).usableRange.contains(clientInfo.address4!) else {
					throw WireguardError.addressNotUsable
				}
				let serverAddress4 = try self.ipv4Scope(someTrans).address
				guard try self.clientIPv4_clientPub.contains(key:clientInfo.address4!, tx:someTrans) == false, clientInfo.address4! != serverAddress4 else {
					throw WireguardError.addressAlreadyAssigned
				}
			}
			
			//validation passed: install the client in the database
			try subnetNameCursor.set(value:clientInfo.subnet, forKey:clientInfo.publicKey)
			try clientNameCursor.set(value:clientInfo.name, forKey:clientInfo.publicKey)
			try self.clientIPv6_clientPub.set(value:clientInfo.publicKey, forKey:clientInfo.address6, tx:someTrans)
			try self.clientPub_clientIPv6.set(value:clientInfo.address6, forKey:clientInfo.publicKey, tx:someTrans)
			
			try self.clientPub_createdOn.set(value:clientInfo.createdOn, forKey:clientInfo.publicKey, tx:someTrans)
			
			if clientInfo.email != nil {
				try self.clientPub_email.set(value:clientInfo.email!, forKey:clientInfo.publicKey, tx:someTrans)
			}
			
			if clientInfo.address4 != nil {
				try self.clientPub_clientIPv4.set(value:clientInfo.address4!, forKey:clientInfo.publicKey, tx:someTrans)
				try self.clientIPv4_clientPub.set(value:clientInfo.publicKey, forKey:clientInfo.address4!, tx:someTrans)
			}
		}
	}
	func getClients(subnet:String) throws -> Set<ClientInfo> {
		try env.transact(readOnly:true) { someTrans -> Set<ClientInfo> in
			var buildClients = Set<ClientInfo>()
		
			let subNameCursor = try clientPub_subnetName.cursor(tx:someTrans)
			let cliNameCursor = try clientPub_clientName.cursor(tx:someTrans)
			let clientPubIP6 = try clientPub_clientIPv6.cursor(tx:someTrans)
			let clientPubIP4 = try clientPub_clientIPv4.cursor(tx:someTrans)
			let clientEmailCursor = try clientPub_email.cursor(tx:someTrans)
			let clientCreatedCursor = try clientPub_createdOn.cursor(tx:someTrans)
			
			for subRecord in subNameCursor {
				guard let subName = String(data:subRecord.value) else {
					throw WireguardError.internalFailure
				}
				//if this client is in the subnet the user is targeting...
				if subName == subnet {
					//fetch all the other data
					let clientName = try cliNameCursor.get(.setKey, key:subRecord.key).value
					let clientIP = try clientPubIP6.get(.setKey, key:subRecord.key).value
					let clientCreated = try clientCreatedCursor.get(.setKey, key:subRecord.key).value
					guard let pubKeyString = String(data:subRecord.key), let clientNameString = String(data:clientName), let clientIPStruct6 = AddressV6(data:clientIP), let createdDate = Date(data:clientCreated) else {
						throw WireguardError.internalFailure
					}
					
					let ip4:AddressKit.AddressV4?
					do {
						ip4 = AddressV4(data:try clientPubIP4.get(.setKey, key:subRecord.key).value)
					} catch LMDBError.notFound {
						ip4 = nil
					}
					
					let email:String?
					do {
						email = String(data:try clientEmailCursor.get(.setKey, key:subRecord.key).value)
					} catch LMDBError.notFound {
						email = nil
					}
					buildClients.update(with:ClientInfo(createdOn:createdDate, name:clientNameString, subnet:subName, address4:ip4, address6:clientIPStruct6, publicKey:pubKeyString, email:email))
				}
			}
			return buildClients
		}
	}
	func revokeClient(pubKey:String) throws {
		try env.transact(readOnly:false) { someTrans in
			let subNameCursor = try clientPub_subnetName.cursor(tx:someTrans)
			let cliNameCursor = try clientPub_clientName.cursor(tx:someTrans)
			let pubIP6Cursor = try clientPub_clientIPv6.cursor(tx:someTrans)
			let ip6PubCursor = try clientIPv6_clientPub.cursor(tx:someTrans)
			let pubIP4Cursor = try clientPub_clientIPv4.cursor(tx:someTrans)
			let ip4PubCursor = try clientIPv4_clientPub.cursor(tx:someTrans)
			let pubEmailCursor = try clientPub_email.cursor(tx:someTrans)
			let pubCreatedOn = try clientPub_createdOn.cursor(tx:someTrans)
			
			_ = try subNameCursor.get(.setKey, key:pubKey)
			try subNameCursor.deleteCurrent()
			
			let cliName = try cliNameCursor.get(.setKey, key:pubKey).value
			try cliNameCursor.deleteCurrent()
			
			let addr6 = try pubIP6Cursor.get(.setKey, key:pubKey).value
			try pubIP6Cursor.deleteCurrent()
			
			_ = try ip6PubCursor.get(.setKey, key:addr6)
			try ip6PubCursor.deleteCurrent()
			
			//delete the ipV4 related data if there has been one assigned
			do {
				let addr4 = try pubIP4Cursor.get(.setKey, key:pubKey).value
				try pubIP4Cursor.deleteCurrent()
				
				_ = try ip4PubCursor.get(.setKey, key:addr4)
				try ip4PubCursor.deleteCurrent()
			} catch LMDBError.notFound {}
			
			do {
				_ = try pubEmailCursor.get(.setKey, key:pubKey)
				try pubEmailCursor.deleteCurrent()
			} catch LMDBError.notFound {}
			
			_ = try pubCreatedOn.get(.setKey, key:pubKey).value
			try pubCreatedOn.deleteCurrent()
		}
	}	

	//validation
	func isAddress6Used(_ address:AddressV6) throws -> Bool {
		try env.transact(readOnly:true) { someTrans in
			let serverAddress6 = try self.ipv6Scope(someTrans).address
			return try clientIPv6_clientPub.contains(key:address, tx:someTrans) || serverAddress6 == address
		}
	}
	func isAddress4Used(_ address:AddressKit.AddressV4) throws -> Bool {
		try env.transact(readOnly:true) { someTrans in
			let serverAddress4 = try self.ipv4Scope(someTrans).address
			return try clientIPv4_clientPub.contains(key:address, tx:someTrans) || serverAddress4 == address
		}
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