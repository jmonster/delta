// Adapted from Riley Testut's pinned native NES bridge (2018).
import Foundation
import DeltaCore

public final class NESEmulatorBridge : NSObject, EmulatorBridging
{
    public private(set) var lastLoadResult = false
    public private(set) var lastBatterySaveResult = false
    public private(set) var lastSaveStateResult = false
    public private(set) var lastLoadStateResult = false

    public static let shared = NESEmulatorBridge()

    public private(set) var gameURL: URL?

    public private(set) var frameDuration: TimeInterval = (1.0 / 60.0)

    public var audioRenderer: AudioRendering?
    public var videoRenderer: VideoRendering?
    public var saveUpdateHandler: (() -> Void)?

    public static var applicationWindow: UIWindow?


    private var isReady = false

    private override init()
    {
        super.init()


        let databaseURL = NES.core.resourceBundle.url(forResource: "NstDatabase", withExtension: "xml")!
        databaseURL.withUnsafeFileSystemRepresentation { NESInitialize($0!) }

        NESSetAudioCallback { (buffer, size) in
            NESEmulatorBridge.shared.audioRenderer?.audioBuffer.write(buffer, size: Int(size))
        }

        NESSetVideoCallback { (buffer, size) in
            if let destination = NESEmulatorBridge.shared.videoRenderer?.videoBuffer { memcpy(destination, buffer, Int(size)) }
        }

        NESSetSaveCallback {
            NESEmulatorBridge.shared.saveUpdateHandler?()
        }

        self.isReady = true


    }
}

public extension NESEmulatorBridge
{
    func start(withGameURL gameURL: URL)
    {
        if !self.isReady
        {
            return
        }

        self.gameURL = gameURL


        lastLoadResult = gameURL.withUnsafeFileSystemRepresentation { NESStartEmulation($0!) }

        self.frameDuration = NESFrameDuration()


    }

    func stop()
    {
        self.gameURL = nil


        NESStopEmulation()


    }

    func pause()
    {
    }

    func resume()
    {
    }

    func runFrame(processVideo: Bool)
    {

        guard lastLoadResult else { return }
        NESRunFrame()



        if processVideo
        {
            self.videoRenderer?.processFrame()
        }
    }

    func readMemory(at address: Int, size: Int) -> Data?
    {
        guard address >= 0, size >= 0, address <= 0x800, size <= 0x800 - address else { return nil }
        guard let bytes = NESReadMemory(Int32(address), Int32(size)) else { return nil }

        let data = Data(bytes: bytes, count: size)
        return data
    }

    func activateInput(_ input: Int, value: Double, playerIndex: Int)
    {

        guard (0..<2).contains(playerIndex) else { return }
        NESActivateInput(Int32(input), Int32(playerIndex))


    }

    func deactivateInput(_ input: Int, playerIndex: Int)
    {

        guard (0..<2).contains(playerIndex) else { return }
        NESDeactivateInput(Int32(input), Int32(playerIndex))


    }

    func resetInputs()
    {

        NESResetInputs()


    }

    func saveSaveState(to url: URL)
    {

        lastSaveStateResult = url.withUnsafeFileSystemRepresentation { NESSaveSaveState($0!) }


    }

    func loadSaveState(from url: URL)
    {

        lastLoadStateResult = url.withUnsafeFileSystemRepresentation { NESLoadSaveState($0!) }


    }

    func saveGameSave(to url: URL)
    {

        lastBatterySaveResult = url.withUnsafeFileSystemRepresentation { NESSaveGameSave($0!) }


    }

    func loadGameSave(from url: URL)
    {

        _ = url.withUnsafeFileSystemRepresentation { NESLoadGameSave($0!) }


    }

    func addCheatCode(_ cheatCode: String, type: String) -> Bool
    {
        let cheatType = CheatType(type)
        guard cheatType == .gameGenie6 || cheatType == .gameGenie8 else { return false }

        let codes = cheatCode.split(separator: "\n")
        for code in codes
        {
                if !code.withCString({ NESAddCheatCode($0) })
            {
                return false
            }

        }

        return true
    }

    func resetCheats()
    {

        NESResetCheats()


    }

    func updateCheats()
    {
    }
}
