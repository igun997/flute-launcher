import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:focus_launcher/core/day_style.dart';
import 'package:focus_launcher/pets/pet_stage.dart';
import 'package:focus_launcher/pets/pet_world.dart';
import 'package:focus_launcher/weather/weather_service.dart';

PetWorld world({List<String> ids = const ['pip', 'nori', 'sora']}) {
  final w = PetWorld(ids: ids, phrases: {for (final i in ids) i: ['Hi $i']}, seed: 3)..layout(const Size(360, 260));
  return w;
}

void run(PetWorld w, double seconds) {
  for (var t = 0.0; t < seconds; t += 0.066) {
    w.update(0.066);
  }
}

void main() {
  group('weather and bedtime', () {
    test('rain sends every pet indoors, out of sight', () {
      final w = world();
      w.shelter = Shelter.rain;
      run(w, 40);
      expect(w.actors.every((a) => a.indoors && !a.visible), isTrue);
    });

    test('they come back out when the rain stops', () {
      final w = world();
      w.shelter = Shelter.rain;
      run(w, 40);
      w.shelter = Shelter.none;
      run(w, 15);
      expect(w.actors.every((a) => a.visible && !a.indoors), isTrue);
    });

    test('at bedtime they sleep in front of their own door, visible', () {
      final w = world();
      w.shelter = Shelter.sleep;
      run(w, 40);
      for (final a in w.actors) {
        expect(a.asleep, isTrue);
        expect(a.visible, isTrue);
        expect((a.x - a.houseX).abs(), lessThan(1.5));
        expect(a.lane, lessThan(0.1));
      }
    });

    test('waking up puts them back in their lane and they stroll again', () {
      final w = world();
      w.shelter = Shelter.sleep;
      run(w, 40);
      w.shelter = Shelter.none;
      run(w, 20);
      for (final a in w.actors) {
        expect(a.asleep, isFalse);
        expect(a.lane, a.baseLane);
      }
    });

    test('rain while asleep moves the pet indoors', () {
      final w = world(ids: ['pip']);
      w.shelter = Shelter.sleep;
      run(w, 30);
      w.shelter = Shelter.rain;
      run(w, 5);
      expect(w.actors.single.indoors, isTrue);
    });
  });

  group('interaction', () {
    test('tapping a pet makes it happy, say something and send up a heart', () {
      final w = world(ids: ['pip']);
      run(w, 2);
      final a = w.actors.single;
      final hit = w.tap(w.petRect(a).center);
      expect(hit, isTrue);
      expect(a.mode, PetMode.happy);
      expect(a.say, 'Hi pip');
      expect(w.hearts, hasLength(1));
    });

    test('knocking on the house of a pet that is indoors opens the door, then it goes back in', () {
      final w = world(ids: ['pip']);
      w.shelter = Shelter.rain;
      run(w, 40);
      final a = w.actors.single;
      expect(a.indoors, isTrue);
      expect(w.tap(w.houseRect(a).center), isTrue);
      expect(a.mode, PetMode.peeking);
      run(w, 1);
      expect(a.visible, isTrue);
      expect(a.say, "It's raining!");
      run(w, 4);
      expect(a.indoors, isTrue);
    });

    test('a sleeping pet is not woken by a tap, it only mumbles', () {
      final w = world(ids: ['pip']);
      w.shelter = Shelter.sleep;
      run(w, 40);
      final a = w.actors.single;
      expect(w.tap(w.petRect(a).center), isTrue);
      expect(a.asleep, isTrue);
      expect(a.say, contains('Zzz'));
    });

    test('a tap on empty ground hits nothing', () {
      final w = world();
      expect(w.tap(const Offset(2, 2)), isFalse);
    });

    test('the nearer pet wins when two overlap', () {
      final w = world(ids: ['pip', 'nori']);
      final far = w.actors[0]..x = 100;
      final near = w.actors[1]..x = 100;
      expect(far.lane, lessThan(near.lane));
      expect(w.hitPet(w.petRect(near).center), same(near));
    });
  });

  test('pets never leave the stage while strolling', () {
    final w = world();
    run(w, 120);
    for (final a in w.actors) {
      expect(a.x, inInclusiveRange(0, 360));
    }
  });

  group('repaint budget', () {
    int changesIn(PetWorld w, double seconds) {
      var changes = 0;
      var last = worldSignature(w);
      for (var t = 0.0; t < seconds; t += 0.083) {
        w.update(0.083);
        final sig = worldSignature(w);
        if (sig != last) changes++;
        last = sig;
      }
      return changes;
    }

    test('a pet standing still asks for far fewer frames than the 12 ticks a second', () {
      final w = world(ids: ['pip']);
      // Reach a standing state, then freeze its decisions by faking a long idle.
      w.actors.single
        ..mode = PetMode.idling
        ..idleFor = 999;
      final changes = changesIn(w, 6);
      expect(changes, lessThan(6 * 6), reason: 'idle at 3 frames a second plus bookkeeping');
    });

    test('a sleeping pet is also cheap', () {
      final w = world(ids: ['pip']);
      w.shelter = Shelter.sleep;
      run(w, 40);
      expect(changesIn(w, 6), lessThan(6 * 8));
    });

    test('a walking pet does change what is drawn every tick', () {
      final w = world(ids: ['pip']);
      w.actors.single
        ..mode = PetMode.walking
        ..target = 340;
      w.actors.single.x = 20;
      expect(changesIn(w, 3), greaterThan(30));
    });
  });

  group('shelterFor', () {
    Shelter f({WeatherKind k = WeatherKind.clear, bool sleep = false, int hour = 12}) =>
        shelterFor(kind: k, phase: DayPhase.day, sleepMode: sleep, hour: hour);

    test('clear daytime means outside', () => expect(f(), Shelter.none));
    test('rain, drizzle, thunder and snow mean indoors', () {
      for (final k in [WeatherKind.rain, WeatherKind.drizzle, WeatherKind.thunder, WeatherKind.snow]) {
        expect(f(k: k), Shelter.rain, reason: k.name);
      }
    });
    test('late at night or Sleep mode means sleeping, even in the rain', () {
      expect(f(hour: 22), Shelter.sleep);
      expect(f(hour: 3), Shelter.sleep);
      expect(f(sleep: true), Shelter.sleep);
      expect(f(k: WeatherKind.rain, hour: 23), Shelter.sleep);
    });
    test('evening before 21:00 is still awake', () => expect(f(hour: 20), Shelter.none));
  });
}
