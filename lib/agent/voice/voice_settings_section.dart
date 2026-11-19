import 'package:material_ui/material_ui.dart';

import '../../app/theme.dart';
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
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(
              title: const Text('Voice language', style: TextStyle(color: FluteColors.text)),
              trailing: DropdownButton<String?>(
                value: language,
                dropdownColor: FluteColors.surfaceHigh,
                style: const TextStyle(color: FluteColors.text),
                items: [
                  for (final entry in _languages.entries)
                    DropdownMenuItem<String?>(value: entry.key, child: Text(entry.value)),
                ],
                onChanged: voice.setLanguage,
              ),
            ),
            ListTile(
              title: const Text('Speech rate', style: TextStyle(color: FluteColors.text)),
              subtitle: Slider(
                min: 0.5,
                max: 2.0,
                divisions: 15,
                value: voice.rate,
                label: '${voice.rate.toStringAsFixed(1)}x',
                onChanged: voice.setRate,
              ),
            ),
            SwitchListTile(
              title: const Text('Read replies aloud', style: TextStyle(color: FluteColors.text)),
              value: voice.autoSpeak,
              onChanged: voice.setAutoSpeak,
            ),
            SwitchListTile(
              title: const Text('Hands-free listening', style: TextStyle(color: FluteColors.text)),
              subtitle: const Text(
                'Listen again after each reply.',
                style: TextStyle(color: FluteColors.muted),
              ),
              value: voice.handsFree,
              onChanged: voice.setHandsFree,
            ),
          ],
        );
      },
    );
  }
}
