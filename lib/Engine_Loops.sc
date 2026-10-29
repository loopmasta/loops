// loops: a sampled Rhodes for the loop voices, with a long reverb and a soft echo

Engine_Loops : CroneEngine {

  var rhodes; // sampled note -> [buffers by layer 1 (loudest) .. 5 (softest)]
  var voices, fx, revBus, fxSynth;
  var tapeBus, tapeSynth; // the tape delay
  var vibBus, vibSynth; // the vibrato: one shared LFO, so all notes sway together

  *new { arg context, doneCallback;
    ^super.new(context, doneCallback);
  }

  alloc {
    var server = context.server;
    var out = context.out_b.index;

    revBus = Bus.audio(server, 2);
    tapeBus = Bus.audio(server, 2);

    // one sample of the jRhodes3d set (a 1977 Rhodes Mark I by Jeff Learman, samples
    // CC BY-NC 4.0, music made with it CC0), transposed by `rate`, ringing out fully
    // the vibrato is a stereo tremolo, as in a Suitcase Rhodes: the sound swings
    // between left and right with the shared LFO on `vib` (already scaled by depth)
    // held for `dur`, then damped over `rel` (dur 0 = ring out fully)
    SynthDef(\loops_rhodes, { arg out, rev, tape, vib, buf, rate = 1, amp = 0.5, pan = 0, send = 0.5,
        dur = 0, rel = 0.8;
      var damp = Select.kr(dur > 0, [DC.kr(1),
        EnvGen.kr(Env([1, 1, 0], [dur.max(0.01), rel], [0, -3]), doneAction: 2)]);
      var sig = PlayBuf.ar(1, buf, BufRateScale.kr(buf) * rate, doneAction: 2) * amp * damp;
      var m = In.kr(vib);
      sig = Pan2.ar(sig, pan) * [1 + m, 1 - m];
      Out.ar(out, sig);
      Out.ar(rev, sig * send);
      Out.ar(tape, sig);
    }).add;

    // the tape delay: every repeat passes the same faults again, so it wears more
    // with each pass: highs and lows get lost, it saturates, its pitch wavers (wow
    // and flutter), it drops out now and then, and a little hiss. `wear` (0..1)
    // sets how worn the tape is; the repeats also go into the reverb
    SynthDef(\loops_tape, { arg out, rev, in, mix = 0.4, time = 0.85, feedback = 0.6, wear = 0.5;
      var w = Lag.kr(wear, 0.5);
      var dry = In.ar(in, 2);
      var fb = LocalIn.ar(2);
      var wow = (SinOsc.kr(0.3 + (w * 0.4), [0, 1]) * 0.006 * w)
        + (LFNoise2.kr(7) * 0.0012 * w);
      var x = DelayC.ar(dry + fb, 3, (Lag.kr(time, 1) + wow).clip(0.02, 2.9));
      var drop = Lag.kr(LFNoise0.kr(1.5 + (w * 2)) > (1 - (0.3 * w)), 0.05);
      x = LPF.ar(x, 7000 - (w * 5000));
      x = HPF.ar(x, 80 + (w * 250));
      x = (x * (1 + w)).tanh / (1 + (w * 0.6));
      x = x * (1 - (drop * 0.7));
      x = x + (HPF.ar(PinkNoise.ar([1, 1]), 2000) * 0.002 * w);
      LocalOut.ar(x * Lag.kr(feedback, 0.3).clip(0, 0.95));
      Out.ar(out, x * mix);
      Out.ar(rev, x * mix * 0.6);
    }).add;

    // the space: a long dark reverb and a soft echo into it
    SynthDef(\loops_fx, { arg out, rev, mix = 0.8;
      var in = In.ar(rev, 2);
      var echo = CombC.ar(LPF.ar(in, 3000), 2, [0.71, 0.93], 6) * 0.25;
      var r = JPverb.ar(in + echo, 7, 0.5, 2, 0.7, 0.05, 2);
      Out.ar(out, r * mix);
    }).add;

    server.sync;

    // the Rhodes samples (shared with miles): A_<note>__<name>_<layer>.flac, read up to 10 s
    rhodes = Dictionary.new;
    PathName("~/dust/audio/miles/jRhodes3d-mono/".standardizePath).files.do({ arg f;
      var parts = f.fileNameWithoutExtension.split($_);
      var note = parts[1].asInteger;
      var layer = parts.last.asInteger;
      if((f.extension == "flac") && (note > 0) && (layer >= 1) && (layer <= 5), {
        rhodes[note] = rhodes[note] ? Array.newClear(6);
        rhodes[note][layer] = Buffer.read(server, f.fullPath, 0, 480000);
      });
    });
    // higher notes have fewer layers: fill the gaps with the nearest one
    rhodes.keysValuesDo({ arg note, layers;
      (1..5).do({ arg l;
        if(layers[l].isNil, {
          layers[l] = ((l + 1)..5).collect({ arg k; layers[k] }).detect(_.notNil)
            ?? (1..(l - 1)).reverse.collect({ arg k; layers[k] }).detect(_.notNil);
        });
      });
    });
    server.sync;
    ("loops: % Rhodes notes".format(rhodes.size)).postln;

    // the shared vibrato LFO
    vibBus = Bus.control(server, 1);
    SynthDef(\loops_vib, { arg bus, rate = 2.5, depth = 0.5;
      Out.kr(bus, SinOsc.kr(Lag.kr(rate, 0.5)) * Lag.kr(depth, 0.5) * 0.9);
    }).add;
    server.sync;
    vibSynth = Synth.new(\loops_vib, [\bus, vibBus.index], context.xg, \addToHead);

    voices = Group.new(context.xg);
    fx = Group.after(voices);
    fxSynth = Synth.new(\loops_fx, [\out, out, \rev, revBus.index], fx);
    tapeSynth = Synth.new(\loops_tape, [\out, out, \rev, revBus.index, \in, tapeBus.index], fx, \addToHead);

    // note(note, amp, pan, dur, rel): a Rhodes note, the nearest sample transposed,
    // the velocity layer from the level; held for dur seconds (0 = ring out), then
    // damped over rel
    this.addCommand("note", "fffff", { arg msg;
      var note = msg[1], amp = msg[2];
      if(rhodes.size > 0, {
        var centre = rhodes.keys.asArray.minItem({ arg k; (k - note).abs });
        var vel = (amp * 127).clip(1, 127);
        var layer = case { vel < 48 } { 5 } { vel < 73 } { 4 } { vel < 96 } { 3 } { vel < 112 } { 2 } { 1 };
        Synth.new(\loops_rhodes, [\out, out, \rev, revBus.index, \tape, tapeBus.index, \vib, vibBus.index, \buf, rhodes[centre][layer],
          \rate, (note - centre).midiratio, \amp, amp.sqrt * 0.4, \pan, msg[3],
          \dur, msg[4], \rel, msg[5]], voices);
      });
    });

    // vibrato(depth 0..1), vibrato_rate(Hz): the Rhodes' stereo tremolo
    this.addCommand("vibrato", "f", { arg msg; vibSynth.set(\depth, msg[1]) });
    this.addCommand("vibrato_rate", "f", { arg msg; vibSynth.set(\rate, msg[1]) });

    // tape(0..1), tape_time(s), tape_feedback(0..0.95), tape_wear(0..1)
    this.addCommand("tape", "f", { arg msg; tapeSynth.set(\mix, msg[1]) });
    this.addCommand("tape_time", "f", { arg msg; tapeSynth.set(\time, msg[1]) });
    this.addCommand("tape_feedback", "f", { arg msg; tapeSynth.set(\feedback, msg[1]) });
    this.addCommand("tape_wear", "f", { arg msg; tapeSynth.set(\wear, msg[1]) });

    // space(0..1): the reverb's level
    this.addCommand("space", "f", { arg msg; fxSynth.set(\mix, msg[1]) });
  }

  free {
    tapeSynth.free;
    tapeBus.free;
    vibSynth.free;
    vibBus.free;
    rhodes.do({ arg layers; layers.do({ arg b; if(b.notNil, { b.free }) }) });
    voices.free;
    fx.free;
    revBus.free;
  }

}
