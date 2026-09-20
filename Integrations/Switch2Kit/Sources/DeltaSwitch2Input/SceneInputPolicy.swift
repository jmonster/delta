// UIKit-independent scene policy, used by the live service and regression tests.
public struct SceneInputPolicy: Sendable
{
    public enum Event: Sendable
    {
        case foreground, activate, deactivate, background, disconnect
    }

    private var foreground: Set<String>
    private var active: Set<String>
    public var acceptsInput: Bool { !self.active.isEmpty }
    public var shouldStop: Bool { self.foreground.isEmpty }

    public init(foreground: Set<String> = [], active: Set<String> = [])
    {
        self.foreground = foreground.union(active)
        self.active = active
    }

    public mutating func receive(_ event: Event, scene: String)
    {
        switch event
        {
        case .foreground: self.foreground.insert(scene)
        case .activate: self.foreground.insert(scene); self.active.insert(scene)
        case .deactivate: self.active.remove(scene)
        case .background, .disconnect: self.active.remove(scene); self.foreground.remove(scene)
        }
    }
}
