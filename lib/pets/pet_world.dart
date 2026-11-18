import 'dart:math' as math;
import 'dart:ui' show Offset, Rect, Size;

/// What a pet is doing.
enum PetMode {
  /// Strolling to a random spot.
  walking,

  /// Standing about for a few seconds.
  idling,

  /// Heading for its house because of rain or bedtime.
  goingHome,

  /// Fading through the door.
  entering,

  /// Indoors, out of the rain.
  inside,

  /// Curled up in front of its house, asleep (bedtime or Sleep mode).
  sleeping,

  /// Coming back out after the weather cleared.
  leaving,

  /// Reacting to a tap.
  happy,

  /// Opened the door because its house was tapped; goes back in after a moment.
  peeking,
}

/// Why pets want to be indoors.
enum Shelter {
  none,

  /// Rain, snow or a storm.
  rain,

  /// Night or Sleep mode: they sleep.
  sleep,
}

/// A floating heart from petting.
class Heart {
  Heart(this.x, this.y);
  double x;
  double y;
  double age = 0;
}

class PetActor {
  PetActor({required this.id, required this.houseX, required this.x, required this.lane}) : baseLane = lane;

  final String id;
  double houseX;
  double x;

  /// 0 = far lane (behind), 1 = near lane.
  double lane;

  /// The lane it strolls in; [lane] changes while it sleeps by its door.
  final double baseLane;

  /// +1 faces right, -1 faces left.
  int dir = 1;
  PetMode mode = PetMode.idling;

  /// Seconds in the current mode.
  double t = 0;
  double? target;
  double idleFor = 1;

  /// 0 hidden .. 1 fully visible (used while going through the door).
  double fade = 1;

  /// Total seconds alive, for animation frames.
  double clock = 0;

  String? say;
  double sayLeft = 0;

  bool get visible => fade > 0.02;
  bool get indoors => mode == PetMode.inside;
  bool get asleep => mode == PetMode.sleeping;
}

/// The little world on the home screen: pets, their houses and the rules for weather and sleep.
/// Pure Dart with no widgets, driven by [update], so it can be tested.
class PetWorld {
  PetWorld({required List<String> ids, required this.phrases, int seed = 7}) : _rng = math.Random(seed) {
    setPets(ids);
  }

  /// Walking speed in logical pixels per second.
  static const speed = 30.0;

  final math.Random _rng;
  final Map<String, List<String>> phrases;
  final List<PetActor> actors = [];
  final List<Heart> hearts = [];

  Size size = const Size(360, 260);
  Shelter shelter = Shelter.none;

  /// Sprite edge in logical pixels.
  double get sprite => (size.height * 0.34).clamp(60.0, 92.0);
  double get houseHeight => sprite * 1.15;
  double get houseBaseY => size.height * 0.62;
  double laneY(double lane) => size.height * (0.72 + 0.2 * lane);

  void setPets(List<String> ids) {
    final old = {for (final a in actors) a.id: a};
    actors.clear();
    for (var i = 0; i < ids.length; i++) {
      final a = old[ids[i]] ??
          PetActor(id: ids[i], houseX: 0, x: size.width * (0.15 + 0.7 * _rng.nextDouble()), lane: i % 2 == 0 ? 0.15 : 0.7);
      actors.add(a);
    }
    _placeHouses();
  }

  void layout(Size s) {
    size = s;
    _placeHouses();
    for (final a in actors) {
      a.x = a.x.clamp(sprite / 2, math.max(sprite / 2, s.width - sprite / 2));
    }
  }

  void _placeHouses() {
    final n = actors.length;
    for (var i = 0; i < n; i++) {
      // One pet: its house stands to the right so there is room to stroll on the left.
      actors[i].houseX = n == 1 ? size.width * 0.78 : size.width * (i + 0.5) / n;
    }
  }

  double _randomX() => sprite / 2 + _rng.nextDouble() * math.max(1, size.width - sprite);

  /// Advance the simulation by [dt] seconds.
  void update(double dt) {
    for (final a in actors) {
      a.clock += dt;
      a.t += dt;
      if (a.sayLeft > 0) {
        a.sayLeft -= dt;
        if (a.sayLeft <= 0) a.say = null;
      }
      _step(a, dt);
    }
    for (final h in hearts) {
      h.age += dt;
      h.y -= 26 * dt;
    }
    hearts.removeWhere((h) => h.age > 1.4);
  }

  void _setMode(PetActor a, PetMode m) {
    if (a.mode == PetMode.sleeping && m != PetMode.sleeping) a.lane = a.baseLane;
    a.mode = m;
    a.t = 0;
  }

  void _walkToward(PetActor a, double target, double dt) {
    final dx = target - a.x;
    if (dx.abs() < 1) return;
    a.dir = dx > 0 ? 1 : -1;
    final step = speed * dt;
    a.x += dx.abs() <= step ? dx : step * a.dir;
  }

