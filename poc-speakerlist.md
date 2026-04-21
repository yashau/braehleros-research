# BrählerOS — Speaker List Monitor

Pure PowerShell wire-protocol client for BrählerOS. Connects to the `ConfClientServicePort` (port 400), receives the full conference state on connect, then monitors live speaker and request list events.

No DLL dependencies, no `Add-Type`, no .NET Framework assemblies required. Runs on PowerShell 7 / .NET Core.

---

## Usage

```powershell
.\poc-speakerlist.ps1 [-ServerIP <ip>] [-Port <port>]
```

| Parameter   | Default        | Description                        |
|-------------|----------------|------------------------------------|
| `-ServerIP` | `192.168.1.100` | IP address of the BrählerOS server |
| `-Port`     | `400`          | `ConfClientServicePort`            |

**Example:**
```powershell
.\poc-speakerlist.ps1 -ServerIP 192.168.1.100
```

Press **Ctrl+C** to disconnect (responds within ~500 ms).

---

## Sample Output

```
[*] Connecting to 192.168.1.100:400 ...
[+] Connected.
[+] License APPROVED  (server: 2.3.0)
>> Initialize (95770 bytes) ...
  [INIT] DelegateData: 107 rows
  [INIT] Delegates: 107 rows
  [INIT] Seats: 104 rows
  [INIT] ConferenceDelegateSeatMap: 96 rows
[+] Name table: 107 people, 107 delegates, 96 seat mappings

  [INIT REQUEST] pos=1  seat=102  seat#102
  [INIT REQUEST] pos=2  seat=97   Jane Doe [Org A]
  [INIT REQUEST] pos=3  seat=101  seat#101
  [INIT REQUEST] pos=4  seat=103  John Roe [Org B]

[+] Ready. Monitoring speaker / request lists (Ctrl+C to stop)...

  [REQUEST ADDED]    pos=1  seat=94   Alex Example [Org C]
  [SPEAKER ADDED]    pos=0  seat=94   Alex Example [Org C]
  [SPEAKER REMOVED]         seat=94   Alex Example [Org C]
  [REQUEST REMOVED]         seat=81   Sam Sample [Org D]
```

---

## Architecture

### Target System

**BrählerOS** is a parliamentary conference management platform built on Brähler DCEN hardware and DigiMIC delegate microphone units. The server component (`braehlerOS.exe`) runs on Windows, exposes multiple TCP ports for different client types, and maintains conference state in a PostgreSQL database (`BDB1_1`).

**Hardware:** Each delegate seat connects to a **DCEN** (Delegate Control & Extension Network) unit. DCENs are identified by serial number (e.g., 1483) and contain multiple lines, each with multiple units. The linearised unit index across all lines is what appears as the `delegateID` field in live speaker packets — it is a hardware address, not a database identifier.

### Port 400 — ConfClientServicePort

Port 400 accepts connections from:
- **ConfOperator** (the operator console application)
- **DPU clients** (delegate processing units)

This script connects as `ClientType = 2` (Client/Operator). `ClientType = 1` (Viewer) is rejected by the server in this deployment.

---

## Wire Protocol

### Framing

Every message on the TCP stream is a self-contained packet:

```
[Int32 LE cmd][Int32 LE payloadLen][payloadLen bytes]
```

- All integers are **little-endian**.
- A `payloadLen` of `0` means no payload bytes follow; the 8-byte header is still always present.

### String Encoding (`SMic.Basics.Memstream`)

Strings used in the `SMic` wire protocol are UTF-16LE with a character-count prefix:

```
[Int32 charCount][charCount * 2 bytes UTF-16LE]
```

This is **not** the same as the `APATools.MemStream` format (which uses a byte-length prefix with UTF-8).

---

## Connection Handshake

### 1. ClientIdentification (cmd = 58, client → server)

Sent immediately on connect. Payload:

```
WriteString(guid)   →  [Int32 charCount][UTF-16LE bytes]
WriteInt(clientType) → [Int32]
```

| ClientType | Value |
|------------|-------|
| Viewer     | 1     |
| Client     | 2     |

The GUID is a freshly generated `System.Guid` (`ToString()` format with dashes, e.g. `84a281...`).

### 2. License Approval (cmd = 58, server → client)

The server responds on the same command number:

```
[Int32 state]    — 1 = approved, anything else = denied
[String version] — server version string, e.g. "2.3.0"
```

If denied, the script exits immediately.

### 3. Initial State Sequence

After approval the server sends a burst of packets before `EndInitialize`:

| Cmd | Description |
|-----|-------------|
| 146, 147, 213, 191, 41 | Pre-init metadata (ignored) |
| 66  | `BeginInitialize` |
| 1   | `Initialize` — full DB snapshot (see below) |
| 2   | `ConferenceState` |
| 3, 5, 46 | Current speaker / request / intervention lists (bulk format) |
| 50  | Previous speaker list (ignored) |
| various | Voting, card, audio state packets (ignored) |
| 67  | `EndInitialize` — live monitoring begins |

---

## Initialize Packet (cmd = 1)

A single large payload containing 9 database tables in fixed order. Format:

```
[Int32 tableCount=9]  ← legacy field, ignored by clients
For each table:
  [String tableName]
  [Int32 rowCount]
  For each row:
    [VirtualTable metadata header]
    [table-specific fields]
```

### VirtualTable Metadata Header

Every table row starts with a 6-field header (skipped by this client):

```
String tableName, String internalID, String primaryIDName,
String condition, Int32 cmd, String fieldlist
```

### Table Schemas

#### Conference (1 row)

```
Long, Long, Str, Long, Long, Str, Str, Str,
Int, Int, Long*4, Int, Str, Int, Str, Int, Int,
Str, Long, Long, Str, Int
```

#### DelegateData

Personal information for each delegate/MP.

| Field         | Type   | Notes                                      |
|---------------|--------|--------------------------------------------|
| DelegateDataID | Long  | Primary key; used in CDSMap lookup chain   |
| LastName      | String | Free-form                                  |
| FirstName     | String |                                            |
| MiddleName    | String | Skipped                                    |
| Title         | String | Skipped                                    |
| EMailAddress  | String | Skipped                                    |
| Organisation  | String | Free-form                                  |
| DefaultCardID | Long   | Skipped                                    |
| DefaultPassword, Image, Telephone | String×3 | Skipped |
| Birthday      | Long   | Skipped                                    |
| DelegateInformation … UserID | String×8 | Skipped |
| Flags         | Int    | Skipped                                    |
| DDParameter   | String | Skipped                                    |
| FingerprintID | Int    | Skipped                                    |

#### Delegates

Join record linking a delegate to their personal data for a specific conference.

| Field                   | Type   | Notes                          |
|-------------------------|--------|--------------------------------|
| DelegateID              | Long   | Primary key                    |
| DelegateData_DelegateID | Long   | FK → DelegateData.DelegateDataID |
| ConferenceID            | Long   | FK; skipped                    |
| SpeakTimeLimit          | Int    | Skipped                        |
| SpeakTimeInterval       | Int    | Skipped                        |
| Weighting, Attendance   | String×2 | Stored as strings; skipped   |
| CardID                  | Long   | Skipped                        |
| Password, Flags, Customfield | String×3 | Skipped               |

#### Seats (skipped)

```
Long*3, Int, Long, Int*2, Long, Str, Long
```

#### ConferenceDelegateSeatMap

Maps a conference seat number to its assigned delegate.

| Field        | Type | Notes                              |
|--------------|------|------------------------------------|
| MapID        | Long | Primary key; skipped               |
| ConferenceID | Long | Skipped                            |
| DelegateID   | Long | FK → Delegates.DelegateID          |
| SeatNumber   | Long | Plain conference seat number (e.g. 97) |

This is the critical table for name resolution: `seatMap[seatNumber] = DelegateID`.

#### AgendaItem (skipped)

```
Long*2, Str*2, Int, Long*4, Int, Str, Long, Str*4, Int
```

#### DelAgendaItem, DocAgendaItem (skipped)

```
Long*4
```

#### Documents (skipped)

```
Long*2, Str, Long, Str, Int*2, Str*2
```

---

## Name Resolution

Three hashtables are built from the Initialize packet:

```
$ddMap   : DelegateDataID  → { Last, First, Org }
$delMap  : DelegateID      → DelegateDataID
$seatMap : SeatNumber(Int) → DelegateID
```

Lookup chain for a given seat number:

