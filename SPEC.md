# Fast Fashion — Collection-Aware Transmog Set Gallery

## Objective

Extend the in-game transmog experience with a browsable gallery of appearance sets,
built on the game's own wardrobe, appearance and dressing-room systems rather than a
custom model renderer.

The first release must let a player:

1. Browse all named transmog sets exposed by the game.
2. Filter sets by whether the current character can reproduce and wear the complete
   appearance.
3. Sort sets by number of missing appearances.
4. Select a set and apply it to the existing transmog preview with one click.

## Product thesis

The differentiating behaviour is:

> Browse complete visual outfits on the current character, independently of the class
> restrictions attached to the original named set, and understand how close the account
> is to reproducing each outfit.

WoW contains many officially named appearance sets — raid, PvP and class sets. Some are
nominally class-restricted, but their *visual appearances* are often also available from
unrestricted items of the same armour type. A Druid tier set may be visually reproducible
by a Rogue if unrestricted leather items exist for every appearance. The default
Collections UI gives the Rogue no convenient way to browse that Druid set as a complete
outfit.

The long-term direction is Blizzard sets plus lookalike/recolour sets, community-submitted
outfits, collection-aware filtering, and acquisition guidance — with static community data
shipped in the addon and GitHub as the submission mechanism. No backend for the first
versions. The MVP establishes the data model and abstractions for that direction without
building it.

## MVP scope

### 1. Browse all Blizzard-defined named sets

Display all named transmog sets exposed through the client APIs. Each displayed set should
include, where available: name, set ID, base set ID, description/label, expansion, patch,
original class restriction, faction restriction, number of appearance slots, appearances
collected, appearances missing, and whether the current character can reproduce the
complete set.

Variants and recolours are associated by `baseSetID`. The MVP may render variants as
independent rows, but the internal model retains the family relationship.

### 2. "Can I wear it?" filtering

Filters: **All sets**, **Can wear complete set**, **Cannot wear complete set**.

"Can wear complete set" means: for every required visual appearance in the set, at least
one source exists that the current character can use for transmog. This is *not* the same
as the set's original class restriction. The calculation operates on visual appearances and
their available sources, not solely on the item IDs in the Blizzard set.

A set therefore carries separate states:

```
originallyValidForCharacter  = false
visuallyReproducibleByCharacter = true
fullyCollected               = false
missingCount                 = 2
```

The UI uses `visuallyReproducibleByCharacter` for the filter.

### 3. Sort by missing pieces

Sort by number of uncollected required appearances, both directions (fewest first, most
first). A missing piece is a required visual appearance for which the account has not
collected any compatible source. Where several set entries occupy the same inventory slot,
use the appearance belonging to the selected variant.

Rows show a compact progress indicator:

```
Thunderheart Regalia
6 / 8 collected
2 missing
Wearable by Rogue
```

Fully collected sets have a missing count of zero.

### 4. Apply to transmog preview

Selecting a set offers a primary action, **Preview Set**, which:

1. Resolves each visual appearance to an appropriate source for the current character.
2. Prefers a collected and usable source.
3. Falls back to a usable but uncollected source for preview, if the game permits it.
4. Applies each resolved source to the corresponding inventory slot.
5. Leaves the player in control of committing and paying for the transmog.

The addon **must not** automate the final purchase or confirmation. If a slot cannot be
resolved, apply all resolvable slots and clearly indicate which were skipped.

## Core data model

A common outfit model that can later carry both Blizzard sets and community outfits.

```lua
---@class Outfit
---@field id string
---@field origin "blizzard" | "community"
---@field name string
---@field description string?
---@field blizzardSetID number?
---@field baseSetID number?
---@field expansionID number?
---@field patchID number?
---@field classMask number?
---@field requiredFaction string?
---@field tags string[]
---@field slots table<number, OutfitSlot>

---@class OutfitSlot
---@field inventorySlot number
---@field appearanceID number
---@field preferredSourceID number?
---@field preferredItemID number?
```

The canonical identity of a slot is its **visual appearance ID**. Specific source or item
IDs are implementation details used to reproduce or preview the appearance.

Character-specific derived state is never persisted in the canonical outfit:

```lua
---@class ResolvedOutfit
---@field outfit Outfit
---@field wearable boolean
---@field collectedCount number
---@field missingCount number
---@field totalCount number
---@field slots table<number, ResolvedOutfitSlot>

---@class ResolvedOutfitSlot
---@field appearanceID number
---@field resolvedSourceID number?
---@field collected boolean
---@field usable boolean
---@field missing boolean
```

## Architecture

Provider abstractions let community outfits be added later without rewriting the gallery.