  void _step(PetActor a, double dt) {
    final needHome = shelter != Shelter.none;
    switch (a.mode) {
      case PetMode.walking:
        if (needHome) return _setMode(a, PetMode.goingHome);
        final target = a.target ?? (a.target = _randomX());
        _walkToward(a, target, dt);
        if ((target - a.x).abs() < 1) {
          a.target = null;
          a.idleFor = 2 + _rng.nextDouble() * 4;
          _setMode(a, PetMode.idling);
        }
      case PetMode.idling:
        if (needHome) return _setMode(a, PetMode.goingHome);
        if (a.t >= a.idleFor) _setMode(a, PetMode.walking);
      case PetMode.happy:
        if (a.t >= 1.3) _setMode(a, needHome ? PetMode.goingHome : PetMode.idling);
      case PetMode.goingHome:
        _walkToward(a, a.houseX, dt);
        if ((a.houseX - a.x).abs() < 1) {
          _setMode(a, shelter == Shelter.sleep ? PetMode.sleeping : PetMode.entering);
          a.dir = 1;
          if (a.mode == PetMode.sleeping) a.lane = 0.05; // lie down right in front of the door
        }
      case PetMode.entering:
        a.fade = (1 - a.t / 0.5).clamp(0.0, 1.0);
        if (a.t >= 0.5) {
          a.fade = 0;
          _setMode(a, PetMode.inside);
        }
      case PetMode.inside:
        // Stay in until the need is over, staggered so they do not all pop out at once.
        if (!needHome && a.t > 1.5 + _rng.nextDouble() * 2.5) _setMode(a, PetMode.leaving);
      case PetMode.leaving:
        a.fade = (a.t / 0.5).clamp(0.0, 1.0);
        if (a.t >= 0.5) {
          a.fade = 1;
          a.idleFor = 1 + _rng.nextDouble() * 2;
          _setMode(a, PetMode.idling);
        }
      case PetMode.sleeping:
        // Wakes when bedtime is over; a rain shower while asleep moves it indoors.
        if (shelter == Shelter.none && a.t > 1 + _rng.nextDouble() * 3) {
          _setMode(a, PetMode.happy);
        } else if (shelter == Shelter.rain) {
          _setMode(a, PetMode.entering);
        }
      case PetMode.peeking:
        a.fade = a.t < 0.3 ? a.t / 0.3 : 1;
        if (a.t >= 2.4) _setMode(a, PetMode.entering);
    }
  }

  /// Taps a pet: it reacts and says something. Returns false if it was indoors.
  bool pet(PetActor a) {
    if (a.indoors || !a.visible) return false;
    if (a.asleep) {
      // Do not wake it; it just mumbles.
      a.say = 'Zzz… five more minutes…';
      a.sayLeft = 2.2;
      hearts.add(Heart(a.x, laneY(a.lane) - sprite * 0.6));
      return true;
    }
    _setMode(a, PetMode.happy);
    final lines = phrases[a.id] ?? const ['Hi!'];
    a.say = lines[_rng.nextInt(lines.length)];
    a.sayLeft = 2.2;
    hearts.add(Heart(a.x, laneY(a.lane) - sprite));
    return true;
  }

  /// Taps a house: if its pet is inside it opens the door for a moment.
  bool knock(PetActor a) {
    if (!a.indoors) return false;
    _setMode(a, PetMode.peeking);
    a.x = a.houseX;
    a.dir = 1;
    a.say = shelter == Shelter.sleep ? 'Five more minutes…' : (shelter == Shelter.rain ? "It's raining!" : 'Hi!');
    a.sayLeft = 2.2;
    return true;
  }

  Rect petRect(PetActor a) => Rect.fromCenter(center: Offset(a.x, laneY(a.lane) - sprite / 2), width: sprite, height: sprite);

  Rect houseRect(PetActor a) =>
      Rect.fromCenter(center: Offset(a.houseX, houseBaseY - houseHeight / 2), width: houseHeight, height: houseHeight);

  /// What a tap at [p] hits: a visible pet first (nearest lane wins), then a house.
  PetActor? hitPet(Offset p) {
    PetActor? best;
    for (final a in actors) {
      if (!a.visible || a.indoors) continue;
      if (petRect(a).contains(p) && (best == null || a.lane > best.lane)) best = a;
    }
    return best;
  }

  PetActor? hitHouse(Offset p) {
    for (final a in actors) {
      if (houseRect(a).contains(p)) return a;
    }
    return null;
  }

  /// Handles a tap at [p]. Returns true when it hit something.
  bool tap(Offset p) {
    final a = hitPet(p);
    if (a != null) return pet(a);
    final h = hitHouse(p);
    if (h != null) return knock(h) || true;
    return false;
  }
}
