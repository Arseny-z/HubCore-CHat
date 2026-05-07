import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../../shared/utils/secure_file.dart';

// ── Режим кнопки ─────────────────────────────────────────────────────────────

enum _BtnMode { voice, video }

// ── Состояние записи ──────────────────────────────────────────────────────────

enum _RecState { idle, recording, cancelling }

// ── Основная кнопка (mic / camera) ───────────────────────────────────────────
//
// Поведение:
//   Tap            → переключить режим (mic ↔ camera)
//   Long press     → начать запись выбранного режима
//   Release        → отправить
//   Swipe right    → отмена

class VoiceRecordButton extends StatefulWidget {
  final Future<void> Function(File audioFile) onVoiceSend;
  final Future<void> Function(File videoFile)? onVideoSend;
  final bool disabled;

  const VoiceRecordButton({
    super.key,
    required this.onVoiceSend,
    this.onVideoSend,
    this.disabled = false,
  });

  @override
  State<VoiceRecordButton> createState() => _VoiceRecordButtonState();
}

class _VoiceRecordButtonState extends State<VoiceRecordButton>
    with SingleTickerProviderStateMixin {
  _BtnMode _mode = _BtnMode.voice;
  _RecState _recState = _RecState.idle;

  // Audio
  final _audioRec = AudioRecorder();
  int _seconds = 0;
  Timer? _timer;

  // Video
  CameraController? _camCtrl;
  bool _camReady = false;
  OverlayEntry? _camOverlay;

  // Gesture
  Offset _startPos = Offset.zero;
  bool _cancelled = false;
  Timer? _holdTimer; // задержка 300ms перед стартом записи

  // Animation
  late final AnimationController _pulseCtrl;
  late final Animation<double> _pulse;

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );
    _pulse = Tween<double>(begin: 1.0, end: 1.25).animate(
      CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _removeCamOverlay();
    _pulseCtrl.dispose();
    _timer?.cancel();
    _audioRec.dispose();
    _camCtrl?.dispose();
    super.dispose();
  }

  // ── Overlay с превью камеры ───────────────────────────────────────────────

  void _showCamOverlay() {
    if (_camOverlay != null) return;
    final overlay = Overlay.of(context);
    // Позиция кнопки на экране — размещаем кружок над ней
    final box = context.findRenderObject() as RenderBox?;
    final btnPos = box?.localToGlobal(Offset.zero) ?? Offset.zero;
    final screenW = MediaQuery.of(context).size.width;
    const size = 200.0;
    // Центрируем по горизонтали экрана, прижимаем снизу к кнопке
    final left = (screenW - size) / 2;
    final top = btnPos.dy - size - 16;

    _camOverlay = OverlayEntry(
      builder: (_) => Positioned(
        left: left,
        top: top,
        width: size,
        height: size,
        child: _CamPreviewCircle(
          ctrl: _camCtrl!,
          seconds: _seconds,
        ),
      ),
    );
    overlay.insert(_camOverlay!);
  }

  void _removeCamOverlay() {
    _camOverlay?.remove();
    _camOverlay = null;
  }

  void _updateOverlay() {
    _camOverlay?.markNeedsBuild();
  }

  // ── Инициализация камеры ──────────────────────────────────────────────────

  Future<void> _initCamera() async {
    if (_camReady) return;
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) return;
      final cam = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first,
      );
      // low = 352×288, достаточно для кружочка 160dp, файл ~3× меньше medium
      _camCtrl = CameraController(
        cam, ResolutionPreset.low, enableAudio: true,
      );
      await _camCtrl!.initialize();
      if (mounted) setState(() => _camReady = true);
    } catch (_) {}
  }

  // ── Запись ────────────────────────────────────────────────────────────────

  Future<void> _startRecording() async {
    _cancelled = false;
    if (_mode == _BtnMode.voice) {
      final ok = await _audioRec.hasPermission();
      if (!ok) return;
      final dir = await getTemporaryDirectory();
      // Opus/OGG: ~16 kbps — примерно в 4× меньше AAC-LC 64 kbps
      // На Linux Opus недоступен — fallback на AAC-LC 32 kbps
      final useOpus = !Platform.isLinux;
      final ext = useOpus ? 'ogg' : 'm4a';
      final path = '${dir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.$ext';
      await _audioRec.start(
        RecordConfig(
          encoder: useOpus ? AudioEncoder.opus : AudioEncoder.aacLc,
          bitRate: useOpus ? 16000 : 32000,
          sampleRate: 16000, // 16 kHz достаточно для речи
          numChannels: 1,    // моно
        ),
        path: path,
      );
    } else {
      await _initCamera();
      if (_camCtrl == null || !_camReady) return;
      await _camCtrl!.startVideoRecording();
    }
    HapticFeedback.mediumImpact();
    setState(() { _recState = _RecState.recording; _seconds = 0; });
    _pulseCtrl.repeat(reverse: true);
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() => _seconds++);
        _updateOverlay(); // обновить таймер в превью
      }
    });
    if (_mode == _BtnMode.video) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _showCamOverlay());
    }
  }

  Future<void> _stopAndSend() async {
    if (_recState == _RecState.idle) return;
    _timer?.cancel();
    _pulseCtrl.stop(); _pulseCtrl.reset();
    _removeCamOverlay();
    setState(() => _recState = _RecState.idle);

    if (_cancelled) return;

    if (_mode == _BtnMode.voice) {
      final path = await _audioRec.stop();
      if (path != null && _seconds >= 1) {
        await widget.onVoiceSend(File(path));
      } else if (path != null) {
        try { await File(path).delete(); } catch (_) {}
      }
    } else {
      if (_camCtrl == null) return;
      try {
        final xfile = await _camCtrl!.stopVideoRecording();
        if (_seconds >= 1 && widget.onVideoSend != null) {
          await widget.onVideoSend!(File(xfile.path));
        } else {
          try { await File(xfile.path).delete(); } catch (_) {}
        }
      } catch (_) {}
    }
  }

  Future<void> _cancel() async {
    if (_recState == _RecState.idle) return;
    _cancelled = true;
    _timer?.cancel();
    _pulseCtrl.stop(); _pulseCtrl.reset();
    _removeCamOverlay();
    HapticFeedback.lightImpact();

    if (_mode == _BtnMode.voice) {
      final path = await _audioRec.stop();
      setState(() => _recState = _RecState.idle);
      if (path != null) try { await File(path).delete(); } catch (_) {}
    } else {
      if (_camCtrl != null) {
        try {
          final xfile = await _camCtrl!.stopVideoRecording();
          await File(xfile.path).delete();
        } catch (_) {}
      }
      setState(() => _recState = _RecState.idle);
    }
  }

  // ── Жесты ─────────────────────────────────────────────────────────────────
  // Используем низкоуровневый Listener (PointerDown/Up/Move) чтобы:
  //   - onPointerDown  → запустить таймер 400ms → начать запись
  //   - onPointerMove  → во время записи: свайп вправо >60px → отмена
  //   - onPointerUp    → если запись шла → отправить
  //                      если таймер ещё не сработал → это короткий тап → сменить режим
  //
  // Это обходит ограничение GestureDetector который при onLongPress* отменяет
  // жест при движении > kTouchSlop, а onPanStart не срабатывает без движения.

  void _onPointerDown(PointerDownEvent e) {
    if (widget.disabled) return;
    _startPos = e.position;
    _holdTimer?.cancel();
    _holdTimer = Timer(const Duration(milliseconds: 400), () {
      if (mounted) _startRecording();
    });
  }

  void _onPointerMove(PointerMoveEvent e) {
    final delta = e.position - _startPos;
    // До начала записи: отменяем таймер при вертикальном смещении
    if (_recState == _RecState.idle && _holdTimer != null) {
      if (delta.dy.abs() > 12) {
        _holdTimer?.cancel();
        _holdTimer = null;
      }
      return;
    }
    // Во время записи: свайп вправо → отмена
    if (_recState == _RecState.recording && delta.dx > 60) {
      setState(() => _recState = _RecState.cancelling);
      _cancel();
    }
  }

  void _onPointerUp(PointerUpEvent e) {
    final wasHolding = _holdTimer?.isActive ?? false;
    _holdTimer?.cancel();
    _holdTimer = null;
    if (_recState == _RecState.recording) {
      _stopAndSend();
    } else if (wasHolding) {
      // Палец отпущен до истечения 400ms — это короткий тап → сменить режим
      _onTap();
    }
  }

  // ── Сборка ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_recState == _RecState.recording || _recState == _RecState.cancelling) {
      return _buildRecordingRow();
    }
    return _buildIdleButton();
  }

  Widget _buildIdleButton() {
    final color = widget.disabled ? Colors.white24 : const Color(0xFF2AABEE);
    final icon = _mode == _BtnMode.voice
        ? Icons.mic_rounded
        : Icons.radio_button_checked;

    return Listener(
      onPointerDown: widget.disabled ? null : _onPointerDown,
      onPointerMove: widget.disabled ? null : _onPointerMove,
      onPointerUp: widget.disabled ? null : _onPointerUp,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: 44, height: 44,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        child: Icon(icon, color: Colors.white, size: 22),
      ),
    );
  }

  void _onTap() {
    setState(() {
      _mode = _mode == _BtnMode.voice ? _BtnMode.video : _BtnMode.voice;
    });
    HapticFeedback.selectionClick();
    if (_mode == _BtnMode.video) _initCamera();
  }

  Widget _buildRecordingRow() {
    final isCancelling = _recState == _RecState.cancelling;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Подсказка отмены (свайп вправо)
        AnimatedOpacity(
          opacity: isCancelling ? 0.0 : 1.0,
          duration: const Duration(milliseconds: 200),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Text(
              isCancelling ? 'Отменено' : 'Свайп →',
              style: TextStyle(
                color: isCancelling ? Colors.red[300] : Colors.white38,
                fontSize: 12,
              ),
            ),
            const SizedBox(width: 6),
            Icon(Icons.chevron_right,
                color: isCancelling ? Colors.red[300] : Colors.white38,
                size: 16),
          ]),
        ),
        const SizedBox(width: 6),
        // Таймер
        _RecordingDot(),
        const SizedBox(width: 4),
        Text(
          _fmt(_seconds),
          style: const TextStyle(
              color: Colors.red, fontWeight: FontWeight.w600, fontSize: 13),
        ),
        const SizedBox(width: 8),
        // Пульсирующая кнопка (удерживать)
        Listener(
          onPointerMove: _onPointerMove,
          onPointerUp: _onPointerUp,
          child: AnimatedBuilder(
            animation: _pulse,
            builder: (_, child) =>
                Transform.scale(scale: _pulse.value, child: child),
            child: Container(
              width: 44, height: 44,
              decoration: BoxDecoration(
                color: _mode == _BtnMode.voice ? Colors.red : Colors.red[700],
                shape: BoxShape.circle,
              ),
              child: Icon(
                _mode == _BtnMode.voice
                    ? Icons.mic
                    : Icons.radio_button_checked,
                color: Colors.white, size: 22,
              ),
            ),
          ),
        ),
      ],
    );
  }

  static String _fmt(int s) =>
      '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';
}

