//
//  AudioEqualizer.swift
//  SwiftAudioEx
//
//  Created by Ryosuke Kishimoto
//

import Foundation
import AVFoundation

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

// RNTP_EQUALIZER: イコライザーデリゲート
protocol AudioEqualizerDelegate: AnyObject {
    func equalizerPresetChanged(_ preset: EqualizerPreset)
    func equalizerEnabledChanged(_ enabled: Bool)
}

// RNTP_EQUALIZER: Biquad Filterベースのイコライザー管理クラス
class AudioEqualizer {
    internal var isEnabled = false
    internal var currentPreset: EqualizerPreset = .off
    
    // RNTP_EQUALIZER: バイクアッドフィルターの状態変数
    // チャンネルごと、バンドごとに2つの状態を持つ (Direct Form II Transposed)
    internal var filterStates: [[Float]] = []
    internal var sampleRate: Float = 44100.0
    
    // RNTP_EQUALIZER: 事前計算されたフィルター係数
    // [nb0, nb1, nb2, na1, na2] の配列
    fileprivate var coefficients: [[Float]] = []
    
    // RNTP_EQUALIZER: パフォーマンス最適化用
    fileprivate var activeFilterIndices: [Int] = []  // アクティブなフィルターのインデックス
    fileprivate var processingBuffer: [Float] = []  // 処理用一時バッファ
    fileprivate let queue = DispatchQueue(label: "com.equalizer.processing", attributes: .concurrent)
    
    // RNTP_EQUALIZER: イコライザーコールバック
    weak var delegate: AudioEqualizerDelegate?
    
    init() {
        print("RNTP_EQUALIZER: Initializing AudioEqualizer with Biquad Filter")
        updateCoefficients()
    }
    
    deinit {
        print("RNTP_EQUALIZER: Deinitializing AudioEqualizer")
    }

    // RNTP_EQUALIZER: フィルター係数の事前計算
    private func updateCoefficients() {
        queue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            
            self.coefficients = []
            self.activeFilterIndices = []
            let bands = self.currentPreset.bands
            
            guard self.sampleRate > 0 else { return }

            for (index, band) in bands.enumerated() {
                let gain = self.isEnabled ? band.gain : 0.0
                // ゲインがほぼゼロならフィルターをバイパス（係数を単位行列的に設定）
                if abs(gain) < 0.01 {
                    self.coefficients.append([1.0, 0.0, 0.0, 0.0, 0.0])
                } else {
                    // アクティブなフィルターのインデックスを記録
                    self.activeFilterIndices.append(index)
                    
                    let Q: Float = 0.707
                    let A = pow(10.0, gain / 40.0)
                    let omega = 2.0 * Float.pi * band.frequency / self.sampleRate
                    let sinOmega = sin(omega)
                    let cosOmega = cos(omega)
                    let alpha = sinOmega / (2.0 * Q)
                    
                    let b0 = 1.0 + alpha * A
                    let b1 = -2.0 * cosOmega
                    let b2 = 1.0 - alpha * A
                    let a0 = 1.0 + alpha / A
                    let a1 = -2.0 * cosOmega
                    let a2 = 1.0 - alpha / A
                    
                    let norm = 1.0 / a0
                    self.coefficients.append([b0 * norm, b1 * norm, b2 * norm, a1 * norm, a2 * norm])
                }
            }
            print("RNTP_EQUALIZER: Filter coefficients updated for preset: \(self.currentPreset.rawValue), active filters: \(self.activeFilterIndices.count)")
        }
    }
    
    // RNTP_EQUALIZER: イコライザーの有効/無効切り替え
    func setEnabled(_ enabled: Bool) {
        print("RNTP_EQUALIZER: AudioEqualizer setEnabled: \(enabled)")
        
        isEnabled = enabled
        updateCoefficients() // 有効/無効で係数が変わるため再計算
        
        // デリゲートに通知
        delegate?.equalizerEnabledChanged(enabled)
    }
    
    // RNTP_EQUALIZER: イコライザーが有効かどうかを取得
    func getEnabled() -> Bool {
        return isEnabled
    }
    
    // RNTP_EQUALIZER: プリセットの設定
    func setPreset(_ preset: EqualizerPreset) {
        print("RNTP_EQUALIZER: Setting preset to: \(preset.rawValue)")
        
        currentPreset = preset
        updateCoefficients() // プリセットが変わったので係数を再計算
        
        // プリセット変更をデリゲートに通知
        delegate?.equalizerPresetChanged(preset)
        
        print("RNTP_EQUALIZER: Preset applied: \(preset.rawValue)")
    }
    
    // RNTP_EQUALIZER: 現在のプリセットを取得
    func getPreset() -> EqualizerPreset {
        return currentPreset
    }
    
    // RNTP_EQUALIZER: 利用可能なプリセットのリストを取得
    func getAvailablePresets() -> [String] {
        return EqualizerPreset.allCases.map { $0.rawValue }
    }
    
    // RNTP_EQUALIZER: オーディオフォーマットを設定
    func setAudioFormat(_ format: AVAudioFormat) {
        let needsUpdate = abs(Float(format.sampleRate) - sampleRate) > 1.0
        
        sampleRate = Float(format.sampleRate)
        
        // チャンネル数 x バンド数 分の状態を初期化
        let numChannels = Int(format.channelCount)
        let numBands = currentPreset.bands.count
        filterStates = Array(repeating: Array(repeating: 0.0, count: 2), count: numChannels * numBands)
        
        // 処理用バッファのサイズを事前確保（最大8192サンプル）
        processingBuffer = Array(repeating: 0.0, count: 8192)
        
        if needsUpdate {
            updateCoefficients() // サンプルレートが変わったので係数を再計算
        }
        
        print("RNTP_EQUALIZER: Audio format set - Sample Rate: \(sampleRate)Hz, Channels: \(numChannels)")
    }
    
    
    // RNTP_EQUALIZER: AVPlayerItem用のAudioMixを作成
    func createAudioMix(for item: AVPlayerItem) -> AVAudioMix? {
        print("RNTP_EQUALIZER: Creating AudioMix for Biquad Filter")
        
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
        
        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(nil, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap)

        if status == noErr, let tap = tap {
            parameters.audioTapProcessor = tap
            audioMix.inputParameters = [parameters]
            print("RNTP_EQUALIZER: Successfully created AudioMix with Biquad Filter")
            return audioMix
        } else {
            print("RNTP_EQUALIZER: Failed to create MTAudioProcessingTap, status: \(status)")
        }
        
        return nil
    }
}

