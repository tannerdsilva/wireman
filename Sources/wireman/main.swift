import Foundation
import Commander
import SwiftSlash
import AddressKit
import TToolkit
import RapidLMDB

fileprivate func validateRoot() {
	//validate that we're root
	guard let user = String(validatingUTF8:getpwuid(geteuid()).pointee.pw_name), user == "root" else {
		print(Colors.Red("you must run this utility as root"))
		exit(1)
	}
}
validateRoot()

extension NetworkV6 {
	func maskingAddress() -> NetworkV6 {
		return NetworkV6(address:AddressV6(self.address.integer & self.netmask.integer), netmask:self.netmask)!
	}
}

extension NetworkV4 {
	func maskingAddress() -> NetworkV4 {
		return NetworkV4(address:AddressV4(self.address.integer & self.netmask.integer), netmask:self.netmask)!
	}
}

fileprivate let tempDir = FileManager.default.temporaryDirectory

Group {	
	$0.command("subnet_make",
		Argument<String>("name", description:"the name of the subnet to create"),
		Flag("non-interactive", default:false, description:"no not prompt for user input - automatically pick a subnet of prefix length 112")
	) { subnetName, nonInteractive in
		let database = try WireguardDatabase()
	
		let ipv6Scope = try database.ipv6Scope()
		
		if (nonInteractive == false) {
			print(Colors.dim("ipv6 scope for this VPN: \(ipv6Scope.cidrString)"))
		}	
		
		var randomAddress:AddressV6
		var suggestedSubnet:NetworkV6?
		repeat {
			randomAddress = ipv6Scope.range.randomAddress()
			suggestedSubnet = NetworkV6(cidr:randomAddress.string + "/112")?.maskingAddress()
		} while try suggestedSubnet != nil && database.validateNonOverlapping(subnet:suggestedSubnet!) == false
		
		if (nonInteractive == false) { 
			print("define new subnet cidrV6 [\(suggestedSubnet!.cidrString)]: ", terminator:"")
			var suggestionOverride = readLine()
			if suggestionOverride != nil && suggestionOverride!.count > 0, let overrideNetwork = NetworkV6(cidr:suggestionOverride!) {
				guard try! database.validateNonOverlapping(subnet:overrideNetwork) == true else {
					print(Colors.Red("This subnet overlaps with another subnet. try again"))
					exit(5)
				}
				suggestedSubnet = overrideNetwork.maskingAddress()
			}
		}
		do {
			try database.createSubnet(name:subnetName, subnet:suggestedSubnet!)
		} catch LMDBError.keyExists {
			print(Colors.Red("a subnet named \(subnetName) already exists. please specify a different name"))
		}
	}
	$0.command("list") {
		let database = try WireguardDatabase()
		for curSubnet in try database.getSubnets().sorted(by: { $0.key > $1.key }) {
			print(Colors.Cyan("\(curSubnet.key)"))
			print(Colors.Yellow("\tCIDR:\t\(curSubnet.value.cidrString)"))
			let clients = try database.getClients(subnet:curSubnet.key)
			for client in clients.sorted(by: { $0.name < $1.name }) {
				print("-\t\t\(client.name)\t\(client.address6.string)\t\(client.address4?.string)")
			}
		}
	}
	$0.command("subnet_delete",
		Argument<String>("name", description:"The subnet name to delete")
	) { snName in
		let database = try WireguardDatabase()
		let interface = try database.primaryInterfaceName()
		do {
			let revokedClientPubs = try database.revokeSubnet(name:snName)
			for curPubKey in revokedClientPubs {
				if try Command(command:"/usr/bin/wg set \(interface) peer \(curPubKey) remove")!.runSync().succeeded == false {
					print("!!failed to set new config with /usr/bin/wg")
					exit(15)
				}
			}
			if revokedClientPubs.count > 0 {
				if try Command(bash:"/usr/bin/wg-quick save \(interface)").runSync().succeeded == false {
					print("!!failed to sync config")
					exit(8)
				}
			}
		} catch LMDBError.notFound {
			print(Colors.Red("\(snName) is not a valid subnet name. please specify one of the following subnet names:"))
			for curSubnet in try database.getSubnets() {
				print(Colors.Cyan("\t\(curSubnet.key)"))
			}
			exit(5)
		}
	}

	$0.command("client_make") {
		let database = try WireguardDatabase()
		let subnets = try database.getSubnets()
		guard subnets.count > 0 else {
			print(Colors.Red("subnets must exist to create a client"))
			exit(40)
		}
		print("Subnets configured for \(try! database.primaryInterfaceName()) ===================")
		for sub in subnets.sorted(by: { $0.key < $1.key }) {
			print("\t- \(sub.key)")
		}
	
		var subnetName:String? = nil
		repeat {
			print("subnet name: ", terminator:"")
			subnetName = readLine()
		} while subnetName == nil || subnetName!.count == 0
		
		guard let addressRange6 = subnets[subnetName!] else {
			print("\(subnetName) is not a valid subnet name")
			exit(5)
		}
		
		let clientNames = Dictionary(grouping:try database.getClients(subnet:subnetName!), by: { $0.name })
		var clientName:String? = nil
		repeat {
			print("client name: ", terminator:"")
			clientName = readLine()
		} while clientName == nil || clientName!.count == 0
		guard clientNames[clientName!] == nil else {
			print("this client name already exists")
			exit(9)
		}
		let addressRange4 = try database.ipv4Scope().usableRange
		let secureScope = try database.ipv4SecureScope()
		print(Colors.Green("IPv4 secure scope: \(secureScope.cidrString)"))
		print(Colors.Yellow("Full IPv4 scope: \(try database.ipv4Scope().cidrString)"))
		
		var useAddress4:AddressKit.AddressV4?
		repeat {
			useAddress4 = addressRange4.randomAddress()
		} while try database.isAddress4Used(useAddress4!) && secureScope.contains(useAddress4!) == false
		print("client address v4 (type 'x' for none) [\(useAddress4!.string)]: ", terminator:"")
		var clientAddressString4:String? = readLine()
		if clientAddressString4 == "x" {
			useAddress4 = nil
		} else if clientAddressString4 != nil && clientAddressString4!.count != 0, let parseIt = AddressKit.AddressV4(clientAddressString4!) {
			guard addressRange4.contains(parseIt) else {
				print("this address is out of range for this subnet")
				exit(12)
			}
			guard try database.isAddress4Used(parseIt) == false else {
				print("the specified address is already used")
				exit(15)
			}
			useAddress4 = parseIt
		}
		
		print(Colors.Yellow("Full IPv6 scope for \(subnetName!): \(addressRange6.cidrString)"))
		var useAddress6:AddressV6
		repeat {
			useAddress6 = addressRange6.range.randomAddress()
		} while try database.isAddress6Used(useAddress6)
		print("client address [\(useAddress6.string)]: ", terminator:"")
		var clientAddressString6:String? = readLine()
		if clientAddressString6 != nil && clientAddressString6!.count != 0, let parseIt = AddressV6(clientAddressString6!) {
			guard addressRange6.contains(parseIt) else {
				print("this address is out of range for this subnet")
				exit(12)
			}
			useAddress6 = parseIt
		}

		print("keepalive? [y/n]: ", terminator:"")
		let shouldKeepalive = readLine()!.lowercased() == "y"
	
		let privateKey = try! Command(bash:"wg genkey").runSync().stdout.compactMap { String(data:$0, encoding:.utf8) }.first!
		let publicKey = try! Command(bash:"echo \(privateKey) | wg pubkey").runSync().stdout.compactMap { String(data:$0, encoding:.utf8) }.first!
		let psk = try! Command(bash:"wg genpsk").runSync().stdout.first!
		
		let pskString = String(data:psk, encoding:.utf8)!
		let pskPath = tempDir.appendingPathComponent(String.random())
		try psk.write(to:pskPath)
		defer {
			try! FileManager.default.removeItem(at:pskPath)
		}
		print("\n\n----------------------------\n\n")
		var buildConfig = "[Interface]\n"
		buildConfig += "PrivateKey = \(privateKey)\n"
		buildConfig += "Address = \(useAddress6.string)/128\n"
		if (useAddress4 != nil) {
			buildConfig += "Address = \(useAddress4!.string)/32\n"
		}
		buildConfig += "[Peer]\n"
		buildConfig += "PublicKey = \(try database.getServerPublicKey())\n"
		buildConfig += "PresharedKey = \(pskString)\n"
		if (useAddress4 != nil) {
			buildConfig += "AllowedIPs = \(try database.ipv4Scope().maskingAddress().cidrString)\n"
		}
		buildConfig += "AllowedIPs = \(try database.ipv6Scope().maskingAddress().cidrString)\n"
		buildConfig += "Endpoint = \(try database.getPublicEndpointDomain())\n"
		if (shouldKeepalive) {
			buildConfig += "PersistentKeepalive = 25"
		}
	
		let interface = try database.primaryInterfaceName()
		let commandString:String
		if useAddress4 == nil {
			commandString = "/usr/bin/wg set \(interface) peer \(publicKey) allowed-ips \(useAddress6.string)/128 preshared-key \(pskPath.path)"
		} else {
			commandString = "/usr/bin/wg set \(interface) peer \(publicKey) allowed-ips \(useAddress6.string)/128,\(useAddress4!.string)/32 preshared-key \(pskPath.path)"
		}
		if try Command(command:commandString)!.runSync().succeeded == false {
			print("!!failed to set new config with /usr/bin/wg")
			exit(15)
		}
		if try Command(bash:"/usr/bin/wg-quick save \(interface)").runSync().succeeded == false {
			print("!!failed to sync config")
			exit(8)
		}
		
		let newClientInfo = WireguardDatabase.ClientInfo(name:clientName!, subnet:subnetName!, address4:useAddress4, address6:useAddress6, publicKey:publicKey)
		
		do {
			try database.makeClient(newClientInfo)
		} catch _ {
			try Command(command:"/usr/bin/wg set \(interface) peer \(publicKey) remove")!.runSync()
			try Command(bash:"/usr/bin/wg-quick save \(interface)").runSync().succeeded == false
			print("failed to save client info to database")
		}
		
		print(buildConfig)
		print("\n\n")
	}
	
	$0.command("client_revoke",
		Argument<String>("subnet", description:"the subnet name that the client belongs to"),
		Argument<String>("client name", description:"the name of the client to revoke")
	) { subnetName, clientName in
		let database = try WireguardDatabase()
		let interface = try! database.primaryInterfaceName()
		let getSubnets = try database.getSubnets()
		guard getSubnets[subnetName] != nil else {
			print(Colors.Red("\(subnetName) is not a valid subnet name. please specify one of the following subnet names:"))
			for curSubnet in getSubnets.sorted(by: { $0.key < $1.key }) {
				print(Colors.Cyan("-\t\(curSubnet.key)"))
			}
			exit(10)
		}
		let clients = Dictionary(grouping:try database.getClients(subnet:subnetName), by: { $0.name })
		guard clients[clientName] != nil else {
			print(Colors.Red("\(clientName) is not a valid client name. please specify one of the following client names:"))
			for curClient in clients.sorted(by: { $0.key < $1.key }) {
				print(Colors.Cyan("-\t\(curClient.key)"))
			}
			exit(11)
		}
		
		let pubKey = clients[clientName]!.first!.publicKey
		if try Command(command:"/usr/bin/wg set \(interface) peer \(pubKey) remove")!.runSync().succeeded == false {
			print("!!failed to set new config with /usr/bin/wg")
			exit(15)
		}
		if try Command(bash:"/usr/bin/wg-quick save \(interface)").runSync().succeeded == false {
			print("!!failed to sync config")
			exit(8)
		}
		try database.revokeClient(pubKey:pubKey)
	}

	$0.command("initialize") {
		//validate that the database is new
		let database = try! WireguardDatabase()
		guard database.needsInitialConfiguration == true else {
			print(Colors.Red("there is already a server configured. please delete the database at \(WireguardDatabase.databasePath()) to run this command"))
			exit(6)
		}
		
		//validate that we're root
		print("configuring new wireguard server instance")
		
		//ask for the interface name
		var interfaceName:String? = nil
		repeat {
			print("interface name: ", terminator:"")
			interfaceName = readLine()
		} while interfaceName == nil || interfaceName!.count == 0
		
		//ask for the public endpoint
		var endpoint:String? = nil
		repeat {
			print("public endpoint dns name: ", terminator:"")
			endpoint = readLine()
		} while (endpoint == nil || endpoint!.count == 0)
		
		//ask for the servers listening port
		var publicListenPort:UInt16? = nil
		repeat {
			print("public listening port: ", terminator:"")
			if let listenString = readLine(), let asInt = UInt16(listenString) {
				publicListenPort = asInt
			}
		} while publicListenPort == nil
		
		//ask for the client ipv4 scope
		var ipv4Scope:NetworkV4? = nil
		repeat {
			print("vpn client ipv4 scope (cidr): ", terminator:"")
			if let asString = readLine(), let asNetwork = NetworkV4(cidr:asString) {
				ipv4Scope = asNetwork
			}
		} while ipv4Scope == nil

		var ipv4SecureScope:NetworkV4? = nil
		repeat {
			print("vpn client ipv4 SECURE scope (cidr): ", terminator:"")
			if let asString = readLine(), let asNetwork = NetworkV4(cidr:asString) {
				ipv4SecureScope = asNetwork
			}
		} while ipv4SecureScope == nil

		//ask for the client ipv6 scope
		var ipv6Scope:NetworkV6? = nil
		repeat {
			print("vpn client ipv6 scope (cidr): ", terminator:"")
			if let asString = readLine(), let asNetwork = NetworkV6(cidr:asString) {
				ipv6Scope = asNetwork
			}
		} while ipv6Scope == nil
		
		print("generating private key")
		let privateKey = try! Command(bash:"wg genkey").runSync().stdout.compactMap { String(data:$0, encoding:.utf8) }.first!
		print("generating public key")
		let publicKey = try! Command(bash:"echo \(privateKey) | wg pubkey").runSync().stdout.compactMap { String(data:$0, encoding:.utf8) }.first!

		var buildConfig = ""
		buildConfig += "[Interface]\n"
		buildConfig += "ListenPort = \(publicListenPort!)\n"
		buildConfig += "Address = \(ipv4Scope!.cidrString)\n"
		buildConfig += "Address = \(ipv6Scope!.cidrString)\n"
		buildConfig += "PrivateKey = \(privateKey)\n"
		let configData = buildConfig.data(using:.utf8)!
		
		if FileManager.default.fileExists(atPath:"/etc/wireguard") == false {
			try POSIX.createDirectory(at:"/etc/wireguard", permissions:[.userRead, .userWrite])
		}
				
		let privateKeyURL = URL(fileURLWithPath:"/etc/wireguard/private.key")
		let privateKeyData = privateKey.data(using:.utf8)!
		let pkFH = try! POSIX.openFileHandle(path:privateKeyURL.path, flags:[.writeOnly, .create], permissions:[.userRead, .userWrite])
		try pkFH.writeFileHandle(privateKeyData)
		pkFH.closeFileHandle()
		
		let publicKeyURL = URL(fileURLWithPath:"/etc/wireguard/public.key")
		let publicKeyData = publicKey.data(using:.utf8)!
		let pubFH = try! POSIX.openFileHandle(path:publicKeyURL.path, flags:[.writeOnly, .create], permissions:[.userRead, .userWrite])
		try pubFH.writeFileHandle(publicKeyData)
		pubFH.closeFileHandle()

		let configURL = URL(fileURLWithPath:"/etc/wireguard/\(interfaceName!).conf")
		let confFH = try! POSIX.openFileHandle(path:configURL.path, flags:[.writeOnly, .create], permissions:[.userRead, .userWrite])
		try confFH.writeFileHandle(buildConfig)
		confFH.closeFileHandle()
		
		try! database.assignInitialConfiguration(primaryInterface:interfaceName!, publicEndpoint:endpoint!, publicListenPort:publicListenPort!, ipv4Scope:ipv4Scope!, ipv4SecureScope:ipv4SecureScope!, ipv6Scope:ipv6Scope!, publicKey:publicKey)
		
		try! Command(bash:"systemctl enable wg-quick@\(interfaceName!)").runSync()
		try! Command(bash:"systemctl start wg-quick@\(interfaceName!)").runSync()
	}
}.run()