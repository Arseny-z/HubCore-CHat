import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_compress/video_compress.dart';
import 'package:video_player/video_player.dart';

import '../../shared/utils/secure_file.dart';

// ── Video circle recorder ─────────────────────────────────────────────────────

const _kMaxDurationSec = 60;

class VideoCircleRecorder extends StatefulWidget {
  final Future<void> Function(File videoFile) onSend;
  final VoidCallback onClose;

  const VideoCircleRecorder({
    super.key,
    required this.onSend,
    required this.onClose,
  });

  @override
  State<VideoCircleRecorder> createState() => _VideoCircleRecorderState();
}

class _VideoCircleRecorderState extends State<VideoCircleRecorder>
    with SingleTickerProviderStateMixin {
  CameraController? _ctrl;
  bool _recording = false;
  bool _initialized = false;
  bool _compressing = false;
  String? _error;
  int _seconds = 0;
  Timer? _timer;

  late final AnimationController _progressCtrl;

  @override
  void initState() {
    super.initState();
    _progressCtrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: _kMaxDurationSec),
    );
    _init();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _progressCtrl.dispose();
    _ctrl?.dispose();
    VideoCompress.cancelCompression();
    super.dispose();
  }

  Future<void> _init() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        setState(() => _error = 'Камера недоступна');
        return;
      }
      // Prefer front camera for circles
      final cam = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first,
      );
      _ctrl = CameraController(
        cam,
        ResolutionPreset.low,
        enableAudio: true,
      );
      await _ctrl!.initialize();
      if (mounted) setState(() => _initialized = true);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _startRecording() async {
    if (_ctrl == null || !_initialized) return;
    await _ctrl!.startVideoRecording();
    setState(() { _recording = true; _seconds = 0; });
    _progressCtrl.forward(from: 0);
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) { t.cancel(); return; }
      setState(() => _seconds++);
      if (_seconds >= _kMaxDurationSec) {
        t.cancel();
        _stopAndSend();
      }
    });
  }

  Future<void> _stopAndSend() async {
    if (!_recording || _ctrl == null) return;
    _timer?.cancel();
    _progressCtrl.stop();
    setState(() => _recording = false);

    try {
      final xfile = await _ctrl!.stopVideoRecording();
      final raw = File(xfile.path);
      setState(() => _compressing = true);

      File fileToSend = raw;
      try {
        final result = await VideoCompress.compressVideo(
          raw.path,
          quality: VideoQuality.LowQuality,
          includeAudio: true,
          deleteOrigin: false,
        );
        if (result?.file != null) fileToSend = result!.file!;
      } catch (_) {
        // compression failed — send original
      } finally {
        if (mounted) setState(() => _compressing = false);
      }

      await widget.onSend(fileToSend);
      if (fileToSend.path != raw.path) raw.deleteSync();
    } catch (_) {
      if (mounted) setState(() => _compressing = false);
    }
    widget.onClose();
  }

  Future<void> _cancel() async {
    if (_recording && _ctrl != null) {
      _timer?.cancel();
      _progressCtrl.stop();
      try {
        final xfile = await _ctrl!.stopVideoRecording();
        await File(xfile.path).delete();
      } catch (_) {}
    }
    widget.onClose();
  }

  Widget _buildCameraPreview() {
    final ctrl = _ctrl!;
    final previewSize = ctrl.value.previewSize;
    if (previewSize == null) return CameraPreview(ctrl);
    // Camera preview size is in landscape orientation internally
    // For portrait display: width = short side, height = long side
    final w = previewSize.width < previewSize.height
        ? previewSize.width
        : previewSize.height;
    final h = previewSize.width < previewSize.height
        ? previewSize.height
        : previewSize.width;
    return FittedBox(
      fit: BoxFit.cover,
      clipBehavior: Clip.hardEdge,
      child: SizedBox(
        width: w,
        height: h,
        child: CameraPreview(ctrl),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Circle camera preview
          Stack(
            alignment: Alignment.center,
            children: [
              // Progress ring
              SizedBox(
                width: 260, height: 260,
                child: AnimatedBuilder(
                  animation: _progressCtrl,
                  builder: (_, __) => CircularProgressIndicator(
                    value: _recording ? _progressCtrl.value : 0,
                    strokeWidth: 4,
                    backgroundColor: Colors.white24,
                    valueColor: const AlwaysStoppedAnimation(Color(0xFF2AABEE)),
                  ),
                ),
              ),
              // Circle clip camera
              ClipOval(
                child: SizedBox(
                  width: 240, height: 240,
                  child: _error != null
                      ? Container(
                          color: Colors.black54,
                          child: Center(
                            child: Text(_error!,
                                style: const TextStyle(color: Colors.white54),
                                textAlign: TextAlign.center),
                          ),
                        )
                      : !_initialized
                          ? Container(
                              color: Colors.black87,
                              child: const Center(
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.white38),
                              ),
                            )
                          : _buildCameraPreview(),
                ),
              ),
              // Timer overlay
              if (_recording)
                Positioned(
                  bottom: 16,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      _formatDuration(_seconds),
                      style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                          fontSize: 14),
                    ),
                  ),
                ),
              // Compression overlay
              if (_compressing)
                Container(
                  width: 240, height: 240,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.black54,
                  ),
                  child: const Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 28, height: 28,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        ),
                        SizedBox(height: 10),
                        Text('Сжатие…',
                            style: TextStyle(color: Colors.white70, fontSize: 13)),
                      ],
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 20),
          // Controls
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              // Cancel
              IconButton(
                onPressed: _cancel,
                icon: const Icon(Icons.close, color: Colors.white70, size: 32),
              ),
              // Record / Stop
              if (!_recording)
                GestureDetector(
                  onTap: _initialized ? _startRecording : null,
                  child: Container(
                    width: 64, height: 64,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _initialized ? Colors.red : Colors.grey,
                      border: Border.all(color: Colors.white, width: 3),
                    ),
                  ),
                )
              else
                GestureDetector(
                  onTap: _stopAndSend,
                  child: Container(
                    width: 64, height: 64,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.red.shade700,
                      border: Border.all(color: Colors.white, width: 3),
                    ),
                    child: const Icon(Icons.stop, color: Colors.white, size: 32),
                  ),
                ),
              // Flip camera placeholder
              IconButton(
                onPressed: _initialized ? _flipCamera : null,
                icon: Icon(Icons.flip_camera_ios,
                    color: _initialized ? Colors.white70 : Colors.white24,
                    size: 32),
              ),
            ],
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Future<void> _flipCamera() async {
    if (_ctrl == null || _recording) return;
    final cameras = await availableCameras();
    if (cameras.length < 2) return;
    final current = _ctrl!.description.lensDirection;
    final next = cameras.firstWhere(
      (c) => c.lensDirection != current,
      orElse: () => cameras.first,
    );
    await _ctrl!.dispose();
    _ctrl = CameraController(next, ResolutionPreset.low, enableAudio: true);
    await _ctrl!.initialize();
    if (mounted) setState(() {});
  }

  static String _formatDuration(int seconds) {
    final m = seconds ~/ 60;
    final s = seconds % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }
}