```
seatNum → $seatMap → DelegateID → $delMap → DelegateDataID → $ddMap → { First, Last, Org }
```

Display format: `FirstName LastName [Organisation]`

If any step in the chain fails, the fallback is `seat#N`.

---

## Speaker / Request / Intervention Events

### Bulk Initial State (sent before EndInitialize)

Cmds 3 (speaker), 5 (request), 46 (intervention) are sent once on connect as full list snapshots:

```
[Int32 count]
For each entry:
  [Int64 seatNumber]   ← plain conference seat number
  [Int64 dcenUnit]     ← linearised DCEN unit index (hardware address, not a DB key)
  [Int32 pos]          ← always -1 in initial dump; position derived from entry order
  [Int32 state]
  [Int32 flags]
```

Entry order in the payload is the queue order — position 1 is the first entry, position 2 the second, etc.

### Live Updates (sent after EndInitialize)

The same cmd numbers are reused for incremental updates, but with **compound-encoded** IDs:

```
seatID   = (conferenceSeatsNum << 32) | lineNumber
dcenUnit = (linearUnitIndex << 32) | 0
```

**Add event** (cmd 3 / 5 / 46):
```
[Int64 seatID compound]
[Int64 dcenUnit compound]
[Int32 pos]              ← actual 0-based position in queue
[Int32 state]
[Int32 flags]
```

**Remove event** (cmd 4 / 6 / 47):
```
[Int64 seatID compound]
[Int64 dcenUnit compound]
```

To recover the plain seat number from a live event: `seatNum = seatID >> 32`.

### DCEN Unit Addressing

The `dcenUnit` field encodes the hardware address of the delegate microphone:

- Each DCEN controller has a serial number (e.g. 1483).
- Each DCEN has multiple lines; each line has multiple units.
- The value in the packet is the **linearised** unit index across all lines on that DCEN.

Example — DCEN 1483 with line 1 (4 units) and line 2 (6 units):

| Seat | Line | Unit on line | Linear index (dcenUnit) |
|------|------|--------------|-------------------------|
| 97   | 1    | 4            | 4                       |
| 102  | 2    | 5            | 9                       |

The dcenUnit field is **not** used for name lookup; seat number is used instead.

### Command Reference

| Cmd | Direction      | Description                        |
|-----|----------------|------------------------------------|
| 1   | server→client  | Initialize (full DB snapshot)      |
| 2   | server→client  | ConferenceState                    |
| 3   | server→client  | Speaker added / initial speaker list |
| 4   | server→client  | Speaker removed                    |
| 5   | server→client  | Request added / initial request list |
| 6   | server→client  | Request removed                    |
| 11  | server→client  | DelegateLogin                      |
| 40  | server→client  | (voting/audio state, ignored)      |
| 46  | server→client  | Intervention added / initial list  |
| 47  | server→client  | Intervention removed               |
| 50  | server→client  | Previous speaker added (ignored)   |
| 51  | server→client  | Previous speaker removed (ignored) |
| 58  | both           | ClientIdentification / ack         |
| 66  | server→client  | BeginInitialize                    |
| 67  | server→client  | EndInitialize                      |

---

## ConferenceState (cmd = 2)

```
[Int64 conferenceID]
[Int32 state]
```

Observed state value `4` during an active session.

---

## Database

The BrählerOS server maintains conference state in a local PostgreSQL instance. The Initialize packet transmits the full relevant subset of the database to each connecting client, so direct database access is not needed for monitoring.

---

## Implementation Notes

- **No DLL loading.** An earlier approach attempted to load `APATools.dll` via reflection and `Add-Type`. This fails under PowerShell 7 / .NET Core because APATools targets .NET Framework 4.x and its assembly references cannot be resolved by the Roslyn compiler. The current implementation reimplements the wire protocol entirely in PowerShell.
- **Receive timeout.** The socket has a 500 ms receive timeout so that `Ctrl+C` is handled promptly even when no data is arriving.
- **Error isolation.** Each packet is parsed inside a `try/catch`; a malformed packet prints a hex dump and the loop continues rather than crashing.
- **Pre/post-init dual format.** The server reuses the same command numbers (3, 5, 46) for both the initial bulk state dump (plain IDs, count-prefixed) and live incremental events (compound IDs, single entry). The `$initialized` flag selects the correct parser.
