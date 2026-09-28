# Combat design: the mockup (as of 2026-09-28)

Everything agreed today, in one place. This is what is being built right now (styles round + M3B). Numbers are placeholders Bryan tunes in `Shared/Data/Combat.luau`, `Config.Combat` and `Config.Npc`.

## 1. A fight, step by step (Fist vs Fist)

1. **Enter the stance.** Press `C`. Your stance idle animation plays so everyone can see you're ready. Outside the stance, clicks do nothing at all (the server refuses attacks too). Knockout drops you out of the stance.
2. **Click = one swing.** One click starts one animation with your style's whole chain in it. For Fist: a **Light** (the jab) then a **Heavy**. The server confirms the swing before anything plays.
3. **The Light.** Fast, can't be interrupted, no knockback, small damage. If it lands, the target is **light-stunned**: they cannot block or parry for a moment, but they can still jab or dash.
4. **The Heavy.** Its wind-up plays slowed so it's readable. If any hit lands on you during that wind-up, your swing is **interrupted** and stops. If it lands, big damage and a big chunk of the target's block meter.
5. **Cancel.** Right-click before the next hit's cancel point (a Light before its wind-up marker; the Heavy until partway into its wind-up). The swing stops, a highlight flashes on you so the enemy knows, and you can act at once: block, jab, or dash (Fist can cancel into anything). Cancelling after you already landed a hit isn't free: your next swing waits the time the full chain would have taken, so jab-cancel-jab can't out-damage a real chain.
6. **Block and parry.** Hold F to block: lights and heavies do no damage but drain the meter; when it breaks you're true-stunned and open. Tap F just before a hit lands: **parry** (short window, cooldown). The parried attacker is stunned long enough to eat your full chain. Parry beats lights and heavies alike; a cancel makes a parry whiff.
7. **Knockback.** Never per hit. Your character counts hits taken from any source; on the sixth you're knocked back and the count resets (also resets after a few seconds without being hit). Three full fist chains = one knockback.
8. **Knockout.** At 0 health you're knocked out, not killed: down for a few seconds, then up with a quarter health. You can't be hit while down.

## 2. The rock-paper-scissors

| You do | Beats | Loses to |
|---|---|---|
| Straight chain (commit the heavy) | a defender who just blocks (heavy drains and breaks block) | a jab during your heavy wind-up; a timed parry on your light |
| Cancel the heavy into block | the defender who jabbed to interrupt (you parry it and punish) | a defender who waits |
| Jab into their heavy wind-up | their committed heavy | their cancel into block (you get parried) |
| Parry | a light or heavy that actually comes | a cancel (your window and cooldown are wasted) |
| Dash out of the heavy | their heavy (resets the exchange) | nothing directly; costs the dash cooldown |

A landed Heavy does interrupt a Light in progress (heavy overrides). Only jabs can't interrupt a light. No light-stun immunity for now: the outs are jab back, dash, or the sixth-hit knockback.

## 3. Fighting styles (every weapon is one)

A style = a chain of hits, each Light or Heavy with its own numbers, plus traits. Data only; adding a weapon is adding a table.

**Fist (the neutral character):** Jab (Light) -> Heavy. Cancel into anything. Normal speed.

**Royal Dagger (light on their feet, bleeds you out):** Stab (Light) -> Slash (Light) -> Lunge (Heavy). Every light adds a **Bleed** stack (damage per second for a few seconds, stacks to three, shown with the old droplets and cut). The heavy adds two. **Feint Stab:** cancelling the heavy automatically throws a stab; if that stab is blocked, the dagger user is stuck half a second and can be punished. The dagger cannot cancel into block, so it has no parry bait; its defence is speed: faster walk and run, shorter dash cooldown.

Swords, spears and everything else come later on the same rules with their own chains and traits. Skills that make up a style come after that.

## 4. Stance, weapons, unlock

- **Stance key** `C` (config). Attack, block and cancel need the stance; dash and run don't.
- **Weapons:** the style comes from the equipped tool on the server. With a weapon tool equipped, pressing `C` or clicking enters the stance with that weapon, and the click is its first hit. Unequip drops you to Fist. Until the shop exists, `.weapon Fist|Dagger` is the shortcut and the dagger is a visual in the hand.
- **Unlock:** combat is a per-player flag in the part of the save that survives death (`Meta.Unlocks.Combat`): complete the tutorial once and every future life starts with fist combat; a wipe makes a new player. New players start unlocked until the tutorial exists (a config switch); the alley teacher will set it later, and the tutorial stays repeatable. Locked players see "You don't know how to fight yet."
- **Stance animations:** one idle per style, empty placeholders until Bryan makes them.

## 5. Training dummies (dev-spawned now; the tutorial NPC presents them later)

`.dummy spawn <name>`, `.dummy clear`, `.dummy list`. Names over their heads, full health, they get back up, they only fight whoever spawned them or the nearest player.

1. **Straight Sam:** straight chains on a rhythm. Learn to block, then to parry his light.
2. **Turtle Tariq:** only blocks. Learn that heavies break block.
3. **Jabbing Jamal:** jabs into your heavy wind-up. Learn to cancel into block and parry his jab.
4. **Parry Pete:** parries your first light. Learn to cancel and land the delayed hit.
5. **Feinting Mohammed:** only feints, super telegraphed. Learn to read the highlight and punish the re-jab.
6. **Dashing Dalila:** dashes out of heavies. Learn spacing and the follow-up after a landed light.
7. **Sparring Sinbad:** mixes throw, cancel, parry and dash by weights. The exam.

Reaction delays and weights per dummy in `Config.Npc.Trainers`.

## 6. What Bryan supplies

- **Marker names and times per style** in `Config.Combat.Markers` (`Fist`, `Dagger`): with `LogMarkers` on, one swing prints every event name and time to Output. Then set each hit's `windupAt`, `cancelUntil` and `hitWindow` in `Combat.luau` to match.
- **Stance idle animation ids** in `Config.Combat.StanceAnimations`.
- Feel tuning: damage, stun lengths, block drain, parry window and cooldown, knockback count, bleed numbers, dummy reactions.
- Later: the alley teacher, dialogue and the tutorial (M7).

## 7. What the server guarantees (so nothing above can be cheated)

The client only ever sends: enter/leave stance, start attack, "hit marker N reached", cancel, block on/off, dash direction, run on/off. The server decides whether each is allowed and what it hits: right order and time window per hit, geometry in front of the attacker with line of sight, no teleport since the swing, no attacks outside the stance or while stunned, blocked, knocked or recovering, styles derived from equipped tools, and rate limits on every remote.

## 8. Not in this pass

Real weapon tools and buying them (M5), the teacher and tutorial (M7), skills, other weapons, light-stun immunity (revisit after feel), name tags.
