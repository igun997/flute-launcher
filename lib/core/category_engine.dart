import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

import 'models.dart';

/// Decides an app's category. Order: user override, bundled package map,
/// Android's own `ApplicationInfo.category`, keyword heuristics, then Other.
class CategoryEngine {
  CategoryEngine(this._known, [Map<String, AppCategory>? overrides]) : overrides = {...?overrides};

  final Map<String, AppCategory> _known;
  final Map<String, AppCategory> overrides;

  static Future<CategoryEngine> load({Map<String, AppCategory>? overrides}) async {
    final raw = jsonDecode(await rootBundle.loadString('assets/data/categories.json')) as Map<String, dynamic>;
    final known = <String, AppCategory>{};
    raw.forEach((pkg, cat) {
      final c = AppCategory.fromName(cat as String?);
      if (c != null) known[pkg] = c;
    });
    return CategoryEngine(known, overrides);
  }

  // ApplicationInfo.CATEGORY_* constants.
  static const _androidMap = <int, AppCategory>{
    0: AppCategory.games,
    1: AppCategory.media, // audio
    2: AppCategory.media, // video
    3: AppCategory.tools, // image
    4: AppCategory.social,
    5: AppCategory.media, // news
    6: AppCategory.travel, // maps
    7: AppCategory.work, // productivity
  };

  // Ordered: first match wins. Matched against "package label" lowercased.
  static final _keywords = <(RegExp, AppCategory)>[
    (RegExp(r'bank|wallet|\bpay\b|payment|finance|invest|crypto|broker|insurance|dana|ovo|gopay|jago|jenius'), AppCategory.banking),
    (RegExp(r'whatsapp|telegram|messag|messenger|\bsms\b|signal|discord|\bchat\b|dialer|\bphone\b'), AppCategory.chat),
    (RegExp(r'instagram|facebook|twitter|tiktok|snapchat|reddit|threads|linkedin|pinterest'), AppCategory.social),
    (RegExp(r'game|\bplay games\b|roblox|minecraft'), AppCategory.games),
    (RegExp(r'music|video|player|podcast|stream|netflix|youtube|spotify|news|radio|tv\b'), AppCategory.media),
    (RegExp(r'shop|store|market|mall|ecommerce|food|delivery'), AppCategory.shopping),
    (RegExp(r'map|travel|taxi|ride|flight|hotel|train|transit|navigation'), AppCategory.travel),
    (RegExp(r'office|docs|sheet|slides|calendar|mail|meet|zoom|teams|notion|drive|\bnotes?\b|task|todo|slack|lark|github'), AppCategory.work),
    (RegExp(r'camera|gallery|photo|file|calculator|clock|setting|browser|chrome|keyboard|weather|vpn|security|launcher'), AppCategory.tools),
  ];

  AppCategory categorize(String package, String label, {int androidCategory = -1}) {
    final o = overrides[package];
    if (o != null) return o;
    final k = _known[package];
    if (k != null) return k;
    final a = _androidMap[androidCategory];
    if (a != null) return a;
    final hay = '$package ${label.toLowerCase()}'.toLowerCase();
    for (final (re, cat) in _keywords) {
      if (re.hasMatch(hay)) return cat;
    }
    return AppCategory.other;
  }
}
