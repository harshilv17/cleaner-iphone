# Storage Cleaner iOS — build plan

> **Status 2026-09-22.** Project scaffolded with xcodegen, **builds clean** and runs on
> the iPhone 17 Pro Max simulator. All five must-have features are written:
> storage dashboard, screenshots, large videos, similar photos, duplicate contacts,
> plus the review gate and all three permission states for both frameworks.
>
> Verified: the app launches, reads real device capacity, and the permission gate,
> analyze-first toggle and dark teal styling render correctly.
> The similarity threshold was measured rather than guessed — near-identical frames
> score 0.01–0.12, unrelated images 0.79–0.89, so the 0.3 cutoff has a wide margin.
>
> **Not verified: everything that touches a real photo library.** `simctl privacy`
> does not move PhotoKit's readWrite status on this simulator, so the scan, grouping,
> selection and delete paths have only been compiled, not run against photos.
> That needs the iPhone.
>
> Next: run on device from Xcode (set a signing team first), then the screen
> recording and the 150-word note.

Assignment: AppFactory "App Builder Intern" selection task. Brief received 2026-09-21,
5 days allowed → **due ~2026-09-26**. Submit to bharat7888@gmail.com.

Reference app: Cleanup: Phone Storage Cleaner. We copy the *problem*, not the branding.

---

## 0. Blockers to clear before any code

| Blocker | State | Action |
|---|---|---|
| Xcode | **Not installed** — only Command Line Tools present | Install Xcode 27 from App Store (~15 GB, slow). Do this first, in the background. |
| Real iPhone | Required by brief ("simulator has almost no photos") | Need a device on iOS 18+, ideally with a messy library. |
| Signing | Free Apple ID works, 7-day provisioning | TestFlight needs the $99 Developer Program. Brief says TestFlight is optional ("if you have one") — skip unless already enrolled. |
| Test library | Evaluators judge scan speed "on a large library" | If the test iPhone is clean, seed a few thousand photos before recording. |

Current platform as of today: iOS 27 / Xcode 27. Brief asks iOS 17+.
**Decision: minimum deployment iOS 18.0.** Reason: the modern Swift Vision API,
`CalculateImageAestheticsScoresRequest` (free blur/quality scoring), limited-contacts
authorization, and `@Observable` all land in 18. iOS 17 buys nothing and costs
back-compat branches.

---

## 1. Architecture

SwiftUI, Swift 6 strict concurrency, **zero third-party dependencies**. Single app target.

```
StorageCleaner/
  App/            entry, routing, theme
  Services/
    DeviceStorage.swift     capacity numbers
    PhotoLibrary.swift      PhotoKit fetch / delete
    Similarity.swift        Vision feature prints + clustering
    ContactsService.swift   fetch / cluster / merge
    FeaturePrintCache.swift SwiftData cache
  Features/
    Dashboard/      home: storage ring + category cards
    SimilarPhotos/  groups, best-shot preselected
    Screenshots/    grid, select-all
    LargeVideos/    list sorted desc, preview
    DuplicateContacts/
    Review/         the single delete gate
  Models/
```

Every scanner conforms to one protocol returning `[CleanupCandidate]` (asset id, bytes,
category, group id, preselected). The Review screen and the dashboard are generic over
that — one delete path, one place for the safety check.

---

## 2. Feature-by-feature: how each is actually built

### 2.1 Storage dashboard
```swift
let v = try URL.homeDirectory.resourceValues(forKeys: [
    .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
```
`volumeAvailableCapacityForImportantUsage` is the right key — it accounts for purgeable
space, which is what the user experiences as "free".

**Known limitation, must be stated in the UI, not hidden:** no API returns exactly what
Settings shows (partitioning and system overhead differ). Label it "approximate".
Per-category reclaimable = bytes our own scans found, streamed in as they finish.

### 2.2 Similar photos — the hard part, and where the grade is won

Naive approach (compare every photo to every other) is O(n²): 20k photos = 200M
comparisons. Dead on arrival. Pipeline instead:

1. **Fetch lazily.** `PHAsset.fetchAssets` sorted by `creationDate`. Never materialise
   the whole library into an array of models.
2. **Cheap exact-duplicate pass.** Bucket by `(pixelWidth, pixelHeight, creationDate
   rounded to the second, byte size)`. Exact dupes fall out for free, no pixels read.
3. **Window the expensive pass.** Near-identical shots are bursts — seconds apart. Sort
   by date, compare each asset only against neighbours inside a ±2 minute / 20-asset
   window. Turns O(n²) into O(n·k). *This is the single decision that makes the scan
   fast.*