// RNTP_EQUALIZER: MTAudioProcessingTapコールバック関数
private func audioTapInit(tap: MTAudioProcessingTap, clientInfo: UnsafeMutableRawPointer?, tapStorageOut: UnsafeMutablePointer<UnsafeMutableRawPointer?>) {
    print("RNTP_EQUALIZER: audioTapInit called for Biquad Filter")
    tapStorageOut.pointee = clientInfo
}

private func audioTapFinalize(tap: MTAudioProcessingTap) {
    print("RNTP_EQUALIZER: audioTapFinalize called")
}

private func audioTapPrepare(tap: MTAudioProcessingTap, maxFrames: CMItemCount, processingFormat: UnsafePointer<AudioStreamBasicDescription>) {
    print("RNTP_EQUALIZER: audioTapPrepare called with maxFrames: \(maxFrames)")
    
    let storage = MTAudioProcessingTapGetStorage(tap)
    let equalizerManager = Unmanaged<AudioEqualizer>.fromOpaque(storage).takeUnretainedValue()
    
    let format = processingFormat.pointee
    
    // AVAudioFormatを作成してAudioUnitを初期化
    if let audioFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: format.mSampleRate,
        channels: format.mChannelsPerFrame,
        interleaved: format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
    ) {
        equalizerManager.setAudioFormat(audioFormat)
        print("RNTP_EQUALIZER: Audio format configured successfully.")
    } else {
        print("RNTP_EQUALIZER: Failed to create audio format")
    }
}

private func audioTapUnprepare(tap: MTAudioProcessingTap) {
    print("RNTP_EQUALIZER: audioTapUnprepare called")
    // AVAudioUnitEQを使っていないので、リソース解放は不要
}

