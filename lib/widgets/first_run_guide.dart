import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _guideCompletedKey = 'first_run_guide_completed';

Future<void> showFirstRunGuide(BuildContext context) async {
  final preferences = SharedPreferencesAsync();
  final hasCompletedGuide = await preferences.getBool(_guideCompletedKey);
  if (!context.mounted || (hasCompletedGuide ?? false)) return;

  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _FirstRunGuideDialog(preferences: preferences),
  );
}

class _FirstRunGuideDialog extends StatefulWidget {
  const _FirstRunGuideDialog({required this.preferences});

  final SharedPreferencesAsync preferences;

  @override
  State<_FirstRunGuideDialog> createState() => _FirstRunGuideDialogState();
}

class _FirstRunGuideDialogState extends State<_FirstRunGuideDialog> {
  static const _steps = [
    _GuideStep(
      icon: Icons.sensors_rounded,
      eyebrow: 'WITAJ W CZUJNIKU',
      title: 'Twój domowy klimat pod kontrolą',
      description:
          'Aplikacja odczytuje dane z czujnika Xiaomi i pokazuje je w czytelnej, spokojnej oprawie.',
      details: [
        'Nie musisz niczego konfigurować — skanowanie rozpoczyna się samo.',
        'Czujnik powinien znajdować się w pobliżu telefonu.',
      ],
      color: Color(0xFF5EEAD4),
    ),
    _GuideStep(
      icon: Icons.bluetooth_searching_rounded,
      eyebrow: 'POŁĄCZENIE',
      title: 'Włącz Bluetooth i gotowe',
      description:
          'Telefon wyszukuje czujnik automatycznie. Przy pierwszym użyciu Android może poprosić o dostęp do urządzeń w pobliżu.',
      details: [
        'Zezwól na wymagane uprawnienia, aby aplikacja mogła znaleźć czujnik.',
        'Gdy Bluetooth jest wyłączony, zobaczysz podpowiedź na ekranie.',
      ],
      color: Color(0xFF7DD3FC),
    ),
    _GuideStep(
      icon: Icons.device_thermostat_rounded,
      eyebrow: 'TWOJE ODCZYTY',
      title: 'Temperatura i wilgotność',
      description:
          'Po znalezieniu czujnika na ekranie pojawią się aktualne pomiary. Jeśli urządzenie je udostępnia, zobaczysz też poziom baterii.',
      details: [
        'Pociągnij ekran w dół, aby odświeżyć połączenie.',
        'Godzina na dole ekranu informuje o ostatnim odczycie.',
      ],
      color: Color(0xFFFBBF24),
    ),
    _GuideStep(
      icon: Icons.touch_app_rounded,
      eyebrow: 'MAŁE PODPOWIEDZI',
      title: 'Odkryj dodatkowe informacje',
      description:
          'Ekran dopasowuje się do pory dnia. Możesz też sprawdzić pogodę i zmienić wygląd tła.',
      details: [
        'Dotknij informacji o pogodzie u góry, aby zobaczyć szczegóły.',
        'Dotknij okrągłego przycisku na dole, aby zmienić motyw.',
      ],
      color: Color(0xFFC4B5FD),
    ),
  ];

  int _currentStep = 0;
  bool _isSaving = false;
  String? _saveError;

