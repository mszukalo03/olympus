/// Audio Player Service
/// ---------------------------------------------------------------------------
/// Service for managing audio playback in chat messages.
/// Provides centralized audio control with state management.


import 'dart:async';
import 'dart:io';
import 'dart:convert';


import 'package:audioplayers/audioplayers.dart';
import 'package:logging/logging.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/core.dart';
import '../models/chat_message.dart';

/// Audio playback state
enum AudioPlaybackState {
  stopped,
  playing,
  paused,
  loading,
  error,
}

/// Audio player instance data
class AudioPlayerInstance {
  final String attachmentId;
  final AudioPlayer player;
  final StreamSubscription<Duration> positionSubscription;
  final StreamSubscription<Duration> durationSubscription;
  final StreamSubscription<PlayerState> stateSubscription;

  AudioPlayerInstance({
    required this.attachmentId,
    required this.player,
    required this.positionSubscription,
    required this.durationSubscription,
    required this.stateSubscription,
  });

  void dispose() {
    positionSubscription.cancel();
    durationSubscription.cancel();
    stateSubscription.cancel();
    player.dispose();
  }
}

/// Audio player state data
class AudioState {
  final String attachmentId;
  final AudioPlaybackState state;
  final Duration position;
  final Duration duration;
  final String? error;

  const AudioState({
    required this.attachmentId,
    required this.state,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.error,
  });

  AudioState copyWith({
    String? attachmentId,
    AudioPlaybackState? state,
    Duration? position,
    Duration? duration,
    String? error,
  }) {
    return AudioState(
      attachmentId: attachmentId ?? this.attachmentId,
      state: state ?? this.state,
      position: position ?? this.position,
      duration: duration ?? this.duration,
      error: error ?? this.error,
    );
  }

  double get progress {
    if (duration.inMilliseconds <= 0) return 0.0;
    return (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0);
  }

  bool get isPlaying => state == AudioPlaybackState.playing;
  bool get isPaused => state == AudioPlaybackState.paused;
  bool get isLoading => state == AudioPlaybackState.loading;
  bool get hasError => state == AudioPlaybackState.error;
}

/// Service for managing audio playback
class AudioPlayerService {
  static final AudioPlayerService _instance = AudioPlayerService._();
  factory AudioPlayerService() => _instance;
  static AudioPlayerService get instance => _instance;
  AudioPlayerService._();

  static final Logger _log = Logger('AudioPlayerService');

  final Map<String, AudioPlayerInstance> _players = {};
  final Map<String, AudioState> _states = {};
  final StreamController<AudioState> _stateController = StreamController.broadcast();

  String? _currentlyPlayingId;

  /// Stream of audio state changes
  Stream<AudioState> get stateStream => _stateController.stream;

  /// Get current state for an attachment
  AudioState? getState(String attachmentId) => _states[attachmentId];

  /// Get current playing attachment ID
  String? get currentlyPlayingId => _currentlyPlayingId;

  /// Play audio attachment
  Future<Result<void>> playAudio(MessageAttachment attachment) async {
    if (attachment.type != AttachmentType.audio) {
      return const Failure(
        AppError(
          message: 'Attachment is not an audio file',
          type: ErrorType.validation,
        ),
      );
    }

    return catchingAsync(() async {
      final attachmentId = attachment.id;

      // Stop any currently playing audio
      if (_currentlyPlayingId != null && _currentlyPlayingId != attachmentId) {
        await _stopAudio(_currentlyPlayingId!);
      }

      // Update state to loading
      _updateState(attachmentId, AudioPlaybackState.loading);

      // Get or create player instance
      AudioPlayerInstance? playerInstance = _players[attachmentId];
      if (playerInstance == null) {
        playerInstance = await _createPlayerInstance(attachment);
        _players[attachmentId] = playerInstance;
      }

      // Play the audio
      final audioSource = await _getAudioSource(attachment);
      await playerInstance.player.play(audioSource);

      _currentlyPlayingId = attachmentId;
      _log.info('Started playing audio: ${attachment.fileName}');
    });
  }

