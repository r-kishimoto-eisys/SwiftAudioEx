//
//  AVPlayerWrapper.swift
//  SwiftAudio
//
//  Created by Jørgen Henrichsen on 06/03/2018.
//  Copyright © 2018 Jørgen Henrichsen. All rights reserved.
//

import Foundation
import AVFoundation
import MediaPlayer
import AudioToolbox

// MARK: - Embedded Equalizer Implementation

// Equalizer Preset Definitions  
public enum EqualizerPreset: String, CaseIterable {
    case voice1 = "voice1"      // 声v1
    case voice2 = "voice2"      // 声v2  
    case voice3 = "voice3"      // 声v3
    case soundEffect1 = "soundEffect1"  // 効果音v1
    case soundEffect2 = "soundEffect2"  // 効果音v2
    case soundEffect3 = "soundEffect3"  // 効果音v3
    case flat = "flat"          // フラット（デフォルト）
    
    public var displayName: String {
        switch self {
        case .voice1: return "声v1"
        case .voice2: return "声v2"
        case .voice3: return "声v3"
        case .soundEffect1: return "効果音v1"
        case .soundEffect2: return "効果音v2"
        case .soundEffect3: return "効果音v3"
        case .flat: return "フラット"
        }
    }
    
    // プリセットの値を取得（周波数：ゲイン（dB））
    public var gains: [Float: Float] {
        switch self {
        case .voice1:
            return [500: 4.0, 1000: -4.0, 2000: -3.0, 4000: 4.0, 8000: -4.0]
        case .voice2:
            return [500: 3.0, 1000: -3.0, 2000: -6.5, 4000: -3.5, 8000: 5.0]
        case .voice3:
            return [500: 0.0, 1000: -2.0, 2000: 4.0, 4000: -2.5, 8000: -3.0]
        case .soundEffect1:
            return [500: 4.0, 1000: -6.5, 2000: 3.5, 4000: -4.0, 8000: 4.0]
        case .soundEffect2:
            return [500: 8.0, 1000: 0.0, 2000: -12.0, 4000: -11.0, 8000: 8.0]
        case .soundEffect3:
            return [500: -5.0, 1000: 5.0, 2000: 0.0, 4000: 2.0, 8000: 8.0]
        case .flat:
            return [500: 0.0, 1000: 0.0, 2000: 0.0, 4000: 0.0, 8000: 0.0]
        }
    }
}

// Equalizer Manager Delegate
public protocol EqualizerManagerDelegate: AnyObject {
    func equalizerManager(_ manager: EqualizerManager, didChangePreset preset: EqualizerPreset)
    func equalizerManager(_ manager: EqualizerManager, didChangeEnabledState enabled: Bool)
}

// Equalizer Manager Class - AVAudioPCMBuffer Streaming Implementation
public class EqualizerManager {
    // Audio engine components
    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let equalizer = AVAudioUnitEQ(numberOfBands: 5)
    
    // Current state
    private var currentPreset: EqualizerPreset = .flat
    private var isEnabled: Bool = false
    
    // Audio format and streaming
    private var audioFormat: AVAudioFormat?
    private var isStreamingContent = false
    private var streamingURL: URL?
    
    // Playback state
    private var isPlayingAudio = false
    private var currentTime: TimeInterval = 0
    private var currentVolume: Float = 1.0
    private var currentRate: Float = 1.0
    
    // PCM Buffer streaming components
    private let bufferQueue = DispatchQueue(label: "pcm.buffer.queue")
    private let networkQueue = DispatchQueue(label: "network.streaming.queue")
    private var streamingTask: URLSessionDataTask?
    private var audioConverter: AVAudioConverter?
    private var pendingBuffers: [AVAudioPCMBuffer] = []
    private var isSchedulingBuffers = false
    private var bufferSize: AVAudioFrameCount = 4096
    
