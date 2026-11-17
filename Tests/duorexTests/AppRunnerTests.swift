import Foundation
import Testing
@testable import duorex

private func list(schemes: [String], project: String = "Notes") -> Data {
    try! JSONSerialization.data(withJSONObject: ["project": ["name": project, "schemes": schemes, "targets": schemes]])
}

@Test func `a project with one scheme builds that scheme`() throws {
    #expect(try AppRunner.scheme(fromList: list(schemes: ["Notes"]), wanted: nil) == "Notes")
}

@Test func `among several schemes, the one named like the project is built`() throws {
    #expect(try AppRunner.scheme(fromList: list(schemes: ["NotesKit", "Notes", "NotesTests"]), wanted: nil) == "Notes")
}

@Test func `a workspace's schemes are read the same way`() throws {
    let workspace = try JSONSerialization.data(withJSONObject: ["workspace": ["name": "Notes", "schemes": ["Notes", "Pods-Notes"]]])
    #expect(try AppRunner.scheme(fromList: workspace, wanted: nil) == "Notes")
}

@Test func `several schemes with no clear one ask for a choice`() {
    #expect(throws: DuoError.self) { try AppRunner.scheme(fromList: list(schemes: ["Free", "Pro"]), wanted: nil) }
    #expect(throws: DuoError.self) { try AppRunner.scheme(fromList: list(schemes: []), wanted: nil) }
}

@Test func `a wanted scheme must be one of the project's`() throws {
    #expect(try AppRunner.scheme(fromList: list(schemes: ["Free", "Pro"]), wanted: "Pro") == "Pro")
    #expect(throws: DuoError.self) { try AppRunner.scheme(fromList: list(schemes: ["Free", "Pro"]), wanted: "Plus") }
}

@Test func `the app is the scheme's application target, at its build folder`() throws {
    func target(_ name: String, type: String, wrapper: String, bundle: String) -> [String: Any] {
        ["action": "build", "target": name, "buildSettings": [
            "PRODUCT_TYPE": type, "TARGET_BUILD_DIR": "/Derived/Build/Products/Debug-iphonesimulator",
            "WRAPPER_NAME": wrapper, "PRODUCT_BUNDLE_IDENTIFIER": bundle,
        ]]
    }
    let settings = try JSONSerialization.data(withJSONObject: [
        target("NotesKit", type: "com.apple.product-type.framework", wrapper: "NotesKit.framework", bundle: "com.example.kit"),
        target("Notes", type: "com.apple.product-type.application", wrapper: "Notes.app", bundle: "com.example.notes"),
        target("NotesWatch", type: "com.apple.product-type.application", wrapper: "NotesWatch.app", bundle: "com.example.notes.watch"),
    ])
    #expect(try AppRunner.product(fromSettings: settings, scheme: "Notes")
        == AppRunner.App(path: "/Derived/Build/Products/Debug-iphonesimulator/Notes.app", bundleID: "com.example.notes"))
    let framework = try JSONSerialization.data(withJSONObject: [target("NotesKit", type: "com.apple.product-type.framework", wrapper: "NotesKit.framework", bundle: "k")])
    #expect(throws: DuoError.self) { try AppRunner.product(fromSettings: framework, scheme: "NotesKit") }
}

@Test func `a failed build is told by its errors, each once`() {
    let output = """
    CompileSwift normal arm64 /Notes/ContentView.swift
    /Notes/ContentView.swift:12:9: error: cannot find 'Texx' in scope
            Texx("Hello")
    /Notes/ContentView.swift:12:9: error: cannot find 'Texx' in scope
    warning: unused variable
    ** BUILD FAILED **
    """
    #expect(AppRunner.errors(in: output) == ["/Notes/ContentView.swift:12:9: error: cannot find 'Texx' in scope"])
}

@Test func `a folder with no project says how to go on`() {
    #expect(throws: DuoError.self) { try AppRunner.container(in: FileManager.default.temporaryDirectory.appendingPathComponent("duorex-empty-\(UUID().uuidString)")) }
}

@Test func `a built app is known by its Info.plist`() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("duorex-app-\(UUID().uuidString)/Notes.app")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
    #expect(throws: DuoError.self) { try AppRunner.app(at: folder.path) }
    try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.example.notes"], format: .binary, options: 0)
        .write(to: folder.appendingPathComponent("Info.plist"))
    #expect(try AppRunner.app(at: folder.path) == AppRunner.App(path: folder.path, bundleID: "com.example.notes"))
}
