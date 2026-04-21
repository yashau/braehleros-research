# Deconstructing BrählerOS
### Protocol Reverse Engineering and Client Implementation

---

## Abstract

This paper documents the reverse engineering of **BrählerOS**, Brähler's conference management platform as deployed in a national parliament. Starting from a running server binary with no documentation, we reconstructed the full TCP wire protocol, decoded the binary data serialisation format, mapped the database schema transmitted over the wire, and produced a working open-source Node.js client library. No proprietary SDKs were used in the final implementation.

**See also:**
- [PROTOCOL.md](PROTOCOL.md) — standalone wire protocol reference
- [poc-speakerlist.md](poc-speakerlist.md) — PowerShell PoC usage and implementation notes

---

## 1. Target Overview

BrählerOS is a parliamentary conference management platform used to manage delegate DigiMIC units, speaker lists, and request queues in legislative chambers. The deployment under study runs on a Windows host (`braehlerOS.exe`) and manages a chamber of approximately 107 delegates seated at Brähler DCEN (Delegate Control & Extension Network) hardware.

The system exposes several TCP services. The one of interest is the **ConfClientServicePort on port 400**, which serves both the operator console (`ConfOperator.exe`, a Unity-based desktop application) and delegate processing units. This port delivers the full conference state to any connecting client and streams live events as delegates interact with their microphone units.