```lua
---@class OutfitProvider
---@field GetOutfits fun(self): Outfit[]
---@field GetOutfit fun(self, id: string): Outfit?

local providers = { BlizzardSetProvider }
```

Modules and responsibilities:

| Module | Responsibility |
| --- | --- |
| `BlizzardSetProvider` | Read named sets from Blizzard APIs; convert to `Outfit`; preserve base/variant relationships; avoid duplicating game-supplied data. |
| `AppearanceResolver` | For an appearance ID + current character: find all sources, determine which are usable, which usable ones are collected, choose the preferred source for preview, cache the result. |
| `CollectionResolver` | For an outfit: resolve all slots, compute collected/missing counts and complete-set wearability, return a `ResolvedOutfit`. |
| `GalleryController` | Own active filters and sort order; request resolution when needed; avoid resolving the full item-source graph at startup. |
| `GalleryView` | Render list, progress, wearability; expose filter/sort controls and the preview action. |
| `TransmogPreview` | Apply resolved source IDs to the existing dressing-room/transmog preview; isolate all dependencies on Blizzard UI internals; fail gracefully when the Blizzard UI addon is not loaded. |
| `Cache` | Session-scoped memoisation of resolution results. |

## Client API reference

Signatures verified against the live client API (warcraft.wiki.gg, 2026-07). Two differ
from the original brief and the differences are load-bearing.

### `C_TransmogSets.GetAllSets() -> TransmogSetInfo[]`

Fields: `setID`, `name`, `baseSetID?`, `description?`, `label?`, `expansionID`, `patchID`,
`uiOrder`, `classMask`, `hiddenUntilCollected`, `requiredFaction?`, `collected`,
`favorite`, `limitedTimeSet`, `validForCharacter`, `grantAsPrecedingVariant`.

> **Deviation from brief:** `requiredFaction` is a *string* (`"Alliance"` / `"Horde"` /
> `nil`), not a number. The `Outfit` model carries it as `string?`.

`classMask` is a bitmask, `0x1` Warrior through `0x1000` Evoker. `validForCharacter` is
the game's own answer to the *original* restriction — it maps to
`originallyValidForCharacter` and is explicitly **not** the wearability answer.

### `C_Transmog.GetAllSetAppearancesByID(setID) -> TransmogSetItemInfo[]?`

Fields per entry: `itemID`, `itemModifiedAppearanceID`, `invSlot`, `invType`.

> **Deviation from brief:** `itemModifiedAppearanceID` is a **sourceID**, not a visual
> appearance ID. Resolving it to a visual requires `GetSourceInfo().visualID`. This is the
> difference between "the exact item Blizzard shipped" and "the look" — and the whole
> product rests on the latter.

May return `nil` while item data streams in.

### `C_TransmogCollection.GetSourceInfo(sourceID) -> AppearanceSourceInfo?`

Relevant fields: `visualID` (the canonical appearance ID), `sourceID`, `itemID`,
`isCollected`, `invType`, `inventorySlot?`, `categoryID?`, `playerCanCollect`,
`isValidSourceForPlayer`, `canDisplayOnPlayer`, `useError?`, `useErrorType?`,
`meetsTransmogPlayerCondition?`, `isHideVisual?`.

`isValidSourceForPlayer` is the primitive behind wearability; `isCollected` is the
primitive behind collection state. `canDisplayOnPlayer` gates preview fallback.

### `C_TransmogCollection.GetAppearanceSources(appearanceID) -> AppearanceSourceInfo[]`

The alternative-source lookup that makes a Druid set wearable by a Rogue.

### `C_TransmogSets.GetVariantSets(transmogSetID) -> TransmogSetInfo[]`

May return nothing. `baseSetID` from `GetAllSets` is sufficient for MVP grouping, so the
provider groups on that and does not call this per set.

## Definitions

**Collected** — an appearance slot counts as collected when the account owns at least one
source that provides the required visual appearance *and* can be used by the current
character for transmog. Owning a source the current character cannot use does not satisfy
character-specific collected state. Account-wide ownership may additionally be retained for
a future "Collected on account, unusable by this character" state (optional for MVP).

**Wearable** — a set is wearable when every required slot has at least one appearance
source usable by the current character. The calculation considers armour type, class,
race and faction restrictions, weapon proficiency, and any transmog-specific restrictions
exposed by the client. The original set's class mask is *informative metadata, not the
final answer*.

## Loading and performance

Do not eagerly resolve every source for every appearance at login.

1. Load the addon core normally.
2. Query lightweight set metadata when the gallery is first opened.
3. Resolve detailed appearance/source information only for visible rows, the selected set,
   and sets required by the active sort or filter.