  /// Pause audio
  Future<Result<void>> pauseAudio(String attachmentId) async {
    return catchingAsync(() async {
      final playerInstance = _players[attachmentId];
      if (playerInstance == null) {
        throw AppError(
          message: 'Audio player not found',
          type: ErrorType.notFound,
        );
      }

      await playerInstance.player.pause();
      _updateState(attachmentId, AudioPlaybackState.paused);

      if (_currentlyPlayingId == attachmentId) {
        _currentlyPlayingId = null;
      }

      _log.info('Paused audio: $attachmentId');
    });
  }

  /// Resume audio
  Future<Result<void>> resumeAudio(String attachmentId) async {
    return catchingAsync(() async {
      final playerInstance = _players[attachmentId];
      if (playerInstance == null) {
        throw AppError(
          message: 'Audio player not found',
          type: ErrorType.notFound,
        );
      }

      // Stop any other currently playing audio
      if (_currentlyPlayingId != null && _currentlyPlayingId != attachmentId) {
        await _stopAudio(_currentlyPlayingId!);
      }

      await playerInstance.player.resume();
      _currentlyPlayingId = attachmentId;
      _log.info('Resumed audio: $attachmentId');
    });
  }

  /// Stop audio
  Future<Result<void>> stopAudio(String attachmentId) async {
    return catchingAsync(() async {
      await _stopAudio(attachmentId);
    });
  }

  /// Seek to position
  Future<Result<void>> seekTo(String attachmentId, Duration position) async {
    return catchingAsync(() async {
      final playerInstance = _players[attachmentId];
      if (playerInstance == null) {
        throw AppError(
          message: 'Audio player not found',
          type: ErrorType.notFound,
        );
      }

      await playerInstance.player.seek(position);
      _log.info('Seeked audio $attachmentId to ${position.inSeconds}s');
    });
  }

  /// Stop all audio playback
  Future<void> stopAll() async {
    final playingIds = List<String>.from(_players.keys);
    for (final id in playingIds) {
      try {
        await _stopAudio(id);
      } catch (e) {
        _log.warning('Failed to stop audio $id: $e');
      }
    }
    _currentlyPlayingId = null;
  }

  /// Clean up unused players
  Future<void> cleanup() async {
    final stoppedPlayers = <String>[];

    for (final entry in _players.entries) {
      final id = entry.key;
      final instance = entry.value;
      final state = _states[id];

      if (state?.state == AudioPlaybackState.stopped) {
        stoppedPlayers.add(id);
      }
    }

    for (final id in stoppedPlayers) {
      await _disposePlayer(id);
    }

    // Clean up temporary files
    await _cleanupTempFiles();
  }

  /// Internal methods

  Future<void> _stopAudio(String attachmentId) async {
    final playerInstance = _players[attachmentId];
    if (playerInstance != null) {
      await playerInstance.player.stop();
      _updateState(attachmentId, AudioPlaybackState.stopped);
    }

    if (_currentlyPlayingId == attachmentId) {
      _currentlyPlayingId = null;
    }
  }

