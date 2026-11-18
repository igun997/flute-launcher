/// Flute's own line icons for the apps people pin most. Pinned apps that have one are drawn in
/// the launcher's style (a thin white glyph tinted to the sky's ink); every other app keeps its
/// own icon, toned gray.
const _byPackage = <String, String>{
  // Phone
  'com.samsung.android.dialer': 'phone',
  'com.google.android.dialer': 'phone',
  'com.android.dialer': 'phone',
  // Messages
  'com.google.android.apps.messaging': 'messages',
  'com.samsung.android.messaging': 'messages',
  'com.android.mms': 'messages',
  // Chat
  'com.whatsapp': 'whatsapp',
  'com.whatsapp.w4b': 'whatsapp_business',
  'org.telegram.messenger': 'telegram',
  'org.telegram.messenger.web': 'telegram',
  'org.telegram.plus': 'telegram',
  // Banking
  'com.bca': 'bank',
  'com.bca.mybca.omni.android': 'bank',
  // Rides
  'com.grabtaxi.passenger': 'ride',
  'com.gojek.app': 'ride',
};

/// Asset path of the redrawn icon for [package], or null when it has none.
String? redrawnIconAsset(String package) {
  final key = _byPackage[package];
  return key == null ? null : 'assets/icons/$key.png';
}

/// Every key that has a drawn asset, for tests that check the files exist.
Set<String> get redrawnIconKeys => _byPackage.values.toSet();