// ── Video circle player ───────────────────────────────────────────────────────

class VideoCirclePlayer extends StatefulWidget {
  final int messageId;
  final dynamic fileSvc;
  final dynamic storage;
  final VoidCallback? onPlay;

  const VideoCirclePlayer({
    super.key,
    required this.messageId,
    required this.fileSvc,
    required this.storage,
    this.onPlay,
  });

  @override
  State<VideoCirclePlayer> createState() => _VideoCirclePlayerState();
}

class _VideoCirclePlayerState extends State<VideoCirclePlayer> {
  VideoPlayerController? _ctrl;
  bool _loading = true;
  bool _playing = false;
  String? _error;
  File? _tmpFile;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _ctrl?.dispose();
    if (_tmpFile != null) secureDeleteFile(_tmpFile!);
    super.dispose();
  }

  Future<void> _load() async {
    if (widget.fileSvc == null || widget.storage == null) {
      setState(() { _loading = false; _error = 'unavailable'; });
      return;
    }
    try {
      final record = await widget.storage.files.forMessage(widget.messageId);
      if (record == null) throw Exception('no file record');
      final Uint8List bytes = await widget.fileSvc.decryptFile(record);
      final dir = await getTemporaryDirectory();
      _tmpFile = File('${dir.path}/circle_${widget.messageId}.mp4');
      await _tmpFile!.writeAsBytes(bytes);
      _ctrl = VideoPlayerController.file(_tmpFile!);
      await _ctrl!.initialize();
      _ctrl!.setLooping(false);
      _ctrl!.addListener(_onVideoUpdate);
      if (mounted) setState(() => _loading = false);
    } catch (e) {
      if (mounted) setState(() { _loading = false; _error = e.toString(); });
    }
  }

  void _onVideoUpdate() {
    if (!mounted) return;
    final playing = _ctrl?.value.isPlaying ?? false;
    if (playing != _playing) setState(() => _playing = playing);
    // Auto-reset at end
    final pos = _ctrl?.value.position;
    final dur = _ctrl?.value.duration;
    if (pos != null && dur != null && dur.inMilliseconds > 0 &&
        pos.inMilliseconds >= dur.inMilliseconds - 100) {
      _ctrl?.pause();
      _ctrl?.seekTo(Duration.zero);
    }
  }

  Future<void> _togglePlay() async {
    if (_ctrl == null) return;
    if (_playing) {
      await _ctrl!.pause();
    } else {
      widget.onPlay?.call();
      await _ctrl!.play();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const SizedBox(
        width: 160, height: 160,
        child: Center(child: SizedBox(
          width: 24, height: 24,
          child: CircularProgressIndicator(strokeWidth: 2),
        )),
      );
    }

    if (_error != null) {
      return Container(
        width: 160, height: 160,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.black38,
        ),
        child: const Center(
          child: Icon(Icons.videocam_off, color: Colors.white38, size: 40),
        ),
      );
    }

    return GestureDetector(
      onTap: _togglePlay,
      child: SizedBox(
        width: 168, height: 168,
        child: Stack(
          alignment: Alignment.center,
          children: [
            // Progress ring
            ValueListenableBuilder<VideoPlayerValue>(
              valueListenable: _ctrl!,
              builder: (_, v, __) {
                final dur = v.duration.inMilliseconds;
                final pos = v.position.inMilliseconds;
                final progress = dur > 0 ? (pos / dur).clamp(0.0, 1.0) : 0.0;
                return SizedBox(
                  width: 168, height: 168,
                  child: CircularProgressIndicator(
                    value: progress,
                    strokeWidth: 4,
                    backgroundColor: Colors.white24,
                    valueColor: const AlwaysStoppedAnimation(Color(0xFF2AABEE)),
                  ),
                );
              },
            ),
            ClipOval(
              child: SizedBox(
                width: 156, height: 156,
                child: _ctrl != null && _ctrl!.value.isInitialized
                    ? FittedBox(
                        fit: BoxFit.cover,
                        clipBehavior: Clip.hardEdge,
                        child: SizedBox(
                          width: _ctrl!.value.size.width,
                          height: _ctrl!.value.size.height,
                          child: VideoPlayer(_ctrl!),
                        ),
                      )
                    : Container(color: Colors.black54),
              ),
            ),
            if (!_playing)
              Container(
                width: 48, height: 48,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.black.withOpacity(0.5),
                ),
                child: const Icon(Icons.play_arrow,
                    color: Colors.white, size: 30),
              ),
            // Duration indicator
            Positioned(
              bottom: 12,
              child: ValueListenableBuilder<VideoPlayerValue>(
                valueListenable: _ctrl!,
                builder: (_, v, __) {
                  final remaining = v.duration - v.position;
                  return Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      _fmt(remaining),
                      style: const TextStyle(
                          color: Colors.white, fontSize: 11),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _fmt(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }
}