    // For local file playback
    private var audioFile: AVAudioFile?
    private var fileReadPosition: AVAudioFramePosition = 0
    
    // Delegate for state updates
    public weak var delegate: EqualizerManagerDelegate?
    
    public init() {
        setupAudioEngine()
        setupEqualizer()
        setupAudioFormat()
    }
    
    // MARK: - Audio Format Setup
    private func setupAudioFormat() {
        // Set up standard PCM format for streaming
        audioFormat = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)
        print("🎵 EqualizerManager: Audio format set up: \(audioFormat?.description ?? "nil")")
    }
    
    // MARK: - Audio Engine Setup
    private func setupAudioEngine() {
        print("🔧 EqualizerManager: Setting up audio engine...")
        
        // Add nodes to the audio engine
        audioEngine.attach(playerNode)
        audioEngine.attach(equalizer)
        print("🔧 EqualizerManager: Attached playerNode and equalizer to engine")
        
        // Get the main mixer node
        let mainMixer = audioEngine.mainMixerNode
        print("🔧 EqualizerManager: Got main mixer node")
        
        // Connect the nodes: playerNode -> equalizer -> mainMixer -> output
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)
        print("🔧 EqualizerManager: Using format: \(format?.description ?? "nil")")
        
        audioEngine.connect(playerNode, to: equalizer, format: format)
        print("🔧 EqualizerManager: Connected playerNode -> equalizer")
        
        audioEngine.connect(equalizer, to: mainMixer, format: format)
        print("🔧 EqualizerManager: Connected equalizer -> mainMixer")
        
        // Prepare the engine
        audioEngine.prepare()
        print("🔧 EqualizerManager: Audio engine prepared")
        
        // Log the audio chain
        print("🔧 EqualizerManager: Audio chain: playerNode -> equalizer -> mainMixer -> output")
    }
    
    private func setupEqualizer() {
        // Configure equalizer bands for the specified frequencies
        let frequencies: [Float] = [500, 1000, 2000, 4000, 8000]
        
        for (index, frequency) in frequencies.enumerated() {
            if index < equalizer.bands.count {
                let band = equalizer.bands[index]
                band.filterType = .parametric
                band.frequency = frequency
                band.bandwidth = 1.0  // Q factor
                band.gain = 0.0      // Initial gain (flat)
                band.bypass = false
            }
        }
    }
    
    // MARK: - Public Interface
    
    // Enable/disable equalizer
    public func setEnabled(_ enabled: Bool) {
        print("🎛️ EqualizerManager: setEnabled called with: \(enabled)")
        isEnabled = enabled
        
        if enabled {
            print("🎛️ EqualizerManager: Starting audio engine...")
            startAudioEngine()
        } else {
            print("🎛️ EqualizerManager: Disabling - setting all bands to flat")
            // When disabling, set all bands to flat
            for (index, band) in equalizer.bands.enumerated() {
                print("🎛️ EqualizerManager: Setting band \(index) to 0.0dB")
                band.gain = 0.0
            }
        }
        
        delegate?.equalizerManager(self, didChangeEnabledState: enabled)
    }
    
    // Apply equalizer preset
    public func applyPreset(_ preset: EqualizerPreset) {
        print("🎵 EqualizerManager: Applying preset \(preset.rawValue)")
        currentPreset = preset
        let gains = preset.gains
        let frequencies: [Float] = [500, 1000, 2000, 4000, 8000]
        
        print("🎵 EqualizerManager: Preset gains: \(gains)")
        
        for (index, frequency) in frequencies.enumerated() {
            if index < equalizer.bands.count {
                let band = equalizer.bands[index]
                let newGain = gains[frequency] ?? 0.0
                print("🎵 EqualizerManager: Setting band \(index) (freq: \(frequency)Hz) gain: \(newGain)dB")
                band.gain = newGain
                print("🎵 EqualizerManager: Band \(index) actual gain after setting: \(band.gain)dB")
            }
        }
        
        print("🎵 EqualizerManager: Preset \(preset.rawValue) applied successfully")
        delegate?.equalizerManager(self, didChangePreset: preset)
    }
    
    // Get current preset
    public func getCurrentPreset() -> EqualizerPreset {
        return currentPreset
    }
    
    // Get enabled state
    public func isEqualizerEnabled() -> Bool {
        return isEnabled
    }
    
    // MARK: - Audio Playback Control
    
    // Load audio from URL - handles both local files and streaming with PCM buffers
    public func loadAudio(from url: URL) {
        print("📂 EqualizerManager: Loading audio from: \(url)")
        print("📂 EqualizerManager: URL scheme: \(url.scheme ?? "nil")")
        
        // Stop any current playback
        stop()
        
        if url.isFileURL {
            // Local file handling
            loadLocalFileWithPCMBuffers(url: url)
        } else {
            // Streaming URL handling with PCM buffers
            loadStreamingURLWithPCMBuffers(url: url)
        }
        
        // Start audio engine if not running
        startAudioEngine()
    }
    
    // MARK: - Local File Loading with PCM Buffers
    private func loadLocalFileWithPCMBuffers(url: URL) {
        print("📂 EqualizerManager: Loading local file with PCM buffers...")
        isStreamingContent = false
        
        do {
            audioFile = try AVAudioFile(forReading: url)
            audioFormat = audioFile?.processingFormat
            fileReadPosition = 0
            
            print("✅ EqualizerManager: Successfully loaded local audio file")
            print("📂 EqualizerManager: Audio format: \(audioFormat?.description ?? "nil")")
            print("📂 EqualizerManager: File length: \(audioFile?.length ?? 0) frames")
            
            // Reconnect nodes with the file's format
            if let format = audioFormat {
                reconnectNodesWithFormat(format)
            }
        } catch {
            print("❌ EqualizerManager: Failed to load local audio file: \(error)")
            audioFile = nil
        }
    }
    
    // MARK: - Streaming with PCM Buffers
    private func loadStreamingURLWithPCMBuffers(url: URL) {
        print("🌐 EqualizerManager: Setting up streaming with PCM buffers...")
        isStreamingContent = true
        streamingURL = url
        audioFile = nil
        
        // Use standard format for streaming
        guard let format = audioFormat else {
            print("❌ EqualizerManager: No audio format available")
            return
        }
        
        reconnectNodesWithFormat(format)
        startStreamingWithPCMBuffers(url: url)
    }
    
    private func startStreamingWithPCMBuffers(url: URL) {
        print("🌐 EqualizerManager: Starting streaming download for: \(url)")
        
        // Cancel any existing streaming task
        streamingTask?.cancel()
        
        // Create streaming task
        streamingTask = URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            guard let self = self else { return }
            
            if let error = error {
                print("❌ EqualizerManager: Streaming error: \(error)")
                return
            }
            
            guard let data = data else {
                print("❌ EqualizerManager: No data received from stream")
                return
            }
            
            print("🌐 EqualizerManager: Received \(data.count) bytes from stream")
            self.processStreamingDataToPCMBuffers(data)
        }
        
        streamingTask?.resume()
        print("🌐 EqualizerManager: Streaming download started")
    }
    
    private func processStreamingDataToPCMBuffers(_ data: Data) {
        networkQueue.async { [weak self] in
            guard let self = self, let audioFormat = self.audioFormat else { return }
            
            print("🎵 EqualizerManager: Processing streaming data to PCM buffers...")
            
            // Create temporary file from streaming data
            let tempURL = self.createTemporaryFile(from: data)
            
            do {
                // Read the temporary file and convert to PCM buffers
                let tempFile = try AVAudioFile(forReading: tempURL)
                let frameCount = AVAudioFrameCount(tempFile.length)
                
                guard let buffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: frameCount) else {
                    print("❌ EqualizerManager: Failed to create PCM buffer")
                    return
                }
                
                try tempFile.read(into: buffer)
                buffer.frameLength = frameCount
                
                print("✅ EqualizerManager: Created PCM buffer with \(frameCount) frames")
                
                DispatchQueue.main.async {
                    self.addPCMBufferToQueue(buffer)
                }
                
                // Clean up temporary file
                try? FileManager.default.removeItem(at: tempURL)
                
            } catch {
                print("❌ EqualizerManager: Failed to process streaming data to PCM: \(error)")
            }
        }
    }
    
    private func addPCMBufferToQueue(_ buffer: AVAudioPCMBuffer) {
        bufferQueue.async { [weak self] in
            guard let self = self else { return }
            
            self.pendingBuffers.append(buffer)
            print("🎵 EqualizerManager: Added buffer to queue. Queue size: \(self.pendingBuffers.count)")
            
            if !self.isSchedulingBuffers {
                self.scheduleNextBuffer()
            }
        }
    }
    
    private func scheduleNextBuffer() {
        bufferQueue.async { [weak self] in
            guard let self = self else { return }
            
            guard !self.pendingBuffers.isEmpty else {
                self.isSchedulingBuffers = false
                print("🎵 EqualizerManager: No more buffers to schedule")
                return
            }
            
            let buffer = self.pendingBuffers.removeFirst()
            self.isSchedulingBuffers = true
            
            DispatchQueue.main.async {
                self.playerNode.scheduleBuffer(buffer) { [weak self] in
                    self?.scheduleNextBuffer()
                }
                print("🎵 EqualizerManager: Scheduled buffer with \(buffer.frameLength) frames")
            }
        }
    }
    
    private func createTemporaryFile(from data: Data) -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let tempURL = tempDir.appendingPathComponent(UUID().uuidString + ".m4a")
        
        do {
            try data.write(to: tempURL)
            print("💾 EqualizerManager: Created temporary file: \(tempURL)")
        } catch {
            print("❌ EqualizerManager: Failed to create temporary file: \(error)")
        }
        
        return tempURL
    }
    
    // Play audio - supports both local files and streaming
    public func play() {
        print("🎬 EqualizerManager: Starting playback...")
        
        guard !isPlayingAudio else {
            print("🎬 EqualizerManager: Already playing")
            return
        }
        
        // Start audio engine if not running
        startAudioEngine()
        
        if isStreamingContent {
            // For streaming content, start playing the queued buffers
            print("🌐 EqualizerManager: Starting streaming playback")
            playerNode.play()
            isPlayingAudio = true
            
            // Start scheduling buffers if we have any
            if !pendingBuffers.isEmpty && !isSchedulingBuffers {
                scheduleNextBuffer()
            }
        } else {
            // For local files, use PCM buffer approach for consistency
            playLocalFileWithPCMBuffers()
        }
    }
    
    private func playLocalFileWithPCMBuffers() {
        guard let audioFile = audioFile else {
            print("❌ EqualizerManager: No audio file loaded")
            return
        }
        
        print("📂 EqualizerManager: Starting local file playback with PCM buffers")
        
        // Read file in chunks and schedule as buffers
        readAndScheduleFileBuffers()
        playerNode.play()
        isPlayingAudio = true
    }
    
    private func readAndScheduleFileBuffers() {
        guard let audioFile = audioFile, let audioFormat = audioFormat else { return }
        
        let framesToRead = min(bufferSize, AVAudioFrameCount(audioFile.length - fileReadPosition))
        guard framesToRead > 0 else {
            print("📂 EqualizerManager: Reached end of file")
            return
        }
        
        guard let buffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: framesToRead) else {
            print("❌ EqualizerManager: Failed to create buffer for local file")
            return
        }
        
        do {
            audioFile.framePosition = fileReadPosition
            try audioFile.read(into: buffer, frameCount: framesToRead)
            buffer.frameLength = framesToRead
            
            playerNode.scheduleBuffer(buffer) { [weak self] in
                DispatchQueue.main.async {
                    self?.continueReadingLocalFile()
                }
            }
            
            fileReadPosition += AVAudioFramePosition(framesToRead)
            print("📂 EqualizerManager: Scheduled local file buffer: \(framesToRead) frames")
            
        } catch {
            print("❌ EqualizerManager: Failed to read local file: \(error)")
        }
    }
    
    private func continueReadingLocalFile() {
        guard isPlayingAudio, let audioFile = audioFile else { return }
        
        if fileReadPosition < audioFile.length {
            readAndScheduleFileBuffers()
        } else {
            print("📂 EqualizerManager: Local file playback completed")
            isPlayingAudio = false
        }
    }
    
    // Pause audio
    public func pause() {
        if isPlayingAudio {
            playerNode.pause()
            isPlayingAudio = false
            print("EqualizerManager: Paused playback")
        }
    }
    
    // Stop audio
    public func stop() {
        if isPlayingAudio {
            playerNode.stop()
            isPlayingAudio = false
            print("EqualizerManager: Stopped playback")
        }
    }
    
    // MARK: - Audio Engine Control
    
    private func startAudioEngine() {
        guard !audioEngine.isRunning else { 
            print("🔊 EqualizerManager: Audio engine already running")
            return 
        }
        
        do {
            try audioEngine.start()
            print("✅ EqualizerManager: Audio engine started successfully")
        } catch {
            print("❌ EqualizerManager: Failed to start audio engine: \(error)")
        }
    }
    
    private func stopAudioEngine() {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
    }
    
    // MARK: - Volume and Rate Control
    
    public func setVolume(_ volume: Float) {
        currentVolume = volume
        audioEngine.mainMixerNode.outputVolume = volume
    }
    
    public func setRate(_ rate: Float) {
        currentRate = rate
        // Note: Rate control would require more complex implementation
        // For now, we'll store the rate for future use
        print("EqualizerManager: Rate set to \(rate)")
    }
    
    public func isPlaying() -> Bool {
        return isPlayingAudio
    }
    
    // MARK: - Cleanup
    
    public func cleanup() {
        stopAudioEngine()
        audioFile = nil
    }
}

