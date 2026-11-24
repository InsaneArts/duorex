import Testing
@testable import duorex

private let duo = Device(udid: "AAAA0000-0000-0000-0000-000000000001", name: "duorex Duo", type: Simulators.duoType)
private let mine = Device(udid: "AAAA0000-0000-0000-0000-000000000002", name: "My iPhone", type: "com.apple.CoreSimulator.SimDeviceType.iPhone-17")
private let pro = Device(udid: "AAAA0000-0000-0000-0000-000000000003", name: "duorex iPhone 18 Pro", type: "com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro")
private let types = [(name: "iPhone 18 Pro", identifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro"),
                     (name: "iPhone Air", identifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-Air"),
                     (name: "iPad Air 11-inch (M4)", identifier: "com.apple.CoreSimulator.SimDeviceType.iPad-Air-11-inch-M4"),
                     (name: "iPhone Duo", identifier: Simulators.duoType)]

@Test func `a simulator is found by its name or its UDID`() {
    #expect(Simulators.choose("My iPhone", simulators: [duo, mine], types: types) == .existing(mine))
    #expect(Simulators.choose(mine.udid.lowercased(), simulators: [duo, mine], types: types) == .existing(mine))
}

@Test func `a model stands for duorex's own simulator of it`() {
    #expect(Simulators.choose("iPhone 18 Pro", simulators: [duo, pro], types: types) == .existing(pro))
}

@Test func `a model with no simulator yet is made, with duorex's name for it`() {
    #expect(Simulators.choose("iPhone Air", simulators: [duo], types: types)
            == .make(name: "duorex iPhone Air", type: "com.apple.CoreSimulator.SimDeviceType.iPhone-Air"))
}

@Test func `iPhone Duo is duorex's first device, under its first name`() {
    #expect(Simulators.choose("iPhone Duo", simulators: [duo], types: types) == .existing(duo))
    #expect(Simulators.choose("duorex Duo", simulators: [], types: types) == .make(name: "duorex Duo", type: Simulators.duoType))
}

@Test func `only iPhones are made, and an unknown name stands for nothing`() {
    #expect(Simulators.choose("iPad Air 11-inch (M4)", simulators: [], types: types) == nil)
    #expect(Simulators.choose("Phone 18", simulators: [duo], types: types) == nil)
}

@Test func `a device knows whether it is the Duo`() {
    #expect(duo.isDuo)
    #expect(!pro.isDuo)
}
