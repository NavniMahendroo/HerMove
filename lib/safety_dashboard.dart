import 'dart:async';

import 'package:flutter/material.dart';

import 'services/hardware_bridge.dart';

class SafetyDashboard extends StatefulWidget {
  const SafetyDashboard({
    super.key,
    required this.onEmergencyApiCall,
    this.safeLabel = 'Safe',
    this.emergencyLabel = 'SOS Active',
  });

  final Future<void> Function(Map<String, dynamic> payload) onEmergencyApiCall;
  final String safeLabel;
  final String emergencyLabel;

  @override
  State<SafetyDashboard> createState() => _SafetyDashboardState();
}

class _SafetyDashboardState extends State<SafetyDashboard>
    with TickerProviderStateMixin {
  StreamSubscription<Map<String, dynamic>>? _alertSubscription;
  bool _isMonitoring = false;
  bool _showSos = false;
  bool _isCountdownVisible = false;
  int _countdown = 10;
  String _statusLabel = 'Safe';
  Map<String, dynamic>? _lastTriggerPayload;
  final TextEditingController _pinController = TextEditingController();

  late final AnimationController _pulseController;
  late final Animation<double> _pulseAnimation;
  late final AnimationController _breathingController;
  late final Animation<double> _breathingAnimation;

  static const String _cancelPin = '4321';

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 950),
    )..repeat(reverse: true);

    _pulseAnimation = CurvedAnimation(
      parent: _pulseController,
      curve: Curves.easeInOut,
    );

    _breathingController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat(reverse: true);

    _breathingAnimation = CurvedAnimation(
      parent: _breathingController,
      curve: Curves.easeInOut,
    );

    _bindHardwareBridge();
  }

  @override
  void dispose() {
    _alertSubscription?.cancel();
    _pinController.dispose();
    _pulseController.dispose();
    _breathingController.dispose();
    super.dispose();
  }

  Future<void> _bindHardwareBridge() async {
    await HardwareBridge.instance.initialize();
    _alertSubscription = HardwareBridge.instance.alerts.listen(
      _handleHardwareAlert,
    );
    if (!mounted) {
      return;
    }
    setState(() {
      _isMonitoring = true;
    });
  }

  void _handleHardwareAlert(Map<String, dynamic> payload) {
    final eventType = payload['event']?.toString();
    if (eventType == 'bluetooth_acl_disconnected' ||
        eventType == 'high_g_burst') {
      _triggerSos(payload: payload, fromHardware: true);
    }
  }

  Future<void> _triggerSos({
    Map<String, dynamic>? payload,
    bool fromHardware = false,
  }) async {
    if (!mounted) {
      return;
    }

    setState(() {
      _showSos = true;
      _isCountdownVisible = true;
      _countdown = 10;
      _lastTriggerPayload = payload ?? <String, dynamic>{
        'event': 'manual_sos',
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      };
      _statusLabel = widget.emergencyLabel;
    });

    unawaited(widget.onEmergencyApiCall(_lastTriggerPayload!));

    if (fromHardware) {
      await _showEmergencyCountdownDialog(isHardwareTrigger: true);
      return;
    }

    await _showEmergencyCountdownDialog(isHardwareTrigger: false);
  }

  Future<void> _showEmergencyCountdownDialog({
    required bool isHardwareTrigger,
  }) async {
    if (!mounted) {
      return;
    }

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return _FakeCancelDialog(
          countdown: _countdown,
          onCancelWithPin: (pin) async {
            if (pin == _cancelPin) {
              Navigator.of(context).pop();
              if (mounted) {
                setState(() {
                  _showSos = false;
                  _isCountdownVisible = false;
                  _statusLabel = widget.safeLabel;
                });
              }
              unawaited(widget.onEmergencyApiCall(<String, dynamic>{
                ...(_lastTriggerPayload ?? <String, dynamic>{}),
                'event': 'duress_pin_cancel',
                'timestamp': DateTime.now().millisecondsSinceEpoch,
                'cancel_pin_used': true,
              }));
            }
          },
          onCountdownExpired: () {
            unawaited(widget.onEmergencyApiCall(<String, dynamic>{
              ...(_lastTriggerPayload ?? <String, dynamic>{}),
              'event': 'countdown_expired_sos',
              'timestamp': DateTime.now().millisecondsSinceEpoch,
            }));
          },
        );
      },
    );

    if (!mounted) {
      return;
    }

    setState(() {
      _isCountdownVisible = false;
    });
  }
  Future<void> _handleSlideSuccess() async {
    await _triggerSos(
      payload: <String, dynamic>{
        'event': 'manual_sos',
        'trigger_type': 'slide_to_sos',
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      },
      fromHardware: false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: const Color(0xFF06131F),
      body: SafeArea(
        child: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Color(0xFF06131F),
                Color(0xFF081D2A),
                Color(0xFF0B2A33),
              ],
            ),
          ),
          child: Stack(
            children: [
              Positioned.fill(
                child: IgnorePointer(
                  child: AnimatedBuilder(
                    animation: _breathingAnimation,
                    builder: (context, child) {
                      final scale = 1.0 + (_breathingAnimation.value * 0.04);
                      return Transform.scale(scale: scale, child: child);
                    },
                    child: Opacity(
                      opacity: 0.18,
                      child: Container(
                        decoration: BoxDecoration(
                          gradient: RadialGradient(
                            center: const Alignment(-0.4, -0.8),
                            radius: 1.2,
                            colors: [
                              const Color(0xFF15D2C3).withOpacity(0.25),
                              Colors.transparent,
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _DashboardHeader(
                      statusLabel: _statusLabel,
                      isArmed: _isMonitoring,
                      pulseAnimation: _pulseAnimation,
                    ),
                    const SizedBox(height: 24),
                    Text(
                      'Late-night commute mode',
                      style: theme.textTheme.headlineMedium?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.4,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Keep the gesture deliberate. A full swipe arms an emergency response without accidental taps.',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: Colors.white.withOpacity(0.72),
                        height: 1.45,
                      ),
                    ),
                    const SizedBox(height: 24),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          AnimatedBuilder(
                            animation: _pulseAnimation,
                            builder: (context, child) {
                              return Container(
                                padding: const EdgeInsets.all(22),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF0D2334).withOpacity(0.88),
                                  borderRadius: BorderRadius.circular(28),
                                  border: Border.all(
                                    color: _showSos
                                        ? const Color(0xFFFF5E5E).withOpacity(0.75)
                                        : const Color(0xFF21D4C2).withOpacity(0.2),
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: (_showSos
                                              ? const Color(0xFFFF5E5E)
                                              : const Color(0xFF21D4C2))
                                          .withOpacity(0.16 + (_pulseAnimation.value * 0.08)),
                                      blurRadius: 28,
                                      spreadRadius: 1,
                                    ),
                                  ],
                                ),
                                child: child,
                              );
                            },
                            child: Column(
                              children: [
                                Text(
                                  _showSos ? 'SOS Triggered' : 'Emergency Access',
                                  style: theme.textTheme.titleLarge?.copyWith(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  _showSos
                                      ? 'Countdown is active. Cancel requires a PIN.'
                                      : 'Swipe fully to the right to trigger SOS.',
                                  textAlign: TextAlign.center,
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    color: Colors.white.withOpacity(0.74),
                                  ),
                                ),
                                const SizedBox(height: 20),
                                SlideToSosButton(
                                  enabled: !_showSos,
                                  onCompleted: _handleSlideSuccess,
                                ),
                                const SizedBox(height: 18),
                                Row(
                                  children: [
                                    _StatusPill(
                                      label: _isMonitoring ? 'Bridge Connected' : 'Bridge Offline',
                                      icon: Icons.sensors,
                                      active: _isMonitoring,
                                    ),
                                    const SizedBox(width: 12),
                                    _StatusPill(
                                      label: _isCountdownVisible ? 'Countdown Live' : 'Standby',
                                      icon: Icons.timer_outlined,
                                      active: _isCountdownVisible,
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 24),
                          _AmbientTriggerPanel(
                            lastPayload: _lastTriggerPayload,
                            onSimulateHardwareTrigger: () {
                              _handleHardwareAlert(<String, dynamic>{
                                'event': 'high_g_burst',
                                'trigger_type': 'simulated_high_g_burst',
                                'timestamp': DateTime.now().millisecondsSinceEpoch,
                              });
                            },
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class SlideToSosButton extends StatefulWidget {
  const SlideToSosButton({
    super.key,
    required this.onCompleted,
    this.enabled = true,
  });

  final Future<void> Function() onCompleted;
  final bool enabled;

  @override
  State<SlideToSosButton> createState() => _SlideToSosButtonState();
}

class _SlideToSosButtonState extends State<SlideToSosButton>
    with SingleTickerProviderStateMixin {
  double _dragPosition = 0;
  late final AnimationController _completionController;
  late final Animation<double> _completionAnimation;

  @override
  void initState() {
    super.initState();
    _completionController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 240),
    );
    _completionAnimation = CurvedAnimation(
      parent: _completionController,
      curve: Curves.easeOut,
    );
  }

  @override
  void dispose() {
    _completionController.dispose();
    super.dispose();
  }

  Future<void> _finishSlide() async {
    await _completionController.forward(from: 0);
    await widget.onCompleted();
    if (!mounted) {
      return;
    }
    setState(() {
      _dragPosition = 0;
    });
    await _completionController.reverse();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const thumbSize = 58.0;
        final maxDrag = (constraints.maxWidth - thumbSize - 10).clamp(0.0, double.infinity);

        return GestureDetector(
          onHorizontalDragUpdate: widget.enabled
              ? (details) {
                  setState(() {
                    _dragPosition = (_dragPosition + details.delta.dx).clamp(0.0, maxDrag);
                  });
                }
              : null,
          onHorizontalDragEnd: widget.enabled
              ? (details) async {
                  if (_dragPosition >= maxDrag * 0.96) {
                    await _finishSlide();
                  } else {
                    setState(() {
                      _dragPosition = 0;
                    });
                  }
                }
              : null,
          child: Container(
            height: 72,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(36),
              gradient: LinearGradient(
                colors: widget.enabled
                    ? [const Color(0xFF133B56), const Color(0xFF0F6C73)]
                    : [const Color(0xFF112233), const Color(0xFF16293A)],
              ),
              border: Border.all(color: Colors.white.withOpacity(0.08)),
            ),
            child: Stack(
              children: [
                Positioned.fill(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(36),
                    child: AnimatedBuilder(
                      animation: _completionAnimation,
                      builder: (context, child) {
                        return Opacity(
                          opacity: 0.18 + (_completionAnimation.value * 0.2),
                          child: child,
                        );
                      },
                      child: Container(
                        decoration: const BoxDecoration(
                          gradient: LinearGradient(
                            colors: [Color(0xFF21D4C2), Color(0xFF1B8CFF)],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned.fill(
                  child: Center(
                    child: Text(
                      widget.enabled ? 'Slide to trigger SOS' : 'SOS already active',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            color: Colors.white.withOpacity(0.85),
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0.2,
                          ),
                    ),
                  ),
                ),
                Positioned(
                  left: _dragPosition + 5,
                  top: 7,
                  child: AnimatedBuilder(
                    animation: _completionAnimation,
                    builder: (context, child) {
                      final scale = 1.0 + (_completionAnimation.value * 0.05);
                      return Transform.scale(scale: scale, child: child);
                    },
                    child: Container(
                      width: thumbSize,
                      height: thumbSize,
                      decoration: BoxDecoration(
                        color: widget.enabled
                            ? const Color(0xFFF8FBFF)
                            : const Color(0xFF90A8BA),
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.24),
                            blurRadius: 14,
                            offset: const Offset(0, 8),
                          ),
                        ],
                      ),
                      child: Icon(
                        Icons.chevron_right,
                        size: 34,
                        color: widget.enabled
                            ? const Color(0xFF0A3448)
                            : const Color(0xFF20384A),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _FakeCancelDialog extends StatefulWidget {
  const _FakeCancelDialog({
    required this.countdown,
    required this.onCancelWithPin,
    required this.onCountdownExpired,
  });

  final int countdown;
  final Future<void> Function(String pin) onCancelWithPin;
  final VoidCallback onCountdownExpired;

  @override
  State<_FakeCancelDialog> createState() => _FakeCancelDialogState();
}

class _FakeCancelDialogState extends State<_FakeCancelDialog> {
  late int _remaining;
  late Timer _timer;
  final TextEditingController _pinController = TextEditingController();
  bool _isSubmitting = false;
  bool _forceSafeVisual = false;
  bool _expiredFired = false;

  @override
  void initState() {
    super.initState();
    _remaining = widget.countdown;
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_remaining <= 1) {
        timer.cancel();
        setState(() {
          _remaining = 0;
        });
        if (!_expiredFired) {
          _expiredFired = true;
          widget.onCountdownExpired();
        }
      } else {
        setState(() {
          _remaining -= 1;
        });
      }
    });
  }

  @override
  void dispose() {
    _timer.cancel();
    _pinController.dispose();
    super.dispose();
  }

  Future<void> _submitPin() async {
    if (_isSubmitting) {
      return;
    }

    setState(() {
      _isSubmitting = true;
    });

    await widget.onCancelWithPin(_pinController.text.trim());

    if (!mounted) {
      return;
    }

    if (_pinController.text.trim() == '4321') {
      setState(() {
        _forceSafeVisual = true;
      });
    } else {
      setState(() {
        _isSubmitting = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final accent = _forceSafeVisual ? const Color(0xFF21D4C2) : const Color(0xFFFF5E5E);
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 20),
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(28),
          gradient: LinearGradient(
            colors: _forceSafeVisual
                ? [const Color(0xFF082D2A), const Color(0xFF0A433C)]
                : [const Color(0xFF2A0C18), const Color(0xFF140912)],
          ),
          border: Border.all(color: accent.withOpacity(0.35)),
          boxShadow: [
            BoxShadow(
              color: accent.withOpacity(0.22),
              blurRadius: 30,
              spreadRadius: 2,
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _forceSafeVisual ? Icons.check_circle_outline : Icons.warning_rounded,
              size: 64,
              color: accent,
            ),
            const SizedBox(height: 14),
            Text(
              _forceSafeVisual ? 'State restored to Safe' : 'Emergency countdown active',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
            ),
            const SizedBox(height: 8),
            Text(
              _forceSafeVisual
                  ? 'The app is visually safe now.'
                  : 'Enter PIN to cancel. Response dispatch continues in the background.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Colors.white.withOpacity(0.76),
                    height: 1.4,
                  ),
            ),
            const SizedBox(height: 18),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              child: _forceSafeVisual
                  ? Container(
                      key: const ValueKey('safe-pill'),
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      decoration: BoxDecoration(
                        color: const Color(0xFF21D4C2).withOpacity(0.16),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: const Text(
                        'Safe',
                        style: TextStyle(
                          color: Color(0xFFBFFAF3),
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    )
                  : Container(
                      key: const ValueKey('countdown-pill'),
                      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFF5E5E).withOpacity(0.12),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        '$_remaining seconds',
                        style: const TextStyle(
                          color: Color(0xFFFFD5D5),
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
            ),
            const SizedBox(height: 18),
            if (!_forceSafeVisual) ...[
              TextField(
                controller: _pinController,
                obscureText: true,
                keyboardType: TextInputType.number,
                maxLength: 6,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  counterText: '',
                  hintText: 'Enter cancel PIN',
                  hintStyle: TextStyle(color: Colors.white.withOpacity(0.5)),
                  filled: true,
                  fillColor: Colors.white.withOpacity(0.06),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide: BorderSide(color: Colors.white.withOpacity(0.08)),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide: BorderSide(color: Colors.white.withOpacity(0.08)),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide: const BorderSide(color: Color(0xFF21D4C2)),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _isSubmitting ? null : _submitPin,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF21D4C2),
                    foregroundColor: const Color(0xFF03121C),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  child: Text(_isSubmitting ? 'Verifying...' : 'Cancel Emergency'),
                ),
              ),
            ] else ...[
              const SizedBox(height: 8),
              const SizedBox(
                width: double.infinity,
                child: _SafeStateBadge(),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SafeStateBadge extends StatelessWidget {
  const _SafeStateBadge();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        'Visual state restored. Dispatch continues quietly.',
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: const Color(0xFFBFFAF3),
              fontWeight: FontWeight.w600,
            ),
      ),
    );
  }
}

class _DashboardHeader extends StatelessWidget {
  const _DashboardHeader({
    required this.statusLabel,
    required this.isArmed,
    required this.pulseAnimation,
  });

  final String statusLabel;
  final bool isArmed;
  final Animation<double> pulseAnimation;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: const LinearGradient(
              colors: [Color(0xFF21D4C2), Color(0xFF1B8CFF)],
            ),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF21D4C2).withOpacity(0.25),
                blurRadius: 22,
                spreadRadius: 2,
              ),
            ],
          ),
          child: const Icon(Icons.shield_moon_outlined, color: Colors.white),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'HERMOVE',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.0,
                    ),
              ),
              const SizedBox(height: 4),
              Text(
                statusLabel,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: isArmed
                          ? const Color(0xFF21D4C2)
                          : Colors.white.withOpacity(0.7),
                      fontWeight: FontWeight.w600,
                    ),
              ),
            ],
          ),
        ),
        ScaleTransition(
          scale: pulseAnimation,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: isArmed
                  ? const Color(0xFF21D4C2).withOpacity(0.16)
                  : Colors.white.withOpacity(0.08),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              isArmed ? 'Monitored' : 'Idle',
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
            ),
          ),
        ),
      ],
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({
    required this.label,
    required this.icon,
    required this.active,
  });

  final String label;
  final IconData icon;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final foreground = active ? const Color(0xFFBFFAF3) : Colors.white.withOpacity(0.75);
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        decoration: BoxDecoration(
          color: active ? const Color(0xFF163A45) : Colors.white.withOpacity(0.05),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: active ? const Color(0xFF21D4C2).withOpacity(0.32) : Colors.white.withOpacity(0.08)),
        ),
        child: Row(
          children: [
            Icon(icon, size: 18, color: foreground),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: foreground,
                      fontWeight: FontWeight.w600,
                    ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AmbientTriggerPanel extends StatelessWidget {
  const _AmbientTriggerPanel({
    required this.lastPayload,
    required this.onSimulateHardwareTrigger,
  });

  final Map<String, dynamic>? lastPayload;
  final VoidCallback onSimulateHardwareTrigger;

  @override
  Widget build(BuildContext context) {
    final event = lastPayload?['event']?.toString() ?? 'No trigger yet';
    final triggerType = lastPayload?['trigger_type']?.toString() ?? 'standby';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.05),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white.withOpacity(0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.radar, color: Color(0xFF21D4C2)),
              const SizedBox(width: 10),
              Text(
                'Ambient trigger state',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                    ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            'Last event: $event',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Colors.white.withOpacity(0.78),
                ),
          ),
          const SizedBox(height: 4),
          Text(
            'Trigger type: $triggerType',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Colors.white.withOpacity(0.62),
                ),
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: onSimulateHardwareTrigger,
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFFBFFAF3),
                side: const BorderSide(color: Color(0xFF21D4C2)),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
              child: const Text('Simulate hardware trigger'),
            ),
          ),
        ],
      ),
    );
  }
}