public enum PlaybackEndedReason: String {
    case playedUntilEnd
    case playerStopped
    case skippedToNext
    case skippedToPrevious
    case jumpedToIndex
    case cleared
    case failed
}

class AVPlayerWrapper: AVPlayerWrapperProtocol {
    // MARK: - Properties - Pure AVAudioEngine + PCM Buffer Implementation
    
    // AVAudioEngine for all audio processing and playback
    private let equalizerManager = EqualizerManager()
    private var currentEqualizerPreset: String = "flat"
    private var equalizerEnabled: Bool = false
    
    // State management
    private var url: URL? = nil
    private var urlOptions: [String: Any]? = nil
    private let stateQueue = DispatchQueue(
        label: "AVPlayerWrapper.stateQueue",
        attributes: .concurrent
    )
    
    // Playback state and timing
    private var audioEngineVolume: Float = 1.0
    private var audioEngineRate: Float = 1.0
    private var timeToSeekToAfterLoading: TimeInterval?
    private var playbackStartTime: Date?
    private var pausedTime: TimeInterval = 0
    
    // Progress tracking
    private var progressTimer: Timer?
    
    // Required protocol properties
    private let playerTimeObserver = AVPlayerTimeObserver(periodicObserverTimeInterval: CMTime(seconds: 1.0, preferredTimescale: 1000))
    private var _currentItem: AVPlayerItem? = nil
    
