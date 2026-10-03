# Combat design: the mockup (as of 2026-09-28)

Everything agreed today, in one place. This is what is being built right now (styles round + M3B). Numbers are placeholders Bryan tunes in `Shared/Data/Combat.luau`, `Config.Combat` and `Config.Npc`.

## 1. A fight, step by step (Fist vs Fist)

*Updated 2026-10-02 (M3-FIX7): the Light/Heavy split is gone. Every hit is a Light.*

1. **Enter the stance.** Press `C`. Your stance idle animation plays so everyone can see you're ready. Outside the stance, clicks do nothing at all (the server refuses attacks too). Knockout drops you out of the stance.
2. **Click = one hit.** Your style's whole chain is one animation, but each hit takes its own click, and the chain **loops**: it never ends on its own while the clicks keep coming. It ends when the defender blocks, parries, dashes away, or hits you first. For Fist: click, the Jab winds up and lands, and the animation freezes on the punch; click again and the Cross winds up and lands, then freezes; click again and it's the Jab again. Click too soon after a hit and the click is remembered and fires when the short gap is over; don't click at all and the combo times out and fades. The server confirms the swing and every continue before anything counts.
3. **Every hit is a Light.** Small damage, no knockback of its own, and a landed hit **light-stuns** the target: they cannot block or parry for a moment, but they can still hit back or dash. Nothing else happens to them: no flinch, no full stun.
4. **Interrupts.** **Any hit that lands on a fighter who is mid-attack interrupts their chain** (a hit still to land, or the chain frozen on a punch waiting for the next click): the swing stops. So if you both swing, whoever lands first breaks the other's chain. A swing is also cut short by a block break, a parry or a knockout (stun, true stun, knocked).
5. **Cancel.** Right-click before the next hit's cancel point. The swing stops, a highlight flashes on you so the enemy knows, and you can act at once: block, hit, or dash (Fist can cancel into anything). Cancelling after you already landed a hit isn't free: your next swing waits a short recovery, so jab-cancel-jab can't out-damage a real chain.
6. **Block and parry.** Hold F to block: hits do no damage but drain the meter (each hit has its own block drain); when it breaks you're true-stunned and open. Tap F just before a hit lands: **parry** (short window, cooldown). The parried attacker is stunned long enough to eat your full chain. Parry beats any hit; a cancel makes a parry whiff.
7. **Knockback.** Never per hit. Your character counts hits taken from any source; on the sixth you're knocked back and the count resets (also resets after a few seconds without being hit).
8. **Knockout.** At 0 health you're knocked out, not killed: down for a few seconds, then up with a quarter health. You can't be hit while down.

## 2. The rock-paper-scissors

| You do | Beats | Loses to |
|---|---|---|
| Keep the chain going (infinite while the clicks come) | a defender who does nothing | a block, a timed parry, a dash out, or a hit of their own landing first (interrupts you) |
| Block-drain (hold block) | a chain with no gaps (every hit costs them time and you only lose meter) | a cancel into a fresh hit once your meter is low |
| Parry | any hit that actually comes | a cancel (your window and cooldown are wasted) |
| Cancel | a defender who parried or blocked on reading your swing | a defender who just waits and hits you back |
| Dash out | a committed chain (resets the exchange) | nothing directly; costs the dash cooldown |
| Hit first | their chain (a landed hit interrupts it) | their block or parry if you were reading it wrong |

Landing a hit light-stuns the target (no block, no parry) and interrupts their swing: their outs are to hit you back, dash away, or the sixth-hit knockback.

## 3. Fighting styles (every weapon is one)

A style = a chain of hits with their own numbers, plus traits. Data only; adding a weapon is adding a table. Timings in `Combat.luau` are **animation-track seconds** (what the animation editor shows); `Config.Combat.ComboSpeed` is the one speed knob that retimes the whole style.

**Fist (the neutral character):** Jab -> Cross, looping. Both hits are identical in stats. Cancel into anything. Normal speed.