  Future<void> _finish() async {
    setState(() {
      _isSaving = true;
      _saveError = null;
    });

    try {
      await widget.preferences.setBool(_guideCompletedKey, true);
      if (mounted) Navigator.of(context).pop();
    } on PlatformException catch (error) {
      if (mounted) {
        setState(() {
          _isSaving = false;
          _saveError =
              'Nie udało się zapisać ustawienia: '
              '${error.message ?? error.code}';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final step = _steps[_currentStep];
    final screenHeight = MediaQuery.sizeOf(context).height;

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 460,
          maxHeight: screenHeight * 0.88,
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(30),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xF21A3045), Color(0xF20B1422)],
                ),
                borderRadius: BorderRadius.circular(30),
                border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.32),
                    blurRadius: 36,
                    offset: const Offset(0, 18),
                  ),
                ],
              ),
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 22, 24, 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 38,
                          height: 38,
                          decoration: BoxDecoration(
                            color: Colors.tealAccent.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(13),
                          ),
                          child: const Icon(
                            Icons.waves_rounded,
                            color: Colors.tealAccent,
                            size: 21,
                          ),
                        ),
                        const SizedBox(width: 11),
                        const Expanded(
                          child: Text(
                            'CZUJNIK',
                            style: TextStyle(
                              color: Colors.white70,
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 2,
                            ),
                          ),
                        ),
                        TextButton(
                          onPressed: _isSaving ? null : _finish,
                          child: const Text('Pomiń'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 22),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: LinearProgressIndicator(
                        value: (_currentStep + 1) / _steps.length,
                        minHeight: 4,
                        backgroundColor: Colors.white.withValues(alpha: 0.1),
                        valueColor: AlwaysStoppedAnimation<Color>(step.color),
                      ),
                    ),
                    const SizedBox(height: 26),
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 260),
                      switchInCurve: Curves.easeOutCubic,
                      switchOutCurve: Curves.easeIn,
                      transitionBuilder: (child, animation) => FadeTransition(
                        opacity: animation,
                        child: SlideTransition(
                          position: Tween<Offset>(
                            begin: const Offset(0.04, 0),
                            end: Offset.zero,
                          ).animate(animation),
                          child: child,
                        ),
                      ),
                      child: Column(
                        key: ValueKey(_currentStep),
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Center(
                            child: Container(
                              width: 92,
                              height: 92,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: step.color.withValues(alpha: 0.1),
                                border: Border.all(
                                  color: step.color.withValues(alpha: 0.25),
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: step.color.withValues(alpha: 0.12),
                                    blurRadius: 28,
                                    spreadRadius: 2,
                                  ),
                                ],
                              ),
                              child: Icon(
                                step.icon,
                                size: 42,
                                color: step.color,
                              ),
                            ),
                          ),
                          const SizedBox(height: 25),
                          Text(
                            step.eyebrow,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: step.color,
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 1.8,
                            ),
                          ),
                          const SizedBox(height: 9),
                          Text(
                            step.title,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 24,
                              height: 1.18,
                              fontWeight: FontWeight.w700,
                              letterSpacing: -0.4,
                            ),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            step.description,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.7),
                              fontSize: 14,
                              height: 1.55,
                            ),
                          ),
                          const SizedBox(height: 22),
                          ...step.details.map(
                            (detail) => Padding(
                              padding: const EdgeInsets.only(bottom: 12),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Icon(
                                    Icons.check_circle_rounded,
                                    size: 18,
                                    color: step.color,
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Text(
                                      detail,
                                      style: TextStyle(
                                        color: Colors.white.withValues(
                                          alpha: 0.82,
                                        ),
                                        fontSize: 13,
                                        height: 1.4,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: List.generate(
                        _steps.length,
                        (index) => AnimatedContainer(
                          duration: const Duration(milliseconds: 220),
                          width: index == _currentStep ? 20 : 6,
                          height: 6,
                          margin: const EdgeInsets.symmetric(horizontal: 3),
                          decoration: BoxDecoration(
                            color: index == _currentStep
                                ? step.color
                                : Colors.white.withValues(alpha: 0.24),
                            borderRadius: BorderRadius.circular(6),
                          ),
                        ),
                      ),
                    ),
                    if (_saveError != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        _saveError!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Color(0xFFFCA5A5),
                          fontSize: 12,
                        ),
                      ),
                    ],
                    const SizedBox(height: 18),
                    FilledButton(
                      onPressed: _isSaving
                          ? null
                          : _currentStep == _steps.length - 1
                          ? _finish
                          : () => setState(() => _currentStep++),
                      style: FilledButton.styleFrom(
                        backgroundColor: step.color,
                        foregroundColor: const Color(0xFF0B1422),
                        minimumSize: const Size.fromHeight(52),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(17),
                        ),
                        textStyle: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      child: _isSaving
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Color(0xFF0B1422),
                              ),
                            )
                          : Text(
                              _currentStep == _steps.length - 1
                                  ? 'Zaczynamy!'
                                  : 'Dalej',
                            ),
                    ),
                    if (_currentStep > 0) ...[
                      const SizedBox(height: 6),
                      TextButton(
                        onPressed: _isSaving
                            ? null
                            : () => setState(() => _currentStep--),
                        child: const Text('Wstecz'),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _GuideStep {
  const _GuideStep({
    required this.icon,
    required this.eyebrow,
    required this.title,
    required this.description,
    required this.details,
    required this.color,
  });

  final IconData icon;
  final String eyebrow;
  final String title;
  final String description;
  final List<String> details;
  final Color color;
}