    // Legacy AVPlayer reference for compatibility (muted and unused)
    private let avPlayer = AVPlayer()

    public init() {
        print("🚀 AVPlayerWrapper: Initializing pure AVAudioEngine + PCM Buffer implementation")
        setupAudioEngine()
    }
    
    // MARK: - AVPlayerWrapperProtocol

    fileprivate(set) var playbackError: AudioPlayerError.PlaybackError? = nil
    
    var _state: AVPlayerWrapperState = AVPlayerWrapperState.idle
    var state: AVPlayerWrapperState {
        get {
            var state: AVPlayerWrapperState!
            stateQueue.sync {
                state = _state
            }

            return state
        }
        set {
            stateQueue.async(flags: .barrier) { [weak self] in
                guard let self = self else { return }
                let currentState = self._state
                if (currentState != newValue) {
                    self._state = newValue
                    self.delegate?.AVWrapper(didChangeState: newValue)
                }
            }
        }
    }

    /**
     Whether playback should start automatically when the item is ready.
     */
    public var playWhenReady: Bool = false {
        didSet {
            if (playWhenReady == true && (state == .failed || state == .stopped)) {
                reload(startFromCurrentTime: state == .failed)
            }
            
            if oldValue != playWhenReady {
                delegate?.AVWrapper(didChangePlayWhenReady: playWhenReady)
            }
        }
    }