4. Cache appearance-resolution results for the session.
5. Process large batches incrementally across frames if synchronous resolution stalls.

Official set data is queried from Blizzard at runtime, never committed as generated Lua or
YAML.

Future community data ships as separate load-on-demand packages grouped by armour type
(`FastFashion_Data_Cloth`, `_Leather`, `_Mail`, `_Plate`). Not implemented in the MVP, but
no architectural decision may preclude them.

## UI direction

Integrate with the existing Collections/Wardrobe interface: a Gallery tab or button near
the transmog sets UI, reusing Blizzard visual components where practical. One main
character model preview — no animated model per row. Rows are text, icons and progress.

```
Filter: [ All ] [ Can wear ] [ Cannot wear ]
Sort:   [ Missing: low to high ] [ Missing: high to low ]
```

Row: set name, original class or armour context, collected / total, missing count,
wearable status.

Selected-set detail: name, variant, collection progress, wearability, missing slots,
`[ Preview Set ]`.

Keep Blizzard-frame integration behind adapter modules so patch changes stay isolated.

## Error handling

Handle: APIs returning `nil` while item information loads; source information not yet
cached by the client; sets with incomplete or unusual slot data; hidden sets; empty sets;
duplicate inventory slots; sources that exist but cannot be previewed; Blizzard UI modules
not yet loaded; API changes between patches.

Where data is temporarily unavailable, **queue a retry rather than classifying the piece as
permanently missing**. Log diagnostics behind a debug flag.

## Testing approach

Game API calls stay behind injectable adapters so the suite runs outside WoW against
mocked responses.

```lua
---@class TransmogAPI
---@field getAllSets fun(): TransmogSetInfo[]
---@field getSetAppearances fun(setID: number): TransmogSetItemInfo[]?
---@field getSourceInfo fun(sourceID: number): AppearanceSourceInfo?
---@field getAppearanceSources fun(appearanceID: number): AppearanceSourceInfo[]?
```

Cover at least: conversion of Blizzard sets into outfits; grouping of variants by base set;
a class set with unrestricted lookalike sources; fully collected outfit; partially collected
outfit; outfit with no compatible source for one slot; sorting by missing count; filtering
by complete wearability; preferred resolution of collected sources; graceful handling of
unavailable item data.

## MVP acceptance criteria

1. Opening the gallery displays Blizzard-defined named transmog sets.
2. A player can filter to sets completely wearable by the current character.
3. Wearability accounts for unrestricted lookalike sources rather than trusting the
   original set class restriction.
4. A player can sort sets by missing appearance count in both directions.
5. Each row displays collected count, total appearance count and missing count.
6. Selecting a set shows its slot-level resolution state.
7. **Preview Set** applies the resolved outfit to the game's existing transmog or
   dressing-room preview.
8. The final transmog purchase remains a manual player action.
9. Source resolution is cached and does not cause a significant login-time stall.
10. The outfit-provider architecture can later accept static community outfits.

## Out of scope for the MVP

Community submissions; GitHub PR generation; user-authored tags; ratings, likes or
comments; external websites or services; screenshots; farming routes; drop-rate databases;
saved favourites; outfit sharing through chat; Better Wardrobe or All The Things
integration; community data addon packages; automated transmog purchase; automatic
equipment changes; a custom 3D renderer.

## Future direction

- **Community outfit provider** — static outfits generated from repository submissions,
  registered alongside `BlizzardSetProvider`. Submissions use appearance IDs and optional
  preferred source IDs.
- **Submission export** — build an outfit in-game and export a compact payload or YAML
  document suitable for a GitHub issue or pull request.
- **Load-on-demand data** — `C_AddOns.LoadAddOn("FastFashion_Data_Leather")`.
- **Rich filtering** — fully collected; one/two/three pieces missing; armour type; class,
  race and faction compatibility; expansion; content source; colour; theme; creator tags.
- **Acquisition guidance** — per missing appearance, list compatible source items with the
  game-provided source description, indicate boss/raid/dungeon/vendor/quest/achievement,
  prefer easier or already-accessible alternatives, and group pieces obtainable from the
  same activity.
- **Social layer** — only if there is demonstrated demand for live submissions, likes,
  comments, popularity rankings, creator profiles or immediate content updates. The static
  Git repository and addon releases remain the default distribution mechanism.

## Implementation status

| Capability | Status |
| --- | --- |
| 1. Browse Blizzard-defined named sets | Implemented (`src/BlizzardSetProvider.lua`) |
| 2. "Can I wear it?" filtering | Not started |
| 3. Sort by missing pieces | Not started |
| 4. Apply to transmog preview | Not started |
