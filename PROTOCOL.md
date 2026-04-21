# BrählerOS Wire Protocol Reference

This document describes the binary TCP protocol used by the BrählerOS `ConfClientServicePort` (default port 400). It is independent of any specific implementation.

---

## Transport

Plain TCP. All multi-byte integers are **little-endian**. No TLS.

---

## Packet Framing

Every message on the stream is a self-contained packet:

```
┌─────────────────┬──────────────────┬─────────────────────┐
│  cmd  (Int32)   │  length (Int32)  │  payload (N bytes)  │
└─────────────────┴──────────────────┴─────────────────────┘
       4 bytes           4 bytes           length bytes
```

A `length` of zero is valid; the 8-byte header is always present.

---

## Primitive Types

All primitives are serialised in the `SMic.Basics.Memstream` format used on port 400.

| Type   | Encoding |
|--------|----------|
| Int32  | 4 bytes, signed, little-endian |
| Int64  | 8 bytes, signed, little-endian |
| String | `[Int32 charCount][charCount × 2 bytes, UTF-16LE]` — charCount = 0 means empty string |

> **Note:** `APATools.MemStream` (used on other ports) encodes strings as `[Int32 byteLen][UTF-8]`. The two formats are **not** interchangeable.

---

## Connection Handshake

### 1. ClientIdentification — cmd 58 (client → server)

Sent immediately on connect.

```
String  guid        — freshly generated UUID, e.g. "84a281...-3939"
Int32   clientType  — 1 = Viewer, 2 = Client (Operator)
```

`ClientType = 2` (Client) is required. `ClientType = 1` (Viewer) is rejected in most deployments.

### 2. License Ack — cmd 58 (server → client)

```
Int32   state    — 1 = approved; any other value = denied
String  version  — server version string, e.g. "2.3.0"
```

If `state ≠ 1` the server closes the connection. Do not reconnect on an explicit denial.

---

## Initialization Sequence

After a successful license ack, the server sends the following sequence before `EndInitialize`:

| Cmd | Description |
|-----|-------------|
| 66  | BeginInitialize |
| 1   | Initialize — full DB snapshot (see below) |
| 2   | ConferenceState |
| 3   | Initial speaker list (bulk format) |
| 5   | Initial request list (bulk format) |
| 46  | Initial intervention list (bulk format) |
| 50  | Previous speaker list (can be ignored) |
| ... | Voting state, audio config, card state (~30 additional packets) |
| 67  | EndInitialize |

The client is not considered ready until `EndInitialize` (cmd 67) is received.

---

## Initialize Packet — cmd 1

A single large payload containing nine database tables in fixed order.

```
Int32   = 9          — legacy table count header; ignored by clients
```

Then for each of the 9 tables, in this fixed order:

```
String  tableName
Int32   rowCount
[rowCount × row]
```

**Fixed table order:** `Conference`, `DelegateData`, `Delegates`, `Seats`, `ConferenceDelegateSeatMap`, `AgendaItem`, `DelAgendaItem`, `DocAgendaItem`, `Documents`

### VirtualTable Metadata Header

Every row of every table begins with a 6-field metadata header emitted by `VirtualTable.WriteData`. It must be consumed before reading any row-specific fields:

```
String  tableName
String  internalID
String  primaryIDName
String  condition
Int32   cmd
String  fieldlist
```

### Table Schemas

All schemas are listed after their metadata header.

#### Conference (1 row)

```
Int64, Int64, String, Int64, Int64, String, String, String,
Int32, Int32, Int64×4, Int32, String, Int32, String, Int32, Int32,
String, Int64, Int64, String, Int32
```

#### DelegateData

Personal information for each participant.

| Field | Type | Notes |
|-------|------|-------|
| DelegateDataID | Int64 | Primary key |
| LastName | String | Free-form |
| FirstName | String | |
| MiddleName | String | |
| Title | String | |
| EMailAddress | String | |
| Organisation | String | Free-form |
| DefaultCardID | Int64 | |
| DefaultPassword | String | |
| Image | String | |
| Telephone | String | |
| Birthday | Int64 | |
| DelegateInformation | String | |
| WebAddress | String | |
| Addr1–Addr2 | String×2 | |
| City, ZipCode, Country | String×3 | |
| UserID | String | |
| Flags | Int32 | |
| DDParameter | String | |
| FingerprintID | Int32 | |

#### Delegates

Join record binding a person to a specific conference.