    var playbackActive: Bool {
        switch state {
        case .idle, .stopped, .ended, .failed:
            return false
        default: return true
        }
    }
    
    var currentTime: TimeInterval {
        // Calculate current time based on playback start time
        if equalizerManager.isPlaying(), let startTime = playbackStartTime {
            return pausedTime + Date().timeIntervalSince(startTime)
        }
        return pausedTime
    }
    
    var duration: TimeInterval {
        // For now return a reasonable default duration
        // This could be enhanced to get actual duration from loaded audio
        return 300.0 // 5 minutes default
    }
    
    var bufferedPosition: TimeInterval {
        // For AVAudioEngine implementation, return current time as buffered
        return currentTime
    }

    private var _rate: Float = 1.0;
    var rate: Float {
        get { _rate }
        set {
            _rate = newValue
            audioEngineRate = newValue
            // Apply rate to AVAudioEngine
            equalizerManager.setRate(newValue)
        }
    }

    weak var delegate: AVPlayerWrapperDelegate? = nil
    
    var bufferDuration: TimeInterval = 0

    var timeEventFrequency: TimeEventFrequency = .everySecond {
        didSet {
            playerTimeObserver.periodicObserverTimeInterval = timeEventFrequency.getTime()
        }
    }
    
    var volume: Float {
        get { audioEngineVolume }
        set { 
            print("🔊 AVPlayerWrapper: Setting volume to \(newValue) on AVAudioEngine")
            audioEngineVolume = newValue
            // Apply volume to AVAudioEngine only (AVPlayer is muted)
            equalizerManager.setVolume(newValue)
            // Keep AVPlayer muted
            avPlayer.volume = 0.0
        }
    }
    
