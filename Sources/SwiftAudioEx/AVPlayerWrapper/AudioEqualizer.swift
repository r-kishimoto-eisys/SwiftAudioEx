//
//  AudioEqualizer.swift
//  SwiftAudioEx
//
//  Created by RNTP Equalizer Implementation on 2025.
//

import Foundation
import AVFoundation
import Accelerate

// RNTP_EQUALIZER: イコライザープリセット定義
public enum EqualizerPreset: String, CaseIterable {
    case off = "off"
    case soft = "soft"
    case relax = "relax"
    case balance = "balance"
    case whisper = "whisper"
    case focus = "focus"
    case clear = "clear"
    
    // RNTP_EQUALIZER: 各プリセットの周波数とゲイン設定
    var bands: [(frequency: Float, gain: Float)] {
        switch self {
        case .off:
            return [
                (500, 0), (1000, 0), (2000, 0), (4000, 0), (8000, 0)
            ]
        case .soft:
            return [
                (500, 4), (1000, -4), (2000, -3), (4000, 4), (8000, -4)
            ]
        case .relax:
            return [
                (500, 3), (1000, -3), (2000, -6.5), (4000, -3.5), (8000, 5)
            ]
        case .balance:
            return [
                (500, 0), (1000, -2), (2000, 4), (4000, -2.5), (8000, -3)
            ]
        case .whisper:
            return [
                (500, 4), (1000, -6.5), (2000, 3.5), (4000, -4), (8000, 4)
            ]
        case .focus:
            return [
                (500, 8), (1000, 0), (2000, -12), (4000, -11), (8000, 8)
            ]
        case .clear:
            return [
                (500, -5), (1000, 5), (2000, 0), (4000, 2), (8000, 8)
            ]
        }
    }
}

// RNTP_EQUALIZER: 安定したBiquadフィルター実装
class StableBiquadFilter {
    private var b0: Double = 1.0, b1: Double = 0.0, b2: Double = 0.0
    private var a1: Double = 0.0, a2: Double = 0.0
    private var x1: Double = 0.0, x2: Double = 0.0
    private var y1: Double = 0.0, y2: Double = 0.0
    private var frequency: Float = 1000.0
    private var gain: Float = 0.0
    
    // RNTP_EQUALIZER: 安定したピーキングEQフィルターの設定
    func setPeakingEQ(frequency: Float, gain: Float, Q: Float, sampleRate: Float) {
        self.frequency = frequency
        self.gain = gain
        
        // ゲイン0の場合のみパススルー
        if gain == 0.0 {
            setPassThrough()
            return
        }
        
        // 要件通りの完全な値を適用（制限を大幅に緩和）
        let clampedGain = max(-15.0, min(15.0, gain))  // 極端すぎる値のみ制限
        
        // ナイキスト周波数の90%以下に制限
        let nyquist = sampleRate / 2.0
        let clampedFreq = min(frequency, nyquist * 0.9)
        
        // Q値の制限を緩和
        let clampedQ = max(0.2, min(Q, 5.0))
        
        // Double精度で計算
        let A = pow(10.0, Double(clampedGain) / 40.0)
        let omega = 2.0 * Double.pi * Double(clampedFreq) / Double(sampleRate)
        let sinOmega = sin(omega)
        let cosOmega = cos(omega)
        let alpha = sinOmega / (2.0 * Double(clampedQ))
        
        // 安定性チェック：オメガが有効範囲内かチェック
        if omega <= 0 || omega >= Double.pi {
            setPassThrough()
            return
        }
        
        // 係数計算（正規化形式）
        let b0_temp = 1.0 + alpha * A
        let b1_temp = -2.0 * cosOmega
        let b2_temp = 1.0 - alpha * A
        let a0_temp = 1.0 + alpha / A
        let a1_temp = -2.0 * cosOmega
        let a2_temp = 1.0 - alpha / A
        
        // ゼロ除算チェック
        if abs(a0_temp) < 1e-10 {
            setPassThrough()
            return
        }
        
        // 正規化
        b0 = b0_temp / a0_temp
        b1 = b1_temp / a0_temp
        b2 = b2_temp / a0_temp
        a1 = a1_temp / a0_temp
        a2 = a2_temp / a0_temp
        
        // 安定性チェック：極が単位円内にあるかチェック
        let discriminant = a1 * a1 - 4.0 * a2
        if discriminant >= 0 {
            // 実根の場合
            let root1 = (-a1 + sqrt(discriminant)) / 2.0
            let root2 = (-a1 - sqrt(discriminant)) / 2.0
            if abs(root1) >= 1.0 || abs(root2) >= 1.0 {
                setPassThrough()
                return
            }
        } else {
            // 複素根の場合
            let magnitude = sqrt(a2)
            if magnitude >= 1.0 {
                setPassThrough()
                return
            }
        }
        
        // 係数の絶対値チェック（制限を緩和）
        if abs(b0) > 10.0 || abs(b1) > 10.0 || abs(b2) > 10.0 ||
           abs(a1) > 5.0 || abs(a2) > 2.0 {
            setPassThrough()
            return
        }
    }
    