| Field | Type | Notes |
|-------|------|-------|
| DelegateID | Int64 | Primary key — conference-scoped |
| DelegateData_DelegateID | Int64 | FK → DelegateData.DelegateDataID |
| ConferenceID | Int64 | FK |
| SpeakTimeLimit | Int32 | |
| SpeakTimeInterval | Int32 | |
| Weighting | String | Stored as string |
| Attendance | String | Stored as string |
| CardID | Int64 | |
| Password | String | |
| Flags | String | Stored as string |
| Customfield | String | |

#### Seats

```
Int64×3, Int32, Int64, Int32×2, Int64, String, Int64
```

#### ConferenceDelegateSeatMap

Maps a conference seat number to its assigned delegate.

| Field | Type | Notes |
|-------|------|-------|
| MapID | Int64 | Primary key |
| ConferenceID | Int64 | FK |
| DelegateID | Int64 | FK → Delegates.DelegateID |
| SeatNumber | Int64 | **Plain conference seat number** (e.g. 97) |

This is the key table for name resolution. See [Name Resolution](#name-resolution) below.

#### AgendaItem

```
Int64×2, String×2, Int32, Int64×4, Int32, String, Int64, String×4, Int32
```

#### DelAgendaItem, DocAgendaItem

```
Int64×4
```

#### Documents

```
Int64×2, String, Int64, String, Int32×2, String×2
```

---

## Name Resolution

Three lookup tables built from the Initialize packet:

```
ddMap   : DelegateDataID → { first, last, org }
delMap  : DelegateID     → DelegateDataID
seatMap : SeatNumber     → DelegateID
```

Lookup chain for a seat number observed in an event:

```
seatNum → seatMap → DelegateID → delMap → DelegateDataID → ddMap → { first, last, org }
```

---

## ConferenceState — cmd 2

```
Int64   conferenceId
Int32   state
```

Sent during initialization and again whenever conference state changes.

---

## Speaker / Request / Intervention Events

Commands 3, 5, 46 (add) and 4, 6, 47 (remove) are used in two formats depending on whether `EndInitialize` has been received.

### Bulk Initial State (before EndInitialize)

Sent once on connect to deliver the current list state.

```
Int32   count
For each entry:
  Int64   seatNumber   — plain conference seat number (e.g. 97)
  Int64   dcenUnit     — linearised DCEN hardware unit index (see DCEN Addressing)
  Int32   pos          — always -1 in bulk; queue order is entry order
  Int32   state
  Int32   flags
```

Position in the queue is determined by entry order (first entry = position 0).

### Live Add Events (after EndInitialize) — cmd 3, 5, 46

Single-entry format with compound-encoded IDs:

```
Int64   seatId    — compound: (seatNumber << 32) | lineNumber
Int64   dcenUnit  — compound: (unitIndex << 32) | 0
Int32   pos       — 0-based queue position
Int32   state
Int32   flags
```

Extract seat number: `seatNumber = seatId >> 32`

### Live Remove Events — cmd 4, 6, 47

Always compound format, regardless of initialization state:

```
Int64   seatId    — compound: (seatNumber << 32) | lineNumber
Int64   dcenUnit  — compound: (unitIndex << 32) | 0
```

---

## DCEN Hardware Addressing

The `dcenUnit` field is a hardware address, not a database identifier, and is not used for name resolution.

Each DCEN controller manages multiple **lines**; each line has multiple **units**. The wire value is the linearised unit index across all lines on the DCEN:

```
Line 1: units 1–4   → wire values 1, 2, 3, 4
Line 2: units 1–6   → wire values 5, 6, 7, 8, 9, 10
```

Example: seat 102 is on DCEN line 2, unit 5 — wire value `9` (5th unit overall).

---

## Command Reference

| Cmd | Direction | Description |
|-----|-----------|-------------|
| 1   | S→C | Initialize — full DB snapshot |
| 2   | S→C | ConferenceState |
| 3   | S→C | Speaker added / initial speaker list |
| 4   | S→C | Speaker removed |
| 5   | S→C | Request added / initial request list |
| 6   | S→C | Request removed |
| 11  | S→C | DelegateLogin |
| 46  | S→C | Intervention added / initial list |
| 47  | S→C | Intervention removed |
| 50  | S→C | Previous speaker added (history) |
| 51  | S→C | Previous speaker removed (history) |
| 58  | C→S | ClientIdentification |
| 58  | S→C | License ack |
| 66  | S→C | BeginInitialize |
| 67  | S→C | EndInitialize |
