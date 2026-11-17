import simd
import Testing
@testable import duorex

/// A screen two units wide and high in the plane z = 0. It shows its picture toward +z:
/// seen from there, the framebuffer's x runs right and its y runs down.
private let leaf = ScreenLeaf(a: [-1, 1, 0], b: [1, 1, 0], c: [-1, -1, 0], uvA: [0, 0], uvB: [1, 0], uvC: [0, 1], region: [0, 0, 1, 1])

@Test func `a screen faces the side that sees its picture the right way round`() {
    #expect(simd_distance(leaf.outward, [0, 0, 1]) < 0.0001)
}

@Test func `a ray from the front meets the screen at a framebuffer point`() throws {
    let hit = try #require(leaf.intersect(origin: [0.5, 0.5, 5], direction: [0, 0, -1]))
    #expect(simd_distance(hit.uv, [0.75, 0.25]) < 0.0001)
    #expect(hit.outside == 0)
}

@Test func `a ray from behind does not meet the screen`() {
    // The device is between the pointer and the glass.
    #expect(leaf.intersect(origin: [0.5, 0.5, -5], direction: [0, 0, 1]) == nil)
}

@Test func `a framebuffer point has its place on the screen`() {
    let place = leaf.place([0.75, 0.25])
    #expect(simd_distance(place.point, [0.5, 0.5, 0]) < 0.0001)
    #expect(simd_distance(place.across, [2, 0, 0]) < 0.0001)
    #expect(simd_distance(place.down, [0, -2, 0]) < 0.0001)
}
