import AVFoundation
import Combine

/// 语音朗读服务 - 封装 AVSpeechSynthesizer
final class SpeechService: NSObject, ObservableObject {
    static let shared = SpeechService()
    
    /// 是否正在朗读
    @Published var isSpeaking: Bool = false
    
    /// 是否暂停
    @Published var isPaused: Bool = false
    
    /// 语速（0.0 ~ 1.0，默认 AVSpeechUtteranceDefaultSpeechRate ≈ 0.5）
    @Published var rate: Float = AVSpeechUtteranceDefaultSpeechRate
    
    /// 音调（0.5 ~ 2.0，默认 1.0）
    @Published var pitch: Float = 1.0
    
    private let synthesizer: AVSpeechSynthesizer
    private var continuation: (() -> Void)?
    private var currentUtterance: AVSpeechUtterance?
    
    private override init() {
        synthesizer = AVSpeechSynthesizer()
        super.init()
        synthesizer.delegate = self
    }
    
    /// 朗读文本，完成后执行回调
    func speak(_ text: String, completion: (() -> Void)? = nil) {
        // 先停止之前的朗读
        continuation = nil
        currentUtterance = nil
        synthesizer.stopSpeaking(at: .immediate)
        
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // 空文本直接回调，继续下一页
            completion?()
            return
        }
        
        continuation = completion
        
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = rate
        utterance.pitchMultiplier = pitch
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")

        currentUtterance = utterance
        synthesizer.speak(utterance)
        isSpeaking = true
        isPaused = false
    }
    
    /// 暂停朗读
    func pause() {
        guard synthesizer.isSpeaking else { return }
        synthesizer.pauseSpeaking(at: .immediate)
        isPaused = true
    }
    
    /// 继续朗读
    func resume() {
        guard synthesizer.isPaused else { return }
        synthesizer.continueSpeaking()
        isPaused = false
    }
    
    /// 停止朗读
    func stop() {
        continuation = nil
        currentUtterance = nil
        isSpeaking = false
        isPaused = false
        synthesizer.stopSpeaking(at: .immediate)
    }
}

// MARK: - AVSpeechSynthesizerDelegate

extension SpeechService: AVSpeechSynthesizerDelegate {
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        isSpeaking = true
        isPaused = false
    }
    
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        guard utterance === currentUtterance else { return }
        currentUtterance = nil
        let completion = continuation
        continuation = nil
        isSpeaking = false
        isPaused = false
        completion?()
    }
    
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        guard utterance === currentUtterance else { return }
        currentUtterance = nil
        isSpeaking = false
        isPaused = false
        continuation = nil
    }
    
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didPause utterance: AVSpeechUtterance) {
        isPaused = true
    }
    
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didContinue utterance: AVSpeechUtterance) {
        isPaused = false
    }
}
