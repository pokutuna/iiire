import AppKit
import AVFoundation
import Foundation

@main
enum Main {
    static func main() {
        // worker が先に終了したパイプに書いても落ちず、書き込みのエラーになるように
        signal(SIGPIPE, SIG_IGN)
        Defaults.register()
        let args = CommandLine.arguments
        // 動作確認用: Koe --transcribe FILE [MODEL]
        if args.count >= 3, args[1] == "--transcribe" {
            let model = args.count >= 4 ? args[3] : Defaults.model.id
            Task { @MainActor in
                exit(await transcribeFile(args[2], model: model))
            }
            RunLoop.main.run()
        }
        // 画面の確認用: Koe --snapshot-hud DIR で HUD の各表示を PNG に書き出す
        if args.count >= 3, args[1] == "--snapshot-hud" {
            _ = NSApplication.shared
            MainActor.assumeIsolated { HUDController.snapshot(to: URL(fileURLWithPath: args[2])) }
            exit(0)
        }
        KoeApp.main()
    }

    @MainActor
    private static func transcribeFile(_ path: String, model: String) async -> Int32 {
        do {
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
            let format = file.processingFormat
            guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else { return 1 }
            try file.read(into: buf)
            let n = Int(buf.frameLength)
            let samples = Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: n))

            let worker = SpeechWorker()
            worker.onStateChange = { FileHandle.standardError.write("state: \($0)\n".data(using: .utf8)!) }
            worker.start(model: model)
            let start = Date()
            let text = try await worker.transcribe(samples: samples, sampleRate: Int(format.sampleRate), options: [:])
            FileHandle.standardError.write(String(format: "elapsed: %.2fs (incl. load)\n", Date().timeIntervalSince(start)).data(using: .utf8)!)
            print(text)
            worker.stop()
            return 0
        } catch {
            FileHandle.standardError.write("error: \(error.localizedDescription)\n".data(using: .utf8)!)
            return 1
        }
    }
}