    // RNTP_EQUALIZER: パススルーフィルターとして設定
    private func setPassThrough() {
        b0 = 1.0; b1 = 0.0; b2 = 0.0
        a1 = 0.0; a2 = 0.0
    }
    
    // RNTP_EQUALIZER: フィルター処理
    func process(_ input: Float) -> Float {
        // 入力値の検証
        guard input.isFinite && abs(input) <= 1.0 else { return 0.0 }
        
        // Double精度で計算
        let inputDouble = Double(input)
        
        // フィルター計算
        let output = b0 * inputDouble + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        
        // 出力値の検証（制限を緩和）
        guard output.isFinite && abs(output) < 50.0 else {
            // 異常値の場合はフィルター状態をリセット
            reset()
            return Float(inputDouble * 0.5)
        }
        
        // 遅延サンプルの更新
        x2 = x1
        x1 = inputDouble
        y2 = y1
        y1 = output
        
        // デノーマライゼーション対策
        if abs(y1) < 1e-15 { y1 = 0.0 }
        if abs(y2) < 1e-15 { y2 = 0.0 }
        if abs(x1) < 1e-15 { x1 = 0.0 }
        if abs(x2) < 1e-15 { x2 = 0.0 }
        
        // Float範囲でクリッピング（範囲を少し拡大）
        let outputFloat = Float(output)
        return max(-1.0, min(1.0, outputFloat))
    }
    
    // RNTP_EQUALIZER: フィルターリセット
    func reset() {
        x1 = 0.0; x2 = 0.0; y1 = 0.0; y2 = 0.0
    }
}

// RNTP_EQUALIZER: イコライザー管理クラス
class AudioEqualizer {
    internal var isEnabled = false
    internal var currentPreset: EqualizerPreset = .off
    
    // RNTP_EQUALIZER: 各周波数帯域用のフィルター
    internal var filters: [StableBiquadFilter] = []
    private var sampleRate: Float = 44100.0  // 動的に設定されるサンプルレート
    private let filterQ: Float = 0.5  // フィルターのQ値（より広い帯域で安定）
    
    init() {
        setupFilters()
    }
    
    // RNTP_EQUALIZER: フィルターの初期化
    private func setupFilters() {
        print("RNTP_EQUALIZER: Setting up biquad filters with sample rate: \(sampleRate)")
        
        // 5つの周波数帯域用のフィルターを作成
        filters = (0..<5).map { _ in StableBiquadFilter() }
        
        // 初期状態ではフラット（ゲイン0）に設定
        updateFilters()
    }
    
    // RNTP_EQUALIZER: サンプルレートを設定
    func setSampleRate(_ rate: Float) {
        print("RNTP_EQUALIZER: Setting sample rate to: \(rate)")
        sampleRate = rate
        updateFilters()  // サンプルレート変更時にフィルターを再計算
    }
    
    // RNTP_EQUALIZER: フィルターパラメータの更新
    private func updateFilters() {
        let bands = currentPreset.bands
        
        for (index, band) in bands.enumerated() {
            if index < filters.count {
                filters[index].setPeakingEQ(
                    frequency: band.frequency,
                    gain: isEnabled ? band.gain : 0.0,
                    Q: filterQ,
                    sampleRate: sampleRate
                )
            }
        }
        
        print("RNTP_EQUALIZER: Updated filters for preset: \(currentPreset.rawValue)")
    }
    
    // RNTP_EQUALIZER: イコライザーの有効/無効切り替え
    func setEnabled(_ enabled: Bool) {
        print("RNTP_EQUALIZER: AudioEqualizer setEnabled: \(enabled)")
        isEnabled = enabled
        updateFilters()
    }
    
    // RNTP_EQUALIZER: イコライザーが有効かどうかを取得
    func getEnabled() -> Bool {
        return isEnabled
    }
    
    // RNTP_EQUALIZER: プリセットの設定
    func setPreset(_ preset: EqualizerPreset) {
        print("RNTP_EQUALIZER: Setting preset to: \(preset.rawValue)")
        currentPreset = preset
        updateFilters()
    }
    
    // RNTP_EQUALIZER: 現在のプリセットを取得
    func getPreset() -> EqualizerPreset {
        return currentPreset
    }
    
    // RNTP_EQUALIZER: 利用可能なプリセットのリストを取得
    func getAvailablePresets() -> [String] {
        return EqualizerPreset.allCases.map { $0.rawValue }
    }
    
    // RNTP_EQUALIZER: 音声サンプルの処理
    func processSample(_ input: Float) -> Float {
        guard isEnabled else { return input }
        guard input.isFinite && abs(input) <= 1.0 else { return 0.0 }
        
        var output = input
        
        // 各周波数帯域のフィルターを直列に適用
        for filter in filters {
            output = filter.process(output)
            // 各段階で異常値チェック（制限を緩和）
            if !output.isFinite || abs(output) > 5.0 {
                // 異常な場合は元の信号を減衰して返す
                return input * 0.7
            }
        }
        
        // 最終的なスケール調整（複数フィルター適用による増幅を抑制）
        let scaleFactor: Float = 0.9  // より自然な音量レベル
        output *= scaleFactor
        
        // クリッピング防止
        return max(-1.0, min(1.0, output))
    }
    