    var isMuted: Bool {
        get { audioEngineVolume == 0.0 }
        set { 
            if newValue {
                equalizerManager.setVolume(0.0)
            } else {
                equalizerManager.setVolume(audioEngineVolume)
            }
        }
    }

    var automaticallyWaitsToMinimizeStalling: Bool {
        get { true }
        set { /* Not applicable for AVAudioEngine */ }
    }
    
    // Required protocol properties - Pure AVAudioEngine implementation
    var currentItem: AVPlayerItem? {
        get { _currentItem }
    }
    
    var reasonForWaitingToPlay: AVPlayer.WaitingReason? {
        get { nil }
    }
    
    func play() {
        print("🎬 AVPlayerWrapper: play() called - using pure AVAudioEngine")
        playWhenReady = true
        
        if equalizerManager.isPlaying() {
            print("🎬 AVPlayerWrapper: Already playing")
            return
        }
        
        playbackStartTime = Date()
        equalizerManager.play()
        state = .playing
        startProgressTracking()
    }
    
    func pause() {
        print("⏸️ AVPlayerWrapper: pause() called - using pure AVAudioEngine")
        playWhenReady = false
        
        // Update paused time
        if let startTime = playbackStartTime {
            pausedTime += Date().timeIntervalSince(startTime)
        }
        playbackStartTime = nil
        
        equalizerManager.pause()
        state = .paused
        stopProgressTracking()
    }
    
