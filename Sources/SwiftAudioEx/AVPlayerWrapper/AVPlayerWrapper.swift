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
    // MARK: - Properties - AVPlayer + AVAudioEngine Implementation
    
    // AVPlayer for streaming and seek (silent)
    private var mainAVPlayer: AVPlayer?
    private var currentPlayerItem: AVPlayerItem?
    
    // AVAudioEngine for equalizer processing
    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let equalizerUnit = AVAudioUnitEQ(numberOfBands: 5)
    private var currentEqualizerPreset: String = "flat"
    private var equalizerEnabled: Bool = false
    
    // Audio file for AVAudioEngine playback
    private var audioFile: AVAudioFile?
    private var isEnginePlaybackActive = false
    private var isAudioEngineReady = false
    private var isUsingTemporaryAVPlayer = false
    
    // Temporary file tracking
    private var temporaryFiles: Set<URL> = []
    
    // KVO for player item status
    private var playerItemStatusObserver: NSKeyValueObservation?
    
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
        print("🚀 AVPlayerWrapper: Initializing AVPlayer + AVAudioEngine implementation")
        setupAVPlayer()
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
        // Get current time from AVPlayer
        guard let player = mainAVPlayer else { return pausedTime }
        
        let currentCMTime = player.currentTime()
        if currentCMTime.isValid && !currentCMTime.isIndefinite {
            return CMTimeGetSeconds(currentCMTime)
        }
        
        // Fallback to calculated time
        if player.rate > 0, let startTime = playbackStartTime {
            return pausedTime + Date().timeIntervalSince(startTime)
        }
        return pausedTime
    }
    
    var duration: TimeInterval {
        // Get duration from AVPlayerItem
        guard let playerItem = currentPlayerItem else { return 0 }
        
        let durationCMTime = playerItem.duration
        if durationCMTime.isValid && !durationCMTime.isIndefinite {
            return CMTimeGetSeconds(durationCMTime)
        }
        
        // Return 0 for live streams or unknown duration
        return 0
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
            // Apply rate to AVPlayer
            mainAVPlayer?.rate = newValue
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
            print("🔊 AVPlayerWrapper: Setting volume to \(newValue) on AudioEngine")
            audioEngineVolume = newValue
            // Apply volume to AudioEngine
            audioEngine.mainMixerNode.outputVolume = newValue
            // Keep AVPlayer muted
            mainAVPlayer?.volume = 0.0
            avPlayer.volume = 0.0
        }
    }
    
    var isMuted: Bool {
        get { audioEngineVolume == 0.0 }
        set { 
            if newValue {
                audioEngine.mainMixerNode.outputVolume = 0.0
            } else {
                audioEngine.mainMixerNode.outputVolume = audioEngineVolume
            }
        }
    }

    var automaticallyWaitsToMinimizeStalling: Bool {
        get { true }
        set { /* Not applicable for this implementation */ }
    }
    
    // Required protocol properties
    var currentItem: AVPlayerItem? {
        get { _currentItem }
    }
    
    var reasonForWaitingToPlay: AVPlayer.WaitingReason? {
        get { nil }
    }
    
    // Add playbackState computed property for compatibility
    var playbackState: AVPlayerWrapperState {
        get {
            // If AVPlayer is actively playing, ensure we return playing state
            if let player = mainAVPlayer, player.rate > 0 && state != .playing {
                return .playing
            }
            return state
        }
    }
    
    func play() {
        print("🎬 AVPlayerWrapper: play() called")
        playWhenReady = true
        
        // Check if we're still loading
        if state == .loading {
            print("⏳ AVPlayerWrapper: Still loading, will play when ready")
            return
        }
        
        if isEnginePlaybackActive || isUsingTemporaryAVPlayer {
            print("🎬 AVPlayerWrapper: Already playing")
            return
        }
        
        // Check if AudioEngine is ready
        if let audioFile = audioFile, isAudioEngineReady {
            print("🎵 AVPlayerWrapper: Using AudioEngine with equalizer")
            // Start AVPlayer for seek tracking (muted)
            mainAVPlayer?.play()
            
            // Start AudioEngine playback with equalizer
            playWithAudioEngine(audioFile: audioFile)
            
            playbackStartTime = Date()
            state = .playing
            startProgressTracking()
            print("✅ AVPlayerWrapper: Started playback with AudioEngine + Equalizer")
        } else if currentPlayerItem?.status == .readyToPlay {
            print("🎵 AVPlayerWrapper: AudioEngine not ready, using AVPlayer for immediate playback")
            // Use AVPlayer for immediate playback
            playWithAVPlayer()
        } else {
            print("❌ AVPlayerWrapper: Neither AudioEngine nor AVPlayer ready for playback")
        }
    }
    
    private func playWithAudioEngine(audioFile: AVAudioFile) {
        // Schedule the entire file for playback
        playerNode.scheduleFile(audioFile, at: nil) { [weak self] in
            DispatchQueue.main.async {
                self?.isEnginePlaybackActive = false
                print("🎵 AVPlayerWrapper: AudioEngine playback completed")
            }
        }
        
        playerNode.play()
        isEnginePlaybackActive = true
        print("🎵 AVPlayerWrapper: AudioEngine playback started")
    }
    
    func pause() {
        print("⏸️ AVPlayerWrapper: pause() called")
        playWhenReady = false
        
        // Update paused time
        if let startTime = playbackStartTime {
            pausedTime += Date().timeIntervalSince(startTime)
        }
        playbackStartTime = nil
        
        // Pause based on current playback method
        if isEnginePlaybackActive {
            playerNode.pause()
            isEnginePlaybackActive = false
        }
        
        if isUsingTemporaryAVPlayer {
            isUsingTemporaryAVPlayer = false
        }
        
        // Always pause AVPlayer
        mainAVPlayer?.pause()
        
        state = .paused
        stopProgressTracking()
        print("✅ AVPlayerWrapper: Paused playback")
    }
    
    func togglePlaying() {
        if isEnginePlaybackActive {
            pause()
        } else {
            play()
        }
    }
    
    func stop() {
        print("⏹️ AVPlayerWrapper: stop() called - using AudioEngine")
        
        state = .stopped
        playWhenReady = false
        pausedTime = 0
        playbackStartTime = nil
        
        // Stop AudioEngine playback
        if isEnginePlaybackActive {
            playerNode.stop()
            isEnginePlaybackActive = false
        }
        
        // Stop and reset AVPlayer
        mainAVPlayer?.pause()
        mainAVPlayer?.seek(to: CMTime.zero)
        
        stopProgressTracking()
        print("✅ AVPlayerWrapper: Stopped playback with AudioEngine")
    }
    
    func seek(to seconds: TimeInterval) {
        print("⏩ AVPlayerWrapper: seek(to:) called with \(seconds) seconds")
        
        guard let player = mainAVPlayer else {
            print("❌ AVPlayerWrapper: No AVPlayer available")
            return
        }
        
        // Check if player is ready for seeking
        guard let playerItem = currentPlayerItem, playerItem.status == .readyToPlay else {
            print("❌ AVPlayerWrapper: Player item not ready for seeking")
            // Store seek time for later when player is ready
            timeToSeekToAfterLoading = seconds
            return
        }
        
        let time = CMTime(seconds: seconds, preferredTimescale: 1000)
        let wasPlaying = isEnginePlaybackActive || isUsingTemporaryAVPlayer
        let wasUsingEngine = isEnginePlaybackActive
        
        // Stop current playback
        if isEnginePlaybackActive {
            playerNode.stop()
            isEnginePlaybackActive = false
        }
        
        print("🔄 AVPlayerWrapper: Seeking to \(seconds)s, was playing: \(wasPlaying), using engine: \(wasUsingEngine)")
        
        // Seek AVPlayer
        player.seek(to: time, toleranceBefore: CMTime.zero, toleranceAfter: CMTime.zero) { [weak self] completed in
            DispatchQueue.main.async {
                guard let self = self else { return }
                
                if completed {
                    print("✅ AVPlayerWrapper: Seek completed to \(seconds) seconds")
                    self.pausedTime = seconds
                    
                    // Clear any pending seek time
                    self.timeToSeekToAfterLoading = nil
                    
                    // Resume playback if was playing
                    if wasPlaying {
                        if let audioFile = self.audioFile, self.isAudioEngineReady {
                            // Use AudioEngine if available
                            self.seekAndResumeAudioEngine(to: seconds, audioFile: audioFile)
                        } else {
                            // Continue with AVPlayer
                            self.playbackStartTime = Date()
                            self.mainAVPlayer?.play()
                        }
                    }
                } else {
                    print("❌ AVPlayerWrapper: Seek failed")
                }
                self.delegate?.AVWrapper(seekTo: seconds, didFinish: completed)
            }
        }
    }
    
    private func seekAndResumeAudioEngine(to seconds: TimeInterval, audioFile: AVAudioFile) {
        print("🎵 AVPlayerWrapper: Seeking and resuming AudioEngine to \(seconds)s")
        
        // Ensure player node is stopped
        if playerNode.isPlaying {
            playerNode.stop()
        }
        
        // Calculate frame position for seek
        let sampleRate = audioFile.fileFormat.sampleRate
        let framePosition = AVAudioFramePosition(seconds * sampleRate)
        let maxFrame = audioFile.length
        let clampedPosition = max(0, min(framePosition, maxFrame))
        
        print("🎵 AVPlayerWrapper: Seeking to frame \(clampedPosition) of \(maxFrame)")
        
        // Schedule playback from new position
        let frameCount = AVAudioFrameCount(maxFrame - clampedPosition)
        if frameCount > 0 {
            // Schedule the segment
            playerNode.scheduleSegment(audioFile, startingFrame: clampedPosition, frameCount: frameCount, at: nil) { [weak self] in
                DispatchQueue.main.async {
                    print("🎵 AVPlayerWrapper: AudioEngine seek segment completed")
                    // Don't set isEnginePlaybackActive to false here if we want continuous playback
                }
            }
            
            // Start playback
            playerNode.play()
            isEnginePlaybackActive = true
            playbackStartTime = Date()
            state = .playing
            startProgressTracking()
            
            print("✅ AVPlayerWrapper: AudioEngine resumed from position \(seconds)s")
        } else {
            print("❌ AVPlayerWrapper: No frames to play from position \(seconds)s")
        }
    }
    
    private func restartAudioEngineFromPosition(_ seconds: TimeInterval, audioFile: AVAudioFile) {
        // This method is kept for backwards compatibility but uses the new implementation
        seekAndResumeAudioEngine(to: seconds, audioFile: audioFile)
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
        print("📂 AVPlayerWrapper: load() called - AudioEngine needs URL, doing nothing")
        // For AVAudioEngine implementation, this method doesn't make sense without a URL
        // The proper load method is load(from:playWhenReady:options:)
        // Don't change state here as we don't have any content to load
    }
    
    func load(from url: URL, playWhenReady: Bool, options: [String: Any]? = nil) {
        print("🎵 AVPlayerWrapper: load() called with URL: \(url)")
        self.playWhenReady = playWhenReady
        self.url = url
        self.urlOptions = options
        
        // Stop current playback and clean up
        stop()
        audioFile = nil
        isAudioEngineReady = false
        isUsingTemporaryAVPlayer = false
        cleanupTemporaryFiles()
        
        // Reset AudioEngine to prepare for new audio format
        resetAudioEngineForNewTrack()
        
        // Reset state
        pausedTime = 0
        playbackStartTime = nil
        state = .loading
        
        // Create AVPlayerItem for immediate playback
        let playerItem = AVPlayerItem(url: url)
        currentPlayerItem = playerItem
        
        // Optimize buffering for fast start but stable playback
        playerItem.preferredForwardBufferDuration = 3.0  // Buffer 3 seconds ahead for stability
        playerItem.canUseNetworkResourcesForLiveStreamingWhilePaused = false
        
        mainAVPlayer?.replaceCurrentItem(with: playerItem)
        
        // For all files, enable immediate playback capability
        print("🚀 AVPlayerWrapper: Setting up fast start capability")
        setupImmediatePlayback()
        
        // Download audio file for AudioEngine in background
        downloadAudioFile(from: url) { [weak self] success in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if success {
                    print("✅ AVPlayerWrapper: AudioEngine file ready")
                    self.isAudioEngineReady = true
                    
                    // If using temporary AVPlayer and playing, switch to AudioEngine
                    if self.isUsingTemporaryAVPlayer && self.state == .playing {
                        self.switchToAudioEngine()
                    } else if self.state == .loading {
                        // Normal flow for local files or when not playing yet
                        self.state = .ready
                        if self.playWhenReady {
                            self.play()
                        }
                    }
                } else {
                    print("⚠️ AVPlayerWrapper: AudioEngine load failed, continuing with AVPlayer only")
                    if self.state == .loading {
                        // Still mark as ready if AVPlayer is available
                        self.state = .ready
                        if self.playWhenReady {
                            self.play()
                        }
                    }
                }
            }
        }
        
        print("✅ AVPlayerWrapper: Load initiated")
    }
    
    private func setupImmediatePlayback() {
        guard let playerItem = currentPlayerItem else { return }
        
        // Clean up previous observer
        playerItemStatusObserver?.invalidate()
        
        // Use KVO for faster status detection
        playerItemStatusObserver = playerItem.observe(\.status, options: [.new, .initial]) { [weak self] item, _ in
            guard let self = self else { return }
            
            switch item.status {
            case .readyToPlay:
                if self.state == .loading {
                    print("✅ AVPlayerWrapper: AVPlayer ready for immediate playback (via KVO)")
                    self.state = .ready
                    
                    // Clean up observer
                    self.playerItemStatusObserver?.invalidate()
                    self.playerItemStatusObserver = nil
                    
                    if self.playWhenReady {
                        self.playWithAVPlayer()
                    }
                }
            case .failed:
                print("❌ AVPlayerWrapper: AVPlayer failed")
                self.state = .failed
                self.playerItemStatusObserver?.invalidate()
                self.playerItemStatusObserver = nil
            case .unknown:
                break
            @unknown default:
                break
            }
        }
    }
    
    private func playWithAVPlayer() {
        print("🎬 AVPlayerWrapper: Starting immediate playback with AVPlayer")
        isUsingTemporaryAVPlayer = true
        mainAVPlayer?.volume = audioEngineVolume  // Unmute temporarily
        mainAVPlayer?.play()
        playbackStartTime = Date()
        state = .playing
        startProgressTracking()
    }
    
    private func switchToAudioEngine() {
        guard let audioFile = audioFile else { return }
        
        print("🔄 AVPlayerWrapper: Switching from AVPlayer to AudioEngine")
        let currentPlayTime = currentTime
        
        // Ensure smooth transition
        if currentPlayTime > 0 && currentPlayTime < duration - 1.0 {
            // Stop AVPlayer
            mainAVPlayer?.pause()
            mainAVPlayer?.volume = 0.0  // Mute again
            isUsingTemporaryAVPlayer = false
            
            // Start AudioEngine from current position
            seekAndResumeAudioEngine(to: currentPlayTime, audioFile: audioFile)
            
            print("✅ AVPlayerWrapper: Successfully switched to AudioEngine with equalizer")
        } else {
            print("⚠️ AVPlayerWrapper: Skipping switch - near beginning or end of track")
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
        
        // Clean up KVO observer
        playerItemStatusObserver?.invalidate()
        playerItemStatusObserver = nil
        
        // Clean up AVPlayer
        mainAVPlayer?.pause()
        mainAVPlayer?.replaceCurrentItem(with: nil)
        
        currentPlayerItem = nil
        
        pausedTime = 0
        playbackStartTime = nil
        
        print("✅ AVPlayerWrapper: Unloaded successfully")
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
    
    // MARK: - AVPlayer + AudioEngine Setup
    
    private func setupAVPlayer() {
        print("🚀 AVPlayerWrapper: Setting up AVPlayer")
        mainAVPlayer = AVPlayer()
        mainAVPlayer?.volume = 0.0  // Mute AVPlayer, audio goes through AudioEngine
        
        // Optimize for immediate playback
        mainAVPlayer?.automaticallyWaitsToMinimizeStalling = false
        
        print("✅ AVPlayerWrapper: AVPlayer initialized (muted)")
    }
    
    private func setupAudioEngine() {
        print("🚀 AVPlayerWrapper: Setting up AudioEngine with equalizer")
        
        // Configure equalizer bands
        setupEqualizerBands()
        
        // Attach nodes to audio engine
        audioEngine.attach(playerNode)
        audioEngine.attach(equalizerUnit)
        
        // Connect audio chain: playerNode -> equalizer -> output
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        audioEngine.connect(playerNode, to: equalizerUnit, format: format)
        audioEngine.connect(equalizerUnit, to: audioEngine.mainMixerNode, format: format)
        
        // Prepare and start audio engine
        audioEngine.prepare()
        
        do {
            try audioEngine.start()
            print("✅ AVPlayerWrapper: AudioEngine started successfully")
        } catch {
            print("❌ AVPlayerWrapper: Failed to start AudioEngine: \(error)")
        }
        
        print("✅ AVPlayerWrapper: AudioEngine configured with equalizer")
    }
    
    private func setupEqualizerBands() {
        let frequencies: [Float] = [500, 1000, 2000, 4000, 8000]
        
        for (index, frequency) in frequencies.enumerated() {
            if index < equalizerUnit.bands.count {
                let band = equalizerUnit.bands[index]
                band.filterType = .parametric
                band.frequency = frequency
                band.bandwidth = 1.0
                band.gain = 0.0 // Start with flat response
                band.bypass = false
                print("🎛️ AVPlayerWrapper: Configured band \(index): \(frequency)Hz")
            }
        }
    }
    
    private func resetAudioEngineForNewTrack() {
        print("🔄 AVPlayerWrapper: Resetting AudioEngine for new track")
        
        // Stop the player node if it's playing
        if playerNode.isPlaying {
            playerNode.stop()
        }
        
        // Stop audio engine
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        
        // Complete reset to avoid format conflicts
        audioEngine.reset()
        
        print("✅ AVPlayerWrapper: AudioEngine reset completed")
    }
    
    private func setupAudioEngineWithFormat(_ format: AVAudioFormat) {
        print("🎵 AVPlayerWrapper: Setting up AudioEngine with format: \(format)")
        
        // Ensure audio engine is stopped before reconfiguring
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        
        // Reset all connections
        audioEngine.reset()
        
        // Attach nodes (they were detached by reset)
        audioEngine.attach(playerNode)
        audioEngine.attach(equalizerUnit)
        
        // Re-setup equalizer bands after reset
        setupEqualizerBands()
        
        // Use a compatible format - convert to standard format if needed
        let compatibleFormat: AVAudioFormat
        if format.sampleRate == 44100 && format.channelCount == 2 {
            compatibleFormat = format
        } else {
            // Create a standard format that's compatible with equalizer
            guard let standardFormat = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: format.channelCount) else {
                print("❌ AVPlayerWrapper: Failed to create compatible format")
                return
            }
            compatibleFormat = standardFormat
            print("⚠️ AVPlayerWrapper: Using standardized format for compatibility")
        }
        
        do {
            // Connect with error handling
            audioEngine.connect(playerNode, to: equalizerUnit, format: compatibleFormat)
            audioEngine.connect(equalizerUnit, to: audioEngine.mainMixerNode, format: compatibleFormat)
            
            // Re-apply current equalizer settings
            if let currentPreset = EqualizerPreset(rawValue: currentEqualizerPreset) {
                applyEqualizerPreset(currentPreset)
            }
            
            // Prepare and start audio engine
            audioEngine.prepare()
            try audioEngine.start()
            
            print("✅ AVPlayerWrapper: AudioEngine restarted with format: \(compatibleFormat)")
        } catch {
            print("❌ AVPlayerWrapper: Failed to setup AudioEngine: \(error)")
            print("❌ AVPlayerWrapper: Error code: \((error as NSError).code)")
            
            // Fallback to default format
            if let defaultFormat = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2) {
                do {
                    audioEngine.reset()
                    audioEngine.attach(playerNode)
                    audioEngine.attach(equalizerUnit)
                    
                    // Re-setup equalizer bands for fallback
                    setupEqualizerBands()
                    
                    audioEngine.connect(playerNode, to: equalizerUnit, format: defaultFormat)
                    audioEngine.connect(equalizerUnit, to: audioEngine.mainMixerNode, format: defaultFormat)
                    
                    // Re-apply current equalizer settings for fallback
                    if let currentPreset = EqualizerPreset(rawValue: currentEqualizerPreset) {
                        applyEqualizerPreset(currentPreset)
                    }
                    
                    audioEngine.prepare()
                    try audioEngine.start()
                    print("✅ AVPlayerWrapper: AudioEngine started with fallback format")
                } catch {
                    print("❌ AVPlayerWrapper: Failed to start with fallback format: \(error)")
                }
            }
        }
    }
    
    private func downloadAudioFile(from url: URL, completion: @escaping (Bool) -> Void) {
        print("📥 AVPlayerWrapper: Downloading audio file for AudioEngine")
        
        if url.isFileURL {
            // Local file
            loadLocalAudioFile(url: url, completion: completion)
        } else {
            // Remote file - download it
            downloadRemoteAudioFile(url: url, completion: completion)
        }
    }
    
    private func loadLocalAudioFile(url: URL, completion: @escaping (Bool) -> Void) {
        do {
            audioFile = try AVAudioFile(forReading: url)
            print("✅ AVPlayerWrapper: Local audio file loaded for AudioEngine")
            
            // Setup AudioEngine with the actual file format
            if let fileFormat = audioFile?.processingFormat {
                setupAudioEngineWithFormat(fileFormat)
                print("🎵 AVPlayerWrapper: AudioEngine configured with file format: \(fileFormat)")
            }
            
            completion(true)
        } catch {
            print("❌ AVPlayerWrapper: Failed to load local audio file: \(error)")
            completion(false)
        }
    }
    
    private func downloadRemoteAudioFile(url: URL, completion: @escaping (Bool) -> Void) {
        URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            guard let self = self, let data = data, error == nil else {
                print("❌ AVPlayerWrapper: Failed to download audio file: \(error?.localizedDescription ?? "Unknown error")")
                completion(false)
                return
            }
            
            // Create temporary file
            let tempURL = self.createTemporaryAudioFile(from: data)
            
            do {
                self.audioFile = try AVAudioFile(forReading: tempURL)
                print("✅ AVPlayerWrapper: Remote audio file downloaded and loaded for AudioEngine")
                
                // Setup AudioEngine with the actual file format
                if let fileFormat = self.audioFile?.processingFormat {
                    DispatchQueue.main.async {
                        self.setupAudioEngineWithFormat(fileFormat)
                        print("🎵 AVPlayerWrapper: AudioEngine configured with downloaded file format: \(fileFormat)")
                    }
                }
                
                completion(true)
            } catch {
                print("❌ AVPlayerWrapper: Failed to create audio file from downloaded data: \(error)")
                completion(false)
            }
        }.resume()
    }
    
    private func createTemporaryAudioFile(from data: Data) -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let tempURL = tempDir.appendingPathComponent(UUID().uuidString + ".m4a")
        
        do {
            try data.write(to: tempURL)
            temporaryFiles.insert(tempURL)
            print("💾 AVPlayerWrapper: Created temporary audio file: \(tempURL)")
        } catch {
            print("❌ AVPlayerWrapper: Failed to create temporary audio file: \(error)")
        }
        
        return tempURL
    }
    
    private func cleanupTemporaryFiles() {
        for tempURL in temporaryFiles {
            do {
                if FileManager.default.fileExists(atPath: tempURL.path) {
                    try FileManager.default.removeItem(at: tempURL)
                    print("🧹 AVPlayerWrapper: Deleted temporary file: \(tempURL.lastPathComponent)")
                }
            } catch {
                print("❌ AVPlayerWrapper: Failed to delete temporary file: \(error)")
            }
        }
        temporaryFiles.removeAll()
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
                applyEqualizerPreset(preset)
            } else {
                print("🔧 AVPlayerWrapper: Enabling with default flat preset")
                applyEqualizerPreset(.flat)
            }
        } else {
            // Apply flat preset when disabling
            print("🔧 AVPlayerWrapper: Disabling equalizer - applying flat preset")
            applyEqualizerPreset(.flat)
        }
        
        print("🔧 AVPlayerWrapper: Equalizer enabled: \(enabled)")
    }
    
    /// Apply a specific equalizer preset
    public func setEqualizerPreset(_ preset: String) {
        print("🎯 AVPlayerWrapper: setEqualizerPreset called with: \(preset)")
        currentEqualizerPreset = preset
        
        // Apply preset through equalizer unit
        if let eqPreset = EqualizerPreset(rawValue: preset) {
            print("🎯 AVPlayerWrapper: Found matching preset enum: \(eqPreset.rawValue)")
            applyEqualizerPreset(eqPreset)
        } else {
            print("❌ AVPlayerWrapper: Could not find preset enum for: \(preset)")
        }
        
        print("🎯 AVPlayerWrapper: Equalizer preset set to: \(preset)")
    }
    
    private func applyEqualizerPreset(_ preset: EqualizerPreset) {
        print("🎵 AVPlayerWrapper: Applying preset \(preset.rawValue)")
        let gains = preset.gains
        let frequencies: [Float] = [500, 1000, 2000, 4000, 8000]
        
        for (index, frequency) in frequencies.enumerated() {
            if index < equalizerUnit.bands.count {
                let band = equalizerUnit.bands[index]
                let newGain = gains[frequency] ?? 0.0
                print("🎵 AVPlayerWrapper: Setting band \(index) (freq: \(frequency)Hz) gain: \(newGain)dB")
                band.gain = newGain
                band.bypass = false  // Ensure band is not bypassed
                print("🎵 AVPlayerWrapper: Band \(index) actual gain after setting: \(band.gain)dB, bypass: \(band.bypass)")
            }
        }
        
        print("✅ AVPlayerWrapper: Preset \(preset.rawValue) applied to AVAudioUnitEQ")
        print("🔍 AVPlayerWrapper: AudioEngine running: \(audioEngine.isRunning), Engine ready: \(isAudioEngineReady)")
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
