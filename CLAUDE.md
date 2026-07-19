# fast-fashion

A World of Warcraft addon: a collection-aware transmog set gallery. `SPEC.md` is the
product brief and the reference for the client APIs the addon depends on — read it before
changing behaviour, and keep its "Implementation status" table honest.

Lua 5.1 / LuaJIT semantics — the game client has no LuaRocks, no `require`, and no standard
library beyond what Blizzard exposes.

## Git workflow

Commit and push straight to `main`. Do not create a feature branch or open a PR unless
explicitly asked — this is a solo addon repo and the branch-then-merge round trip is pure
overhead here.

## Checks

`./scripts/check.sh` runs luacheck then busted. It must report zero warnings and zero
failures before committing. Luacheck caps lines at 120 characters, and new WoW API globals
have to be declared in `.luacheckrc` or it fails the build.

A run that is not fully green is not a finished piece of work. Leaving lint warnings, test
failures, or errors behind — whether they predate the change, were caused by it, or "only"
affect tests you did not write — is never acceptable. Fix every one of them, or stop and
say plainly which you could not fix and why. Do not report work as done while
`./scripts/check.sh` exits non-zero, and do not silence a problem by deleting or weakening
the test that found it.

## Structure

Every file under `src/` is loaded by the client in the order listed in `fast-fashion.toc`;
a file missing from the .toc fails the test suite as well as the game. Modules are
`ns.newThing(deps)` factories returning a table of closures.

`Main.lua` is the only place allowed to touch WoW globals. It collects them into a `WowEnv`
table and injects it, so `src/` modules stay drivable from the fakes in
`spec/helpers/fake_wow.lua` without monkey patching.

Keep frame code thin and push logic into a pure module beside it — the pure module is where
the tests earn their keep.

## Domain rules that are easy to get wrong

The canonical identity of an outfit slot is its **visual appearance ID** (`visualID`), never
a sourceID or itemID. Blizzard's `itemModifiedAppearanceID` is a *sourceID* despite the
name, and `GetSetPrimaryAppearances().appearanceID` is also a sourceID. Resolving a source
to its visual is what lets a Rogue wear a Druid set.

A set's `validForCharacter` / `classMask` answer the *original* restriction only. They are
metadata, never the wearability answer — see `SPEC.md`, "Definitions".

Client data streams in asynchronously. When an API returns `nil`, the piece is *unresolved*,
not *missing*; the two must stay distinguishable all the way through the model.