4. **Feature prints.** `GenerateImageFeaturePrintRequest` on a small thumbnail
   (~300px, `deliveryMode = .fastFormat`, `resizeMode = .fast`).
   `isNetworkAccessAllowed = false` — **never** pull originals down from iCloud; that
   would be slow, costly, and on a metered connection, rude.
5. **Cluster** with union-find over pairs whose `computeDistance` is under threshold
   (~0.2 near-identical, ~0.4 loosely similar). Threshold is a tunable constant with a
   debug slider — this needs calibration against a real library, not a guess.
6. **Cache** each feature print as a blob keyed by `localIdentifier + modificationDate`
   (SwiftData). Cold scan is slow once; every later scan is near-instant. Evaluators
   rescan.
7. **Concurrency:** `withTaskGroup`, bounded to `activeProcessorCount`. Vision runs on
   the Neural Engine.

**Best shot in each group:** `CalculateImageAestheticsScoresRequest` (iOS 18+) returns
an aesthetics score *and* an `isUtility` flag — Apple already solved "which of these is
the good one". Tie-break on file size. Preselect the rest, never auto-delete.

### 2.3 Screenshots
`PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .smartAlbumScreenshots)`.
The system already maintains this album — one fetch, no detection logic. Grid + select-all
+ date sections.

### 2.4 Large videos
Fetch `.video`, sort by size desc. **Gotcha:** `PHAsset` has no public size property.
```swift
PHAssetResource.assetResources(for: asset).first?.value(forKey: "fileSize") as? Int64
```
is KVC on an undocumented key — the universally used approach, but fragile. Wrap it, and
fall back to `AVURLAsset` / `PHAssetResourceManager` byte count when it returns nil.
Preview: thumbnail in the row, tap for `requestPlayerItem` inline playback.

### 2.5 Duplicate contacts
- Enumerate with **`unifyResults = false`**. Critical: the default unifies linked
  contacts, and deleting a unified contact deletes every linked record behind it.
- Cluster by union-find on: normalised name (casefold, strip diacritics/punctuation),
  last 9 digits of any phone number, lowercased email.
- **There is no public merge/unify API.** Merge by hand: build a `CNMutableContact` that
  unions labelled values deduped by normalised value, keep the richest name and the
  image, then `CNSaveRequest.update(merged)` + `.delete(each other raw contact)`.
- Contacts in read-only containers (Exchange, some Google accounts) refuse deletion —
  catch per-contact and report, don't fail the batch.

### 2.6 Review before delete — the safety gate
One screen. Grouped by category, thumbnails, total bytes, everything removable before
committing. Nothing is deleted anywhere else in the app.

Two facts that the UI must be honest about, because both are counterintuitive:

1. **iOS shows its own "Delete N Photos?" sheet** on `PHAssetChangeRequest.deleteAssets`,
   and returns success only if the user confirmed. So: batch *every* photo deletion into
   **one** `performChanges` call — one sheet, not one per photo.
2. **Deleting does not free space.** Assets go to *Recently Deleted* for 30 days. If the
   app claims "4.2 GB freed" the storage number won't move and the app looks broken.
   Say "4.2 GB will be freed once you empty Recently Deleted", and put a button that
   opens Photos there. Most competitors get this wrong; it directly serves evaluation
   criterion #2 (safe) and #5 (decisions).

Contacts have no system confirmation sheet — our own dialog is the only guard, so it
names the count and is explicit.

### 2.7 Permissions
- Photos: `PHPhotoLibrary.requestAuthorization(for: .readWrite)`.
  - `.limited` must **work**, not break: scan the selected subset, show a banner, offer
    `presentLimitedLibraryPicker` to add more.
  - `.denied`: explain what is lost, deep-link to Settings.
- Contacts: `CNContactStore.requestAccess(for: .contacts)` — iOS 18 added *limited*
  contact access, so handle that state too.
- `Info.plist` usage strings state the reason plainly (brief asks for "a clear reason").

---

## 3. Performance targets (state these in the note)

| Scenario | Target |
|---|---|
| Cold scan, 20k photos | < 90 s, results streaming in from the first second |
| Warm scan (cache hit) | < 5 s |
| Memory | < 300 MB — thumbnails only, never full images |
| Blocking spinners | none; every list populates progressively |

---

## 4. Five-day schedule

- **Day 1** — Xcode installing in the background. Project skeleton, permissions flow
  (all three states), storage dashboard, screenshots list. Ship the cheapest real feature
  first so there is a working app on day one.
- **Day 2** — Similarity engine: thumbnails, feature prints, windowed comparison, cache,
  group UI with best-shot preselection. The risky day; it gets the whole day.