    // RNTP_EQUALIZER: AVPlayerItem用のAudioMixを作成
    func createAudioMix(for item: AVPlayerItem) -> AVAudioMix? {
        print("RNTP_EQUALIZER: Creating AudioMix with biquad filters")
        
        guard let assetTrack = item.asset.tracks(withMediaType: .audio).first else {
            print("RNTP_EQUALIZER: No audio track found in asset")
            return nil
        }
        
        let audioMix = AVMutableAudioMix()
        let parameters = AVMutableAudioMixInputParameters(track: assetTrack)
        
        // MTAudioProcessingTapを作成
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            init: audioTapInit,
            finalize: audioTapFinalize,
            prepare: audioTapPrepare,
            unprepare: audioTapUnprepare,
            process: audioTapProcess
        )
        
        var tap: Unmanaged<MTAudioProcessingTap>?
        let status = MTAudioProcessingTapCreate(nil, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
        
        if status == noErr, let tap = tap {
            parameters.audioTapProcessor = tap.takeRetainedValue()
            audioMix.inputParameters = [parameters]
            print("RNTP_EQUALIZER: Successfully created AudioMix with biquad processing")
            return audioMix
        } else {
            print("RNTP_EQUALIZER: Failed to create MTAudioProcessingTap, status: \(status)")
        }
        
        return nil
    }
}

// RNTP_EQUALIZER: MTAudioProcessingTapコールバック関数
private func audioTapInit(tap: MTAudioProcessingTap, clientInfo: UnsafeMutableRawPointer?, tapStorageOut: UnsafeMutablePointer<UnsafeMutableRawPointer?>) {
    print("RNTP_EQUALIZER: audioTapInit called")
    tapStorageOut.pointee = clientInfo
}

private func audioTapFinalize(tap: MTAudioProcessingTap) {
    print("RNTP_EQUALIZER: audioTapFinalize called")
}

private func audioTapPrepare(tap: MTAudioProcessingTap, maxFrames: CMItemCount, processingFormat: UnsafePointer<AudioStreamBasicDescription>) {
    print("RNTP_EQUALIZER: audioTapPrepare called with maxFrames: \(maxFrames)")
    
    // 実際のサンプルレートを取得
    let actualSampleRate = Float(processingFormat.pointee.mSampleRate)
    print("RNTP_EQUALIZER: Actual sample rate: \(actualSampleRate)")
    
    // フィルターをリセットし、正しいサンプルレートを設定
    let storage = MTAudioProcessingTapGetStorage(tap)
    if storage != nil {
        let equalizer = Unmanaged<AudioEqualizer>.fromOpaque(storage).takeUnretainedValue()
        
        // サンプルレートを実際の値に更新
        equalizer.setSampleRate(actualSampleRate)
        
        // フィルターをリセット
        for filter in equalizer.filters {
            filter.reset()
        }
    }
}

private func audioTapUnprepare(tap: MTAudioProcessingTap) {
    print("RNTP_EQUALIZER: audioTapUnprepare called")
}

private func audioTapProcess(tap: MTAudioProcessingTap, numberFrames: CMItemCount, flags: MTAudioProcessingTapFlags, bufferListInOut: UnsafeMutablePointer<AudioBufferList>, numberFramesOut: UnsafeMutablePointer<CMItemCount>, flagsOut: UnsafeMutablePointer<MTAudioProcessingTapFlags>) {
    
    var timeRange = CMTimeRange()
    let status = MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferListInOut, flagsOut, &timeRange, numberFramesOut)
    
    guard status == noErr else { 
        return 
    }
    
    // タップのストレージからイコライザーインスタンスを取得
    let storage = MTAudioProcessingTapGetStorage(tap)
    guard storage != nil else { 
        return 
    }
    let equalizer = Unmanaged<AudioEqualizer>.fromOpaque(storage).takeUnretainedValue()
    
    // イコライザーが無効な場合は処理をスキップ
    guard equalizer.isEnabled else { 
        return 
    }
    
    // RNTP_EQUALIZER: バイクアッドフィルタによる音声処理
    let bufferList = UnsafeMutableAudioBufferListPointer(bufferListInOut)
    
    for buffer in bufferList {
        guard let data = buffer.mData else { continue }
        
        let frameCount = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
        let samples = data.assumingMemoryBound(to: Float.self)
        
        // バッファサイズの妥当性チェック
        guard frameCount > 0 && frameCount < 8192 else { continue }
        
        // 各サンプルにイコライザー処理を適用
        for i in 0..<frameCount {
            let originalSample = samples[i]
            
            // 入力サンプルの妥当性チェック
            if originalSample.isFinite && abs(originalSample) <= 1.0 {
                samples[i] = equalizer.processSample(originalSample)
            }
        }
    }
    
    // 処理状況をログ出力（頻度を減らす）
    if Int(numberFrames) % 1000 == 0 {
        print("RNTP_EQUALIZER: Processed \(numberFrames) frames with preset \(equalizer.currentPreset.rawValue)")
    }
}