**Royal Dagger (light on their feet, bleeds you out):** Stab -> Slash -> Lunge. Every hit is a Light; each adds a **Bleed** stack (damage per second for a few seconds, stacks to three, shown with the old droplets and cut), the Lunge adds two. **Feint Stab:** cancelling automatically throws a stab; if that stab is blocked, the dagger user is stuck half a second and can be punished. The dagger cannot cancel into block, so it has no parry bait; its defence is speed: faster walk and run, shorter dash cooldown. Its timings are placeholders until the Dagger combo animation exists.

Swords, spears and everything else come later on the same rules with their own chains and traits. Skills that make up a style come after that.

## 4. Stance, weapons, unlock

- **Stance key** `C` (config). Attack, block and cancel need the stance; dash and run don't.
- **Weapons:** the style comes from the equipped tool on the server. With a weapon tool equipped, pressing `C` or clicking enters the stance with that weapon, and the click is its first hit. Unequip drops you to Fist. Until the shop exists, `.weapon Fist|Dagger` is the shortcut and the dagger is a visual in the hand.
- **Unlock:** combat is a per-player flag in the part of the save that survives death (`Meta.Unlocks.Combat`): complete the tutorial once and every future life starts with fist combat; a wipe makes a new player. New players start unlocked until the tutorial exists (a config switch); the alley teacher will set it later, and the tutorial stays repeatable. Locked players see "You don't know how to fight yet."
- **Stance animations:** one idle per style, empty placeholders until Bryan makes them.

## 5. Training dummies (dev-spawned now; the tutorial NPC presents them later)

`.dummy spawn <name>`, `.dummy clear`, `.dummy list`. Names over their heads, full health, they get back up, they only fight whoever spawned them or the nearest player.

1. **Straight Sam:** straight chains on a rhythm. Learn to block, then to parry his first hit.
2. **Turtle Tariq:** only blocks. Learn that a held chain breaks block.
3. **Jabbing Jamal:** blocks, then jabs a beat after you start any attack. Learn to cancel into block and parry his jab.
4. **Parry Pete:** parries your first hit. Learn to cancel and land the delayed hit.
5. **Feinting Mohammed:** only feints, super telegraphed. Learn to read the highlight (he cancels his second hit) and punish the re-jab.
6. **Dashing Dalila:** dashes away a beat after you start any attack. Learn spacing and the follow-up after a landed hit.
7. **Sparring Sinbad:** mixes throw, cancel, parry and dash by weights. The exam.

Reaction delays and weights per dummy in `Config.Npc.Trainers`.

## 6. What Bryan supplies

- **Marker names and times per style** in `Config.Combat.Markers` (`Fist`, `Dagger`): with `LogMarkers` on, one swing prints every event name and time to Output, plus the seconds since that hit's own start (hit 1: the swing; hit 2: your second click). Then set each hit's `windupAt`, `cancelUntil` and `hitWindow` in `Combat.luau` to match those "since its start" numbers.
- **Chain pacing** in `Config.Combat.Chain`: `HitGap`, `ClickTimeout`, `Recovery`, `DropRecovery`. `Config.Npc.ContinueDelay` is how fast a dummy throws its own next hit.
- **Animation ids** in `Config.Combat`: `StanceAnimations` (+ `StanceSpeed`), `ComboAnimations` (+ `ComboSpeed`), `MoveAnimations` (block, run, dashes).
- Feel tuning: damage, stun lengths, block drain, parry window and cooldown, knockback count, bleed numbers, dummy reactions.
- Later: the alley teacher, dialogue and the tutorial (M7).

## 7. What the server guarantees (so nothing above can be cheated)

The client only ever sends: enter/leave stance, start attack, "hit marker N reached", cancel, block on/off, dash direction, run on/off. The server decides whether each is allowed and what it hits: right order and time window per hit, geometry in front of the attacker with line of sight, no teleport since the swing, no attacks outside the stance or while stunned, blocked, knocked or recovering, styles derived from equipped tools, and rate limits on every remote.

## 8. Not in this pass

Real weapon tools and buying them (M5), the teacher and tutorial (M7), skills, other weapons, light-stun immunity (revisit after feel), name tags.