- **Day 3** — Large videos + duplicate contacts and merge.
- **Day 4** — Review + delete gate, Recently Deleted honesty, empty/denied/limited
  states, app name, icon, visual pass.
- **Day 5** — Real-device testing on a large library, fix what breaks, 2–3 min screen
  recording, <150-word note, repo push.

Bonus list is touched only if day 4 ends early. Cheapest bonuses given what is already
built: **blurry photo detection** (the aesthetics request already returns it) and the
**"space freed" summary screen**. Skip the vault, widget, calendar cleanup.

---

## 5. Risks

| Risk | Mitigation |
|---|---|
| Xcode install eats day 1 | Start the download before anything else |
| iCloud-optimised library — originals not on device | `isNetworkAccessAllowed = false` everywhere; operate on thumbnails; show a note when an asset is cloud-only |
| KVC `fileSize` returns nil on some assets | Fallback path to `AVURLAsset` / resource byte count |
| Similarity threshold wrong on a real library | Debug slider, calibrate on device on day 5 |
| Space doesn't drop after delete → looks broken | Explained in UI + Recently Deleted shortcut |
| No paid dev account → no TestFlight | Brief allows it; submit repo + recording |
| Contacts in read-only containers | Per-contact error reporting |

---

## 6. Out of scope (brief says so — do not build)

Payments, subscriptions, paywalls, free trials · email cleaning · other apps' caches or
junk (iOS forbids it — do not even promise it in the UI) · login/cloud sync · iPad,
Watch, Mac.

---

## 7. Naming

Needs an original name, logo and design — explicitly must not resemble Cleanup's.
Candidates: **Declutter**, **Roomy**, **Spacer**, **Tidy**, **Purge**, **Slate**.
One SF-Symbol-derived mark, one accent colour, dark-first. Nothing that mimics the
reference app's palette or icon.

---

## 8. Decisions locked — 2026-09-22

### Environment (verified, not assumed)

| Thing | Reality |
|---|---|
| Test device | iPhone 17, **iOS 26.6.2** |
| Mac | macOS 27 |
| Xcode | **26.6, already installed** at `/Applications/Xcode.app`, iOS 26.5 SDK. `xcode-select` is pointed at CommandLineTools — fix with `sudo xcode-select -s /Applications/Xcode.app`. No download needed. |
| Xcode 27.1 beta | Sitting unused in `~/Downloads` (3.6 GB unpacked + 1.9 GB `.xip`). Not needed for this. |

Deployment target stays **iOS 18.0** — builds against the 26.5 SDK, runs on the 26.6.2
device, keeps the modern Vision API and limited-contacts handling. Brief's floor is 17.

### Zero-cost constraint

No paid Apple Developer Program, no paid APIs. Everything in this plan already complies:
PhotoKit, Vision, Contacts and the storage APIs are free system frameworks, all on-device.
Nothing leaves the phone, which the brief demands anyway.

What free signing means in practice:

- **Free Apple ID provisioning works** for installing on your own iPhone from Xcode.
- The build **expires after 7 days** — reinstall from Xcode to renew. Record the demo
  video while it is live.
- **No TestFlight** (that needs the $99 program). The brief calls TestFlight optional
  ("if you have one"), so the submission is repo + screen recording + note.
- Entitlements a free team cannot use — push, App Groups, CloudKit — are not used here.

### Name

**Cleaner.** Note the reference app is "Cleanup: Phone Storage Cleaner", so the name sits
close. The brief only forbids copying their branding, artwork and text — a generic English
word is fine, but the icon, colour and layout must be visibly our own, not a recolour of
theirs.

### Analyze-first, delete-never-by-default

Your constraint: find what is eating the phone's storage **without having to delete real
photos**. The brief's constraint: the core loop must actually work end to end, and that is
evaluation criterion #1.

Both hold at once:

1. **Analyze mode is the default.** The app scans, groups and reports — every screen is a
   report with a running "you could reclaim X GB". The Clean button stays hidden until
   you flip a switch in settings.
2. Nothing is ever preselected *for deletion*. Within a similar-photo group the best shot
   is marked (the brief asks for that), but a group is only acted on once you tick it.
3. **The delete path is fully built and real** — one batched `performChanges`, the system
   confirmation sheet, the review gate. It is exercised, not stubbed.
4. **Demo it on throwaway assets.** Take a dozen junk screenshots and burst shots on the
   phone an hour before recording, then delete exactly those on camera. Real deletion,
   real system sheet, real "space freed" panel — zero risk to anything you care about.
   They see a working core loop; your library is untouched.

This is also a feature worth naming in the 150-word note: a cleaner whose default is to
report rather than delete is the safer product, and safety is evaluation criterion #2.
