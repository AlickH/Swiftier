import Foundation

@objc(HelperProtocol)
protocol HelperProtocol {
    func getRunningInfo(reply: @escaping (String?) -> Void)
}

let kHelperMachServiceName = "com.alick.swiftier.helper"
let connection = NSXPCConnection(machServiceName: kHelperMachServiceName, options: .privileged)
connection.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
connection.resume()

let helper = connection.remoteObjectProxyWithErrorHandler { error in
    print("XPC Error: \(error)")
    exit(1)
} as! HelperProtocol

helper.getRunningInfo { info in
    if let info = info {
        print(info)
        exit(0)
    } else {
        print("nil")
        exit(1)
    }
}

RunLoop.current.run(until: Date(timeIntervalSinceNow: 5))
print("Timeout")
exit(1)