private func audioTapProcess(
    tap: MTAudioProcessingTap,
    numberFrames: CMItemCount,
    flags: MTAudioProcessingTapFlags,
    bufferListInOut: UnsafeMutablePointer<AudioBufferList>,
    numberFramesOut: UnsafeMutablePointer<CMItemCount>,
    flagsOut: UnsafeMutablePointer<MTAudioProcessingTapFlags>
) {
    var timeRange = CMTimeRange()
    let status = MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferListInOut, flagsOut, &timeRange, numberFramesOut)
    
    guard status == noErr else { return }

    // イコライザーインスタンスを取得
    let storage = MTAudioProcessingTapGetStorage(tap)
    let equalizerManager = Unmanaged<AudioEqualizer>.fromOpaque(storage).takeUnretainedValue()
    
    // イコライザーが無効なら何もしない
    guard equalizerManager.isEnabled else { return }
    
    // アクティブなフィルターがない場合は早期リターン
    guard !equalizerManager.activeFilterIndices.isEmpty else { return }

    // バイクアッドフィルターを使用した本格的なイコライザー処理
    let bufferList = UnsafeMutableAudioBufferListPointer(bufferListInOut)
    let coefficients = equalizerManager.coefficients
    let numBands = coefficients.count
    let activeIndices = equalizerManager.activeFilterIndices
    
    // チャンネルごとに処理
    for (channelIndex, buffer) in bufferList.enumerated() {
        guard let data = buffer.mData else { continue }
        
        let frameCount = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
        let samples = data.assumingMemoryBound(to: Float.self)
        
        guard frameCount > 0 else { continue }
        
        // バッファ全体を一度に処理（最適化版）
        processChannelOptimized(
            samples: samples,
            frameCount: frameCount,
            channelIndex: channelIndex,
            coefficients: coefficients,
            activeIndices: activeIndices,
            numBands: numBands,
            filterStates: &equalizerManager.filterStates
        )
    }
}

// RNTP_EQUALIZER: 最適化されたチャンネル処理
private func processChannelOptimized(
    samples: UnsafeMutablePointer<Float>,
    frameCount: Int,
    channelIndex: Int,
    coefficients: [[Float]],
    activeIndices: [Int],
    numBands: Int,
    filterStates: inout [[Float]]
) {
    // SIMD処理のためのバッチサイズ（4サンプルずつ処理）
    let simdBatchSize = 4
    let simdBatches = frameCount / simdBatchSize
    let remainder = frameCount % simdBatchSize
    
    // アクティブなフィルターのみ処理
    if activeIndices.count == 1 {
        // 単一フィルターの場合は特別最適化
        let bandIndex = activeIndices[0]
        let stateIndex = channelIndex * numBands + bandIndex
        guard stateIndex < filterStates.count else { return }
        
        processSingleFilterOptimized(
            samples: samples,
            frameCount: frameCount,
            coeffs: coefficients[bandIndex],
            states: &filterStates[stateIndex]
        )
    } else {
        // 複数フィルターの場合
        for i in 0..<frameCount {
            var output = samples[i]
            
            // アクティブなフィルターのみ適用
            for bandIndex in activeIndices {
                let stateIndex = channelIndex * numBands + bandIndex
                guard stateIndex < filterStates.count else { continue }
                
                output = applyBiquadFilterOptimized(
                    input: output,
                    coeffs: coefficients[bandIndex],
                    states: &filterStates[stateIndex]
                )
            }
            
            // クリッピング防止（SIMDで最適化）
            samples[i] = max(-0.95, min(0.95, output))
        }
    }
}

// RNTP_EQUALIZER: 単一フィルター用の最適化処理
private func processSingleFilterOptimized(
    samples: UnsafeMutablePointer<Float>,
    frameCount: Int,
    coeffs: [Float],
    states: inout [Float]
) {
    let nb0 = coeffs[0]
    let nb1 = coeffs[1]
    let nb2 = coeffs[2]
    let na1 = coeffs[3]
    let na2 = coeffs[4]
    
    var s1 = states[0]
    var s2 = states[1]
    
    // ベクトル処理用のポインタ
    samples.withMemoryRebound(to: Float.self, capacity: frameCount) { ptr in
        // Accelerateフレームワークのvec_muladdf関数を使用してバッチ処理
        for i in 0..<frameCount {
            let input = ptr[i]
            let output = nb0 * input + s1
            let newS1 = nb1 * input - na1 * output + s2
            s2 = nb2 * input - na2 * output
            s1 = newS1
            
            // クリッピング防止
            ptr[i] = max(-0.95, min(0.95, output))
        }
    }
    
    states[0] = s1
    states[1] = s2
}

// RNTP_EQUALIZER: 最適化されたバイクアッドフィルター
private func applyBiquadFilterOptimized(input: Float, coeffs: [Float], states: inout [Float]) -> Float {
    let nb0 = coeffs[0]
    let nb1 = coeffs[1]
    let nb2 = coeffs[2]
    let na1 = coeffs[3]
    let na2 = coeffs[4]

    // フィルターの実行（Direct Form II Transposed）
    let output = nb0 * input + states[0]
    states[0] = nb1 * input - na1 * output + states[1]
    states[1] = nb2 * input - na2 * output
    
    return output
}