    func togglePlaying() {
        if equalizerManager.isPlaying() {
            pause()
        } else {
            play()
        }
    }
    
    func stop() {
        print("⏹️ AVPlayerWrapper: stop() called - using pure AVAudioEngine")
        state = .stopped
        playWhenReady = false
        pausedTime = 0
        playbackStartTime = nil
        equalizerManager.stop()
        stopProgressTracking()
    }
    
    func seek(to seconds: TimeInterval) {
        print("⏩ AVPlayerWrapper: seek(to:) called with \(seconds) seconds")
        // For AVAudioEngine implementation, seeking is more complex
        // For now, store the seek time and implement basic seeking
        timeToSeekToAfterLoading = seconds
        pausedTime = seconds
        
        // Notify delegate that seek completed
        delegate?.AVWrapper(seekTo: seconds, didFinish: true)
    }

    func seek(by seconds: TimeInterval) {
        print("⏩ AVPlayerWrapper: seek(by:) called with \(seconds) seconds")
        let newTime = currentTime + seconds
        seek(to: newTime)
    }
    
    private func playbackFailed(error: AudioPlayerError.PlaybackError) {
        state = .failed
        self.playbackError = error
        self.delegate?.AVWrapper(failedWithError: error)
    }
    
    func load() {
        print("📂 AVPlayerWrapper: load() called - simplified for AVAudioEngine")
        // For AVAudioEngine implementation, this is handled by loadAudio
        // Just set state to ready
        state = .ready
    }
    