The server-side stack is **.NET Framework 4.7.2** (C#). The operator client is a **Unity** application, meaning its game logic lives not in the native executable but in a managed assembly (`Assembly-CSharp.dll`) bundled in the application's data directory.

---

## 2. Reconnaissance

### 2.1 Binary Identification

Initial inspection of `braehlerOS.exe` confirmed it was a standard .NET PE — decompilable with `ilspycmd`. The operator client `ConfOperator.exe` appeared to be a native 64-bit binary (Unity player), but Unity applications ship all managed C# code compiled to CIL in `ConfOperator_Data/Managed/Assembly-CSharp.dll`, which is fully decompilable.

The server executable referenced several supporting assemblies: `APATools.dll` (lower-level transport and queueing), `SMic.Basics.dll` (serialisation primitives), and `SMic.Database.dll` (entity definitions).

### 2.2 Configuration Exposure

`braehlerOS.exe.config` was found alongside the binary and yielded the PostgreSQL connection string in plaintext — host, port, database name, username, and password all in clear text. This provided direct database access for schema validation and cross-referencing data observed on the wire.

### 2.3 Port Identification

Decompilation of `braehlerOS.exe` revealed a constant:

```csharp
public const int ConfClientServicePort = 400;
```

---

## 3. Wire Protocol Analysis

### 3.1 Framing

All TCP traffic on port 400 uses a simple fixed-header framing scheme discovered in the `APATools` receive loop:

```
[Int32 LE cmd][Int32 LE payloadLen][payloadLen bytes]
```

Every message is self-contained. A `payloadLen` of zero is valid; the 8-byte header is always present.

### 3.2 String Encoding

Two incompatible string encoding formats exist in the codebase. Understanding which one applies to port 400 was critical:

**`SMic.Basics.Memstream` (port 400):**
```
[Int32 charCount][charCount × 2 bytes, UTF-16LE]
```

**`APATools.MemStream` (other services):**
```
[Int32 byteLen][byteLen bytes, UTF-8]
```

Using the wrong format produces a cascade of parse failures since string lengths control field offsets throughout every packet. Decompiling the specific path taken by port 400 connections — through `SMicClientConnection.doReceiveLoop` — confirmed the `SMic.Basics.Memstream` format.

### 3.3 Connection Handshake

The handshake sequence, reconstructed from `RequestLogin()` in Assembly-CSharp.dll:

**Step 1 — ClientIdentification (cmd 58, client → server)**

```
WriteString(guid)    →  [Int32 charCount][UTF-16LE bytes]
WriteInt(clientType) →  [Int32]
```

The GUID is a freshly generated UUID string (36 chars with dashes). The `ClientType` enum:

| Value | Meaning |
|-------|---------|
| 1 | Viewer |
| 2 | Client (Operator) |

During testing, `ClientType = 1` (Viewer) was rejected with `state = 0`. `ClientType = 2` (Client) was accepted. The server checks this against available license slots; the deployment had no viewer licenses configured.

**Step 2 — License Ack (cmd 58, server → client)**

```
[Int32 state]     — 1 = approved, anything else = denied
[String version]  — server version string e.g. "2.3.0"
```

On approval, the server immediately begins transmitting the initialization sequence.

### 3.4 Initialization Sequence

After the license ack, the server emits a burst of packets:

```
cmd 66  — BeginInitialize
cmd 1   — Initialize (single large payload, full DB snapshot)
cmd 2   — ConferenceState
cmd 3   — Initial speaker list (bulk format)
cmd 5   — Initial request list (bulk format)
cmd 46  — Initial intervention list (bulk format)
cmd 50  — Previous speaker list (ignored)
[~30 additional packets — voting state, card state, audio config, etc.]
cmd 67  — EndInitialize
```

The Initialize packet (cmd 1) is the most significant: a single serialized payload containing nine database tables in fixed order, delivering everything the client needs to resolve names, seats, and mappings without any further queries.

---

## 4. The Initialize Packet

### 4.1 Structure

```
[Int32 = 9]          ← legacy table count header, ignored by clients
For each of 9 tables:
  [String tableName]
  [Int32 rowCount]
  For each row:
    [VirtualTable metadata header]
    [table-specific fields]
```

The table order is fixed: `Conference`, `DelegateData`, `Delegates`, `Seats`, `ConferenceDelegateSeatMap`, `AgendaItem`, `DelAgendaItem`, `DocAgendaItem`, `Documents`.

### 4.2 VirtualTable Metadata Header

Every row — regardless of table — begins with a 6-field header emitted by `VirtualTable.WriteData`:

```
String tableName, String internalID, String primaryIDName,
String condition, Int32 cmd, String fieldlist
```

This header is identical across all tables and must be skipped before reading any row-specific data. Missing this caused early parse attempts to read field data at wrong offsets and produce entirely invalid results.

### 4.3 Key Tables

**DelegateData** — personal information for each delegate. `LastName` and `Organisation` are both free-form strings whose meaning depends on how the deployment uses them.

**Delegates** — a join record linking a `DelegateID` (conference-specific) to a `DelegateDataID` (person record). This two-level indirection means the same person can participate in multiple conferences with different `DelegateID` values while sharing a single `DelegateData` row.

**ConferenceDelegateSeatMap** — the critical linking table:

```
Long MapID, Long ConferenceID, Long DelegateID, Long SeatNumber
```

The fourth field is the **plain integer conference seat number** (e.g. 97), not a foreign key to the Seats table. This table is what allows a seat number observed in a live event to be resolved to a delegate name.

### 4.4 Name Resolution Chain

```
seatNumber → seatMap[seatNumber] → DelegateID
           → delMap[DelegateID]  → DelegateDataID
           → ddMap[DelegateDataID] → { first, last, org }
```

---

## 5. Speaker and Request Events

### 5.1 Dual-Format Discovery

The server reuses command numbers for two semantically different purposes depending on whether the client has received `EndInitialize`:

**Before EndInitialize — bulk initial state dump:**
```
[Int32 count]
For each entry:
  [Int64 seatNumber]   ← plain integer (e.g. 97)
  [Int64 dcenUnit]     ← linearised DCEN hardware unit index
  [Int32 pos]          ← always -1; queue order is entry order
  [Int32 state]
  [Int32 flags]
```

**After EndInitialize — live incremental updates:**
```
[Int64 seatId]         ← compound: (seatNumber << 32) | lineNumber
[Int64 dcenUnit]       ← compound: (unitIndex << 32) | 0
[Int32 pos]            ← actual 0-based queue position
[Int32 state]
[Int32 flags]
```

The compound encoding was discovered by observing that live events produced large 64-bit values (e.g. `416611827713`) that shifted right by 32 bits yielded the known seat number (`97`). The low 32 bits encoded the DCEN line number (`1`).

**Remove events** (cmd 4, 6, 47) always use the compound format regardless of initialization state:
```
[Int64 seatId compound]
[Int64 dcenUnit compound]
```

### 5.2 DCEN Hardware Addressing

The `dcenUnit` field encodes physical hardware location, not a database identifier. Each DCEN controller manages multiple lines, each with multiple DigiMIC units. The wire value is a **linearised index** across all lines on the DCEN:

| Seat | Line | Unit on line | Wire value (dcenUnit) |
|------|------|--------------|-----------------------|
| 97   | 1    | 4            | 4                     |
| 102  | 2    | 5            | 9                     |

Line 1 has 4 units; line 2 begins at index 5. This value is not used for name resolution — the seat number is the correct key into the `ConferenceDelegateSeatMap`.

### 5.3 Command Reference

| Cmd | Description |
|-----|-------------|
| 1   | Initialize — full DB snapshot |
| 2   | ConferenceState |
| 3   | Speaker added / initial speaker list |
| 4   | Speaker removed |
| 5   | Request added / initial request list |
| 6   | Request removed |
| 11  | DelegateLogin |
| 46  | Intervention added / initial list |
| 47  | Intervention removed |
| 50  | Previous speaker added (history) |
| 51  | Previous speaker removed (history) |
| 58  | ClientIdentification / ack |
| 66  | BeginInitialize |
| 67  | EndInitialize |

---

## 6. Implementation Challenges

### 6.1 .NET Framework DLL in PowerShell 7

The initial approach attempted to load `APATools.dll` at runtime via reflection and compile a thin wrapper using `Add-Type`. PowerShell 7 uses Roslyn targeting .NET Core; `APATools.dll` targets .NET Framework 4.x. Resolution of framework assembly references (`mscorlib`, `System.Collections.NonGeneric`) failed across multiple attempts with explicit assembly path injection. The root cause is a fundamental incompatibility between Roslyn/.NET Core and .NET Framework 4.x runtime assembly resolution.

**Resolution:** abandoned DLL loading entirely and reimplemented the wire protocol from scratch in pure PowerShell. No `Add-Type`, no reflection, no external assemblies.

### 6.2 Variable Interpolation in PowerShell

PowerShell's string interpolation parsed `"${tbl}:"` as a scoped variable reference (`$tbl:` as scope prefix), producing an empty string rather than the table name. Fixed by using `${tbl}` without the trailing colon inside the interpolated expression.

### 6.3 TcpClient Constructor Null Address

`TcpClient(IPEndPoint localEP, IPEndPoint remoteEP)` overload with `$null` for the local endpoint threw `ArgumentNullException`. Fixed by using `[System.Net.IPAddress]::Any` as the local bind address.

### 6.4 The `+` Notation for Nested Classes

Reflection lookup `APATools.Message` returned null. .NET uses `+` to denote nested classes: the correct name was `APATools.Queue+Message`. Failure to resolve this type caused the entire message processing pipeline to silently drop all received packets.

### 6.5 Compound vs Plain ID Encoding

Live events used compound 64-bit IDs while the init bulk dump used plain integers for the same logical fields. This was discovered empirically by hex-dumping bulk init payloads and cross-referencing against known seat numbers. Without the hex dump, the parser silently produced position `-1` and seat `0` for all init entries.

---

## 7. Results

The complete reverse-engineering effort produced:

1. **[`poc-speakerlist.ps1`](poc-speakerlist.ps1)** — a pure PowerShell wire-protocol monitor that connects to a live server, parses the full initialization snapshot, and streams annotated speaker/request/intervention events with delegate names and organization. See [poc-speakerlist.md](poc-speakerlist.md) for usage.

2. **[node-braehleros](https://www.npmjs.com/package/node-braehleros)** (npm) — a production-quality Node.js client library with zero dependencies, implementing the full protocol with AbortSignal lifecycle control, exponential backoff reconnection, send queuing, and a clean event-driven API surface suitable for building real-time parliamentary dashboards.

Both were validated against a live production deployment serving a national parliament in session.

---

## 8. Disclosure

This research was conducted on a system we had authorised access to. No disruption was caused to parliamentary proceedings. The findings are published to document protocol behaviour for legitimate integration purposes.

---

## References

- `braehlerOS.exe` — decompiled via `ilspycmd`
- `ConfOperator_Data/Managed/Assembly-CSharp.dll` — decompiled via `ilspycmd`
- `APATools.dll`, `SMic.Basics.dll`, `SMic.Database.dll` — inspected via reflection and decompilation
- PostgreSQL dump of `BDB1_1` — used for schema validation
- [node-braehleros](https://www.npmjs.com/package/node-braehleros) — resulting open-source client
- [PROTOCOL.md](PROTOCOL.md) — wire protocol reference derived from this research
