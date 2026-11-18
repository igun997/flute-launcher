/// Apps pinned to the home screen on first run, in order. Each slot lists alternatives
/// (different makers ship different packages); the first one installed is used and a slot
/// with none installed is skipped.
const defaultPinSlots = <List<String>>[
  // Phone
  ['com.samsung.android.dialer', 'com.google.android.dialer', 'com.android.dialer'],
  // Messages
  ['com.google.android.apps.messaging', 'com.samsung.android.messaging', 'com.android.mms'],
  // WhatsApp Business
  ['com.whatsapp.w4b'],
  // WhatsApp
  ['com.whatsapp'],
  // Telegram
  ['org.telegram.messenger', 'org.telegram.messenger.web', 'org.telegram.plus'],
  // BCA (myBCA first, then BCA mobile)
  ['com.bca.mybca.omni.android', 'com.bca'],
  // Grab
  ['com.grabtaxi.passenger'],
];

/// The default pins that exist on this phone, in slot order, without duplicates.
List<String> resolveDefaultPins(Set<String> installed) {
  final out = <String>[];
  for (final slot in defaultPinSlots) {
    for (final pkg in slot) {
      if (installed.contains(pkg)) {
        if (!out.contains(pkg)) out.add(pkg);
        break;
      }
    }
  }
  return out;
}
