# 
# Coordinator Election

In a distributed server environment like Roblox, it's important to prevent multiple servers from processing the same matchmaking queue simultaneously. To handle this, each `RegionalQueue` performs **coordinator election** using `MemoryStoreService:GetHashMap()`.

Each queue region (e.g., `EU-Solo`, `NA-Duo`) has a unique lock key derived from its `Mode` and `RegionCode`. When a `RegionalQueue` is created, it periodically attempts to **claim or renew ownership** of this lock using `UpdateAsync`. The lock stores the current server's `JobId`, a `timestamp`, and an `Active` flag.

#### 🧠 Election Logic

- If **no existing lock** is found for the region, the server successfully claims it and becomes the **coordinator**.
- If the existing lock is held by the **same server**, the server simply **renews** it.
- If the existing lock is **expired** or marked as **inactive**, any server can attempt to claim it.
- If another server already holds the lock and is still active, the current server stands down.

The `UpdateAsync` call ensures atomicity — only one server can win the race to update the lock during each interval.

#### 🔁 Refresh Cycle

The election check runs every few seconds (e.g., every 5 seconds). If the current coordinator fails to renew its lock in time (e.g., crashes or lags), another server will detect this on the next cycle and take over. This keeps matchmaking alive without centralized control.

#### ✅ Benefits

- No external services or timers required
- Fast recovery from server failures
- Fully region- and mode-specific
- Lock timeout ensures no permanent ownership

This simple but robust coordination mechanism allows MatchMaker to safely scale across many servers while ensuring **only one instance creates matches per queue**.

---

# Queue system

The queue system is responsible for managing parties as they enter, wait in, and exit matchmaking queues. Each queue is region- and mode-specific, meaning a player in "Duo" mode and "NA" region will be placed into a different queue than someone in "Solo" mode and "EU". Queues are powered by `MemoryStoreService:GetSortedMap()`, which supports fast server-wide access, sorting, and timeout behavior.

#### 🧑‍🤝‍🧑 Adding a Party to the Queue

When a party joins the queue via `AddPartyAsync`, the following happens:

1. A unique **Party ID** is generated and stored in a party object, which includes member user IDs, their data (optional), the mode name, and region code.
2. This party object is added to a **SortedMap** under its Party ID.
   - The `sortKey` is set to the current time, so parties are automatically sorted by join time (FIFO).
   - An expiration is set (e.g. 24 hours), so stale entries clean themselves up.
3. A local cache holds metadata like join time and references to repeat threads (e.g., refresh loops).
4. A loop begins that checks every few seconds whether a match was found for the party.

#### ⏳ Timeouts and Refreshes

- If the party waits too long (defined by `QUEUE_TIMEOUT`, e.g. 20 minutes), it is automatically removed from the queue.
- Every few seconds, the system calls `CheckIfPartyFoundMatch()` to:
  - See if a match ID was written to the party's data (by a coordinator during matchmaking).
  - Mark it as "left" if they’re being force-removed.

#### 🤝 Match Creation and Retrieval

Once the coordinator creates a match, it updates the matching party entries in the SortedMap by assigning them a shared `MatchId`. When a server checks the party's data during the refresh cycle, it sees this Match ID and triggers a teleport using `TeleportPartyAsync()`.

If the player re-joins after a disconnect, their party data is reloaded from `DataStore`, and the queue system checks again for any match information before deciding whether to teleport them or let them requeue.

#### 🚪 Removing a Party

When a party is removed from the queue (either voluntarily or by timeout), the following occurs:

- The SortedMap entry is either deleted or updated to set a high `sortKey` so it’s ignored during matchmaking.
- A flag `PartyLeft = true` is stored, preventing accidental match assignment after leaving.
- If the party had a match assigned during removal, it’s still teleported to that match to avoid desync issues.

#### 🔐 SortedMap Behavior

- SortedMap guarantees order and TTL expiration, which makes it ideal for queues.
- Only the main coordinator calls `GetRangeAsync()` to fetch batches of parties for matchmaking, minimizing MemoryStore usage and contention.
- Each entry is updated atomically via `UpdateAsync()` to avoid race conditions when multiple servers attempt matchmaking.

The queue system ensures parties are processed efficiently, safely, and predictably — even in distributed server environments. Combined with coordinator election and private server handling, it forms the backbone of the MatchMaker framework.
