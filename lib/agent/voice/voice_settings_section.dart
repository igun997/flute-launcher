import 'package:material_ui/material_ui.dart';

import '../../app/theme.dart';
import '../ui/settings_widgets.dart';
import 'voice_controller.dart';

/// Voice options for the agent settings page. Null language follows the device locale.
const _languages = <String?, String>{
  null: 'Device default',
  'en-US': 'English (US)',
  'en-GB': 'English (UK)',
  'id-ID': 'Bahasa Indonesia',
};

/// Display name for a voice language code. Null or unknown codes read as the device default.
String voiceLanguageLabel(String? code) => _languages[code] ?? 'Device default';

class VoiceSettingsSection extends StatelessWidget {
  const VoiceSettingsSection({super.key, required this.voice});

  final VoiceController voice;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: voice,
      builder: (context, _) {
        final language = _languages.containsKey(voice.language) ? voice.language : null;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SettingsSection(
              title: 'Speech',
              children: [
                SettingsGroup(
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(FluteSpace.lg),
                      child: InputDecorator(
                        decoration: const InputDecoration(labelText: 'Voice language'),
                        child: DropdownButtonHideUnderline(
                          child: DropdownButton<String?>(
                            value: language,
                            isExpanded: true,
                            dropdownColor: FluteColors.surfaceTop,
                            style: FluteText.body.copyWith(color: FluteColors.text),
                            items: [
                              for (final entry in _languages.entries)
                                DropdownMenuItem<String?>(value: entry.key, child: Text(entry.value)),
                            ],
                            onChanged: voice.setLanguage,
                          ),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(FluteSpace.lg, 0, FluteSpace.lg, FluteSpace.md),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  'Speech rate',
                                  style: FluteText.label.copyWith(color: FluteColors.text),
                                ),
                              ),
                              Text('${voice.rate.toStringAsFixed(1)}x', style: FluteText.caption),
                            ],
                          ),
                          Slider(
                            min: 0.5,
                            max: 2.0,
                            divisions: 15,
                            value: voice.rate,
                            label: '${voice.rate.toStringAsFixed(1)}x',
                            onChanged: voice.setRate,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: FluteSpace.xl),
            SettingsSection(
              title: 'Replies',
              children: [
                SettingsGroup(
                  children: [
                    SettingsSwitchRow(
                      title: 'Read replies aloud',
                      value: voice.autoSpeak,
                      onChanged: voice.setAutoSpeak,
                    ),
                    SettingsSwitchRow(
                      title: 'Hands-free listening',
                      subtitle: Text('Listen again after each reply.', style: FluteText.caption),
                      value: voice.handsFree,
                      onChanged: voice.setHandsFree,
                    ),
                  ],
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}
