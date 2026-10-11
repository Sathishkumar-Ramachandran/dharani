import 'package:google_mlkit_translation/google_mlkit_translation.dart';

class Lang {
  const Lang(this.code, this.name, this.native, this.locale, this.mlkit);
  final String code; // BCP-47 language
  final String name, native;
  final String locale; // locale id for speech recognition and TTS
  final TranslateLanguage mlkit;
}

/// Languages supported end to end by the Android on-device backend (ML Kit translation).
const kLanguages = <Lang>[
  Lang('en', 'English', 'English', 'en_IN', TranslateLanguage.english),
  Lang('hi', 'Hindi', 'हिन्दी', 'hi_IN', TranslateLanguage.hindi),
  Lang('ta', 'Tamil', 'தமிழ்', 'ta_IN', TranslateLanguage.tamil),
  Lang('te', 'Telugu', 'తెలుగు', 'te_IN', TranslateLanguage.telugu),
  Lang('kn', 'Kannada', 'ಕನ್ನಡ', 'kn_IN', TranslateLanguage.kannada),
  Lang('mr', 'Marathi', 'मराठी', 'mr_IN', TranslateLanguage.marathi),
  Lang('bn', 'Bengali', 'বাংলা', 'bn_IN', TranslateLanguage.bengali),
  Lang('gu', 'Gujarati', 'ગુજરાતી', 'gu_IN', TranslateLanguage.gujarati),
  Lang('ur', 'Urdu', 'اردو', 'ur_IN', TranslateLanguage.urdu),
  Lang('fr', 'French', 'Français', 'fr_FR', TranslateLanguage.french),
];

Lang langByCode(String code) => kLanguages.firstWhere((l) => l.code == code);