    func load(from url: URL, playWhenReady: Bool, options: [String: Any]? = nil) {
        print("🎵 AVPlayerWrapper: load() called with URL: \(url)")
        self.playWhenReady = playWhenReady
        self.url = url
        self.urlOptions = options
        
        // Reset state
        pausedTime = 0
        playbackStartTime = nil
        
        // Load directly into AVAudioEngine with PCM buffers
        state = .loading
        equalizerManager.loadAudio(from: url)
        
        // Set state to ready - the equalizer manager handles the actual loading
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self else { return }
            self.state = .ready
            
            if self.playWhenReady {
                self.play()
            }
        }
    }
    
    func load(
        from url: URL,
        playWhenReady: Bool,
        initialTime: TimeInterval? = nil,
        options: [String : Any]? = nil
    ) {
        self.load(from: url, playWhenReady: playWhenReady, options: options)
        if let initialTime = initialTime {
            self.seek(to: initialTime)
        }
    }

    func load(
        from url: String,
        type: SourceType = .stream,
        playWhenReady: Bool = false,
        initialTime: TimeInterval? = nil,
        options: [String : Any]? = nil
    ) {
        if let itemUrl = type == .file
            ? URL(fileURLWithPath: url)
            : URL(string: url)
        {
            self.load(from: itemUrl, playWhenReady: playWhenReady, options: options)
            if let initialTime = initialTime {
                self.seek(to: initialTime)
            }
        } else {
            playbackFailed(error: AudioPlayerError.PlaybackError.invalidSourceUrl(url))
        }
    }

    func unload() {
        print("📂 AVPlayerWrapper: unload() called")
        state = .idle
        equalizerManager.stop()
        pausedTime = 0
        playbackStartTime = nil
    }

    func reload(startFromCurrentTime: Bool) {
        print("🔄 AVPlayerWrapper: reload() called")
        let currentTimeToRestore = startFromCurrentTime ? currentTime : 0
        
        if let url = url {
            load(from: url, playWhenReady: playWhenReady, options: urlOptions)
            if startFromCurrentTime {
                seek(to: currentTimeToRestore)
            }
        }
    }
    
    // MARK: - Audio Engine Setup
    
    private func setupAudioEngine() {
        print("🚀 AVPlayerWrapper: setupAudioEngine called")
        // Initialize AVAudioEngine equalizer (always active)
        equalizerManager.setEnabled(true)  // Always enable for processing
        print("✅ AVPlayerWrapper: AVAudioEngine initialized and ready")
    }
    
    private func setupProgressTracking() {
        print("⏱️ AVPlayerWrapper: Setting up progress tracking")
    }
    
    private func startProgressTracking() {
        stopProgressTracking()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.delegate?.AVWrapper(secondsElapsed: self.currentTime)
        }
    }
    
    private func stopProgressTracking() {
        progressTimer?.invalidate()
        progressTimer = nil
    }
    
    
    // MARK: - Equalizer Public Interface
    // Added methods for equalizer control
    
    /// Enable or disable the equalizer
    public func setEqualizerEnabled(_ enabled: Bool) {
        print("🔧 AVPlayerWrapper: setEqualizerEnabled called with: \(enabled)")
        equalizerEnabled = enabled
        
        if enabled {
            // Apply current preset when enabling
            if let preset = EqualizerPreset(rawValue: currentEqualizerPreset) {
                print("🔧 AVPlayerWrapper: Enabling with preset: \(preset.rawValue)")
                equalizerManager.applyPreset(preset)
            } else {
                print("🔧 AVPlayerWrapper: Enabling with default flat preset")
                equalizerManager.applyPreset(.flat)
            }
        } else {
            // Apply flat preset when disabling
            print("🔧 AVPlayerWrapper: Disabling equalizer - applying flat preset")
            equalizerManager.applyPreset(.flat)
        }
        
        print("🔧 AVPlayerWrapper: Equalizer enabled: \(enabled)")
    }
    
    /// Apply a specific equalizer preset
    public func setEqualizerPreset(_ preset: String) {
        print("🎯 AVPlayerWrapper: setEqualizerPreset called with: \(preset)")
        currentEqualizerPreset = preset
        
        // Apply preset through equalizer manager
        if let eqPreset = EqualizerPreset(rawValue: preset) {
            print("🎯 AVPlayerWrapper: Found matching preset enum: \(eqPreset.rawValue)")
            equalizerManager.applyPreset(eqPreset)
        } else {
            print("❌ AVPlayerWrapper: Could not find preset enum for: \(preset)")
        }
        
        // Log preset change
        print("🎯 AVPlayerWrapper: Setting equalizer preset to: \(preset)")
    }
    
    /// Get the current equalizer preset
    public func getEqualizerPreset() -> String {
        return currentEqualizerPreset
    }
    
    /// Check if equalizer is enabled
    public func isEqualizerEnabled() -> Bool {
        return equalizerEnabled
    }
    
    /// Get all available equalizer presets
    public func getAvailableEqualizerPresets() -> [String] {
        return ["flat", "voice1", "voice2", "voice3", "soundEffect1", "soundEffect2", "soundEffect3"]
    }
    
}

extension EqualizerManager {
    // MARK: - Helper Methods
    
    func reconnectNodesWithFormat(_ format: AVAudioFormat) {
        print("🔧 EqualizerManager: Reconnecting audio nodes with format: \(format.description)")
        
        // Disconnect existing connections
        audioEngine.disconnectNodeInput(equalizer)
        audioEngine.disconnectNodeInput(audioEngine.mainMixerNode)
        
        // Reconnect with new format
        audioEngine.connect(playerNode, to: equalizer, format: format)
        audioEngine.connect(equalizer, to: audioEngine.mainMixerNode, format: format)
        
        print("🔧 EqualizerManager: Nodes reconnected with new format")
    }
}