  Future<AudioPlayerInstance> _createPlayerInstance(MessageAttachment attachment) async {
    final player = AudioPlayer();
    final attachmentId = attachment.id;

    // Set up state listeners
    final positionSubscription = player.onPositionChanged.listen((position) {
      final currentState = _states[attachmentId];
      if (currentState != null) {
        _updateState(attachmentId, currentState.state, position: position);
      }
    });

    final durationSubscription = player.onDurationChanged.listen((duration) {
      final currentState = _states[attachmentId];
      if (currentState != null) {
        _updateState(attachmentId, currentState.state, duration: duration);
      }
    });

    final stateSubscription = player.onPlayerStateChanged.listen((playerState) {
      AudioPlaybackState state;
      switch (playerState) {
        case PlayerState.playing:
          state = AudioPlaybackState.playing;
          break;
        case PlayerState.paused:
          state = AudioPlaybackState.paused;
          break;
        case PlayerState.stopped:
          state = AudioPlaybackState.stopped;
          if (_currentlyPlayingId == attachmentId) {
            _currentlyPlayingId = null;
          }
          break;
        case PlayerState.completed:
          state = AudioPlaybackState.stopped;
          if (_currentlyPlayingId == attachmentId) {
            _currentlyPlayingId = null;
          }
          break;
        default:
          state = AudioPlaybackState.stopped;
      }
      _updateState(attachmentId, state);
    });

    return AudioPlayerInstance(
      attachmentId: attachmentId,
      player: player,
      positionSubscription: positionSubscription,
      durationSubscription: durationSubscription,
      stateSubscription: stateSubscription,
    );
  }

  Future<Source> _getAudioSource(MessageAttachment attachment) async {
    // Try local file first
    if (attachment.localPath != null) {
      final file = File(attachment.localPath!);
      if (await file.exists()) {
        return DeviceFileSource(file.path);
      }
    }

    // Fallback to base64 data
    if (attachment.base64Data != null) {
      final tempFile = await _createTempFileFromBase64(attachment);
      return DeviceFileSource(tempFile.path);
    }

    throw AppError(
      message: 'No audio source available',
      type: ErrorType.notFound,
    );
  }

  Future<File> _createTempFileFromBase64(MessageAttachment attachment) async {
    final bytes = base64Decode(attachment.base64Data!);
    final tempDir = await getTemporaryDirectory();
    final extension = _getFileExtension(attachment.mimeType ?? 'audio/mpeg');
    final fileName = 'audio_${attachment.id}$extension';
    final tempFile = File('${tempDir.path}/$fileName');

    await tempFile.writeAsBytes(bytes);
    return tempFile;
  }

  String _getFileExtension(String mimeType) {
    switch (mimeType.toLowerCase()) {
      case 'audio/mpeg':
        return '.mp3';
      case 'audio/wav':
      case 'audio/x-wav':
        return '.wav';
      case 'audio/mp4':
        return '.m4a';
      case 'audio/aac':
        return '.aac';
      case 'audio/ogg':
        return '.ogg';
      default:
        return '.mp3';
    }
  }

  void _updateState(
    String attachmentId,
    AudioPlaybackState state, {
    Duration? position,
    Duration? duration,
    String? error,
  }) {
    final currentState = _states[attachmentId] ?? AudioState(
      attachmentId: attachmentId,
      state: AudioPlaybackState.stopped,
    );

    final newState = currentState.copyWith(
      state: state,
      position: position,
      duration: duration,
      error: error,
    );

    _states[attachmentId] = newState;
    _stateController.add(newState);
  }

  Future<void> _disposePlayer(String attachmentId) async {
    final instance = _players.remove(attachmentId);
    if (instance != null) {
      instance.dispose();
    }
    _states.remove(attachmentId);
  }

  Future<void> _cleanupTempFiles() async {
    try {
      final tempDir = await getTemporaryDirectory();
      final files = tempDir.listSync();

      for (final file in files) {
        if (file is File && file.path.contains('audio_')) {
          final stat = await file.stat();
          final age = DateTime.now().difference(stat.modified);

          // Delete audio files older than 1 hour
          if (age.inHours > 1) {
            await file.delete();
            _log.info('Cleaned up temp audio file: ${file.path}');
          }
        }
      }
    } catch (e) {
      _log.warning('Failed to clean up temp audio files: $e');
    }
  }

  /// Dispose all resources
  void dispose() {
    for (final instance in _players.values) {
      instance.dispose();
    }
    _players.clear();
    _states.clear();
    _stateController.close();
  }
}
