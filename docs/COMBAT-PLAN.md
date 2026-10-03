# Combat plan: the loop from the top (draft for Bryan, 2026-10-02)

> **SHELVED (Bryan, 2026-10-03).** Not approved, nothing below is built. Bryan's call: the current combat "doesn't feel right and we are stacking issues on issues"; combat will be erased and redesigned from the top as its own milestone **after everything else is complete**. What's on main stays as-is (playable, stable) until then. Nobody builds on it in the meantime; combat bugs get logged, not fixed, unless they break something outside combat.

Where combat stands after M3-FIX7 (every hit a Light, any landed hit interrupts, the chain loops forever while the clicks come) and what the next round should change. Numbers are proposals; you tune them in `Shared/Data/Combat.luau` and `Config.Combat`. Nothing here is built until you approve it.

## 1. The loop, as it should play

1. **Attack:** click, click, click. Jab, Cross, Jab, Cross... one animation, one click per hit, frozen on each punch until the next click. It never ends on its own.
2. **A landed Jab stuns the target through the Cross.** The Jab's light-stun is just long enough that the Cross cannot be blocked or parried. **The Cross applies no stun.** So after every Cross there is a short gap before the next Jab lands, and that gap is the defender's whole game. Today every hit refreshes a 0.9 s stun, so a defender who takes one Jab can never block or parry again: that is the bug this plan fixes. The rhythm reads as "ta-TA (gap) ta-TA (gap)", and the gap is where you act.
3. **In the gap the defender picks one:**
   - **Parry:** tap F so the window covers the next Jab. Smaller window than today. If the Jab arrives, the attacker is stunned long enough to eat one pass (Jab, Cross), not a whole chain.
   - **Block:** hold F. Every hit drains block meter, no damage; the block breaks after enough hits (true stun, 3 s). Chaining into a block is a real plan for the attacker, so the blocker has to parry or leave before it breaks.
   - **Hit first:** your own Jab landing interrupts their chain (any landed hit interrupts). Trading is a race to land first.
   - **Dash out:** resets the exchange, costs the dash cooldown.
4. **The attacker's answer to a parry is the cancel.** Right-click pulls the punch back before it lands (any time before the hit, no longer only in the first few frames). The parry window and its cooldown are wasted, and the attacker resumes the chain into what is now just a block, draining it. A cancel costs a short beat before the next swing so it is not free. Everyone sees it: the character fills with the cancel colour, the click sound plays, and the fill fades out fast.
5. **The valve:** the sixth hit taken knocks the target back and resets the count. So "click them to death" always has a reset every three passes, and the attacker has to close distance again. Keep it.
6. **Knockout** at 0 health, up again with a quarter health. Unchanged.

## 2. Who beats whom

| You do | Beats | Loses to |
|---|---|---|
| Keep chaining | a defender who does nothing; a defender who only blocks (drain, then break) | a parry on the Jab; a hit that lands first; a dash out |
| Parry (tap F before the Jab) | the Jab that actually comes (attacker stunned for a pass) | a cancel (window and cooldown wasted, you are left blocking) |
| Cancel (right-click) | a defender tapping F to parry | a defender who just blocks or dashes (you paid the beat for nothing) |
| Hit first | their chain (interrupt) | their parry; their block |
| Dash out | the chain (reset) | nothing directly; costs the cooldown |

## 3. Numbers to change (proposal)

| What | Today | Proposed | Why |
|---|---|---|---|
| Jab `lightStun` | 0.9 | 0.65 | Long enough to cover the Cross (lands about 0.57 s after the Jab at speed 1.5), short enough to end before the next Jab |
| Cross `lightStun` | 0.9 | 0 | Opens the gap after every Cross |
| Jab `cancelUntil` (track s) | 0.05 | 0.35 | Cancel possible until just before the punch; today a Jab is effectively uncancellable |
| Cross `cancelUntil` (track s) | 0.5 | 0.85 | Same |
| `Combat.Block.parryWindow` | 0.25 | 0.18 | "Not just parry merchant": you have to time it |
| Parry stun on the attacker | 1.5 (half of breakStun) | new `Combat.Block.parryStun` = 1.1 | The reward is one pass, not a whole chain; its own number instead of a derived one |
| `Config.Combat.Chain.CancelRecovery` | uses Recovery 0.25 | own knob, 0.3 | The cancel's cost, tunable on its own |
| `Config.Combat.CancelFlashSeconds` | 0.25 (on/off) | 0.35 fade | Fill highlight tweens out instead of blinking |
| Knockback `everyHits` | 6 | 6 | Keep as the valve; raise later if it cuts chains too often |
| Block `blockDrain` per hit | 15 | 15 | 7 hits to break: about two passes and a Jab. Fine for now |

## 4. Feedback the player needs

- **Cancel:** fill highlight (not outline only), the click sound, fast fade. Client only.
- **Light-stun:** nothing new for now. If you cannot tell when you are stunned, a brief flinch on the Jab (the hit that disables your block) is the smallest honest signal. The Cross would stay flinch-free so the gap is readable. Your call.
- **Quest beacon:** the courier highlight fades in and out over about 0.6 s instead of popping. Client only, same task.

## 5. The trainers under these rules (no changes needed)

Sam chains on a rhythm: learn to block, then parry his Jab. Tariq only blocks: learn that chaining breaks a block. Jamal counter-jabs when you swing: learn that landing first wins. Pete parries your first hit: learn the cancel. Mohammed feints: learn not to parry the fake. Dalila dashes: learn spacing. Sinbad mixes everything.

## 6. Tasks (after your approval)

| ID | Owner | Scope |
|---|---|---|
| M3-FIX8-S | server-builder (cloud) | The numbers in section 3; `parryStun` as its own field; `CancelRecovery`; self-tests for "Cross applies no stun", "parry stun is one pass", "cancel accepted until the punch"; COMBAT-DESIGN.md sections 1-3 rewritten from this plan |
| M3-FIX8-C | client-builder (cloud) | Cancel: fill highlight + click sound + fade; courier beacon fade in/out; nothing else |
| Review | Sonnet, cloud | Both branches |
| Later | Opus, cloud | The full combo package review (FIX5 to FIX8) once the feel settles |

## 7. Open questions (one at a time)

1. Flinch on the Jab, or no flinch at all?
2. Should a parry while light-stunned be impossible (today) or just late? Today is right for this plan; confirming.