// ── Пульсирующая красная точка ────────────────────────────────────────────────

class _RecordingDot extends StatefulWidget {
  @override
  State<_RecordingDot> createState() => _RecordingDotState();
}

class _RecordingDotState extends State<_RecordingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 600),
    )..repeat(reverse: true);
    _anim = Tween<double>(begin: 0.3, end: 1.0).animate(_ctrl);
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _anim,
      child: Container(
        width: 8, height: 8,
        decoration: const BoxDecoration(
            color: Colors.red, shape: BoxShape.circle),
      ),
    );
  }
}

// ── Круглый превью камеры во время записи кружочка ───────────────────────────

class _CamPreviewCircle extends StatelessWidget {
  final CameraController ctrl;
  final int seconds;

  const _CamPreviewCircle({required this.ctrl, required this.seconds});

  @override
  Widget build(BuildContext context) {
    if (!ctrl.value.isInitialized) return const SizedBox.shrink();

    final prev = ctrl.value.previewSize!;
    // previewSize в портретной ориентации возвращает width > height (landscape)
    final aspectRatio = prev.height / prev.width;

    return Material(
      color: Colors.transparent,
      child: ClipOval(
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Превью камеры
            FittedBox(
              fit: BoxFit.cover,
              child: SizedBox(
                width: prev.height,
                height: prev.width,
                child: CameraPreview(ctrl),
              ),
            ),
            // Затемнение по краям
            DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: Colors.red, width: 3),
              ),
            ),
            // Таймер внизу
            Positioned(
              bottom: 12,
              left: 0, right: 0,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '${(seconds ~/ 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
            // Красная точка REC сверху слева
            Positioned(
              top: 12, left: 12,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 8, height: 8,
                    decoration: const BoxDecoration(
                      color: Colors.red, shape: BoxShape.circle),
                  ),
                  const SizedBox(width: 4),
                  const Text('REC',
                    style: TextStyle(
                      color: Colors.white, fontSize: 10,
                      fontWeight: FontWeight.bold,
                      shadows: [Shadow(blurRadius: 2)],
                    )),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Voice message bubble player ───────────────────────────────────────────────

class VoiceMessagePlayer extends StatefulWidget {
  final int messageId;
  final dynamic fileSvc;
  final dynamic storage;
  final bool isMe;
  final VoidCallback? onPlay;

  const VoiceMessagePlayer({
    super.key,
    required this.messageId,
    required this.fileSvc,
    required this.storage,
    required this.isMe,
    this.onPlay,
  });

  @override
  State<VoiceMessagePlayer> createState() => _VoiceMessagePlayerState();
}

class _VoiceMessagePlayerState extends State<VoiceMessagePlayer>
    with SingleTickerProviderStateMixin {
  final _player = AudioPlayer();
  bool _loading = true;
  bool _playing = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  String? _error;
  File? _tmpFile;
  double _speed = 1.0;

  // Анимация столбиков
  late final AnimationController _waveCtrl;
  late final Animation<double> _waveAnim;

  static const _speeds = [1.0, 1.5, 2.0];

  @override
  void initState() {
    super.initState();
    _waveCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _waveAnim = Tween<double>(begin: 0, end: 1).animate(_waveCtrl);

    _load();
    _player.positionStream.listen((p) {
      if (mounted) setState(() => _position = p);
    });
    _player.durationStream.listen((d) {
      if (mounted && d != null) setState(() => _duration = d);
    });
    _player.playerStateStream.listen((s) {
      if (mounted) {
        setState(() => _playing = s.playing);
        if (s.playing) {
          _waveCtrl.repeat(reverse: true);
        } else {
          _waveCtrl.stop();
          _waveCtrl.reset();
        }
        if (s.processingState == ProcessingState.completed) {
          _player.seek(Duration.zero);
          _player.stop();
        }
      }
    });
  }

  @override
  void dispose() {
    _waveCtrl.dispose();
    _player.dispose();
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
      final mime = record.mimeType ?? '';
      final ext = mime.contains('ogg') ? 'ogg'
          : mime.contains('m4a') ? 'm4a'
          : 'aac';
      _tmpFile = File('${dir.path}/voice_${widget.messageId}.$ext');
      await _tmpFile!.writeAsBytes(bytes);
      await _player.setFilePath(_tmpFile!.path);
      if (mounted) setState(() => _loading = false);
    } catch (e) {
      if (mounted) setState(() { _loading = false; _error = e.toString(); });
    }
  }

  Future<void> _togglePlay() async {
    if (_playing) {
      await _player.pause();
    } else {
      widget.onPlay?.call();
      await _player.play();
    }
  }

  Future<void> _cycleSpeed() async {
    final idx = _speeds.indexOf(_speed);
    final next = _speeds[(idx + 1) % _speeds.length];
    setState(() => _speed = next);
    await _player.setSpeed(next);
    HapticFeedback.selectionClick();
  }

  @override
  Widget build(BuildContext context) {
    final activeColor = widget.isMe ? Colors.white : const Color(0xFF2AABEE);
    final trackColor = widget.isMe ? Colors.white24 : Colors.white12;

    if (_loading) {
      return SizedBox(
        width: 180, height: 44,
        child: Center(child: SizedBox(
          width: 20, height: 20,
          child: CircularProgressIndicator(strokeWidth: 2, color: activeColor),
        )),
      );
    }

    if (_error != null) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.error_outline, color: Colors.red[300], size: 20),
          const SizedBox(width: 6),
          const Text('Не удалось загрузить',
              style: TextStyle(color: Colors.white54, fontSize: 12)),
        ],
      );
    }

    final total = _duration.inMilliseconds > 0 ? _duration.inMilliseconds : 1;
    final progress = _position.inMilliseconds / total;

    return SizedBox(
      width: 220,
      child: Row(
        children: [
          // Play/pause
          GestureDetector(
            onTap: _togglePlay,
            child: Container(
              width: 36, height: 36,
              decoration: BoxDecoration(
                color: activeColor.withOpacity(0.15),
                shape: BoxShape.circle,
              ),
              child: Icon(
                _playing ? Icons.pause : Icons.play_arrow,
                color: activeColor, size: 22,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // Анимированные столбики
                SizedBox(
                  height: 28,
                  child: AnimatedBuilder(
                    animation: _waveAnim,
                    builder: (_, __) => CustomPaint(
                      painter: _WaveformPainter(
                        progress: progress.clamp(0.0, 1.0),
                        animValue: _waveAnim.value,
                        playing: _playing,
                        activeColor: activeColor,
                        inactiveColor: trackColor,
                      ),
                      size: const Size(double.infinity, 28),
                    ),
                  ),
                ),
                const SizedBox(height: 2),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      _formatDuration(_playing
                          ? _position.inSeconds
                          : _duration.inSeconds),
                      style: TextStyle(
                          color: activeColor.withValues(alpha: 0.7),
                          fontSize: 11),
                    ),
                    // Кнопка скорости
                    GestureDetector(
                      onTap: _cycleSpeed,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 5, vertical: 2),
                        decoration: BoxDecoration(
                          color: activeColor.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          _speed == 1.0 ? '1×' : '${_speed}×',
                          style: TextStyle(
                              color: activeColor,
                              fontSize: 10,
                              fontWeight: FontWeight.w700),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _formatDuration(int seconds) {
    final m = seconds ~/ 60;
    final s = seconds % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }
}

// ── Waveform painter ──────────────────────────────────────────────────────────
//
// Рисует 24 столбика. Высоты — псевдослучайные но стабильные (seeded по index).
// Во время воспроизведения столбики анимируются (пульсируют) через animValue.
// Прогресс разделяет активную (прослушанную) и неактивную части.

class _WaveformPainter extends CustomPainter {
  final double progress;   // 0.0–1.0
  final double animValue;  // 0.0–1.0 (анимация)
  final bool playing;
  final Color activeColor;
  final Color inactiveColor;

  // Псевдослучайные высоты столбиков (фиксированные)
  static const _heights = [
    0.4, 0.7, 0.5, 0.9, 0.6, 0.8, 0.3, 0.7, 0.5, 0.9,
    0.6, 0.4, 0.8, 0.5, 0.7, 0.9, 0.4, 0.6, 0.8, 0.5,
    0.7, 0.3, 0.6, 0.8,
  ];

  const _WaveformPainter({
    required this.progress,
    required this.animValue,
    required this.playing,
    required this.activeColor,
    required this.inactiveColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    const bars = 24;
    const gap = 2.0;
    final barW = (size.width - gap * (bars - 1)) / bars;

    for (int i = 0; i < bars; i++) {
      final frac = i / bars;
      final isPast = frac < progress;

      // Анимация: только у активных столбиков рядом с позицией воспроизведения
      double h = _heights[i];
      if (playing && isPast && (progress - frac) < 0.2) {
        // Столбики у края прогресса пульсируют
        final phase = (animValue + i * 0.15) % 1.0;
        h = h * (0.6 + 0.4 * (0.5 + 0.5 * math.sin(phase * math.pi * 2)));
      }

      final barH = h * size.height;
      final x = i * (barW + gap);
      final y = (size.height - barH) / 2;

      final paint = Paint()
        ..color = isPast ? activeColor : inactiveColor
        ..style = PaintingStyle.fill;

      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, y, barW, barH),
          const Radius.circular(2),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_WaveformPainter old) =>
      old.progress != progress ||
      old.animValue != animValue ||
      old.playing != playing;
}
