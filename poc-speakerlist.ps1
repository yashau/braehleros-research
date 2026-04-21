# BrählerOS - Speaker List PoC
# Pure wire-protocol implementation — no DLL loading, no Add-Type.
# Connects to port 400 (ConfClientServicePort) as Client (type=2).
#
# Usage:  .\poc-speakerlist.ps1 -ServerIP <ip> [-Port 400]

param(
    [string]$ServerIP = "192.168.1.100",
    [int]$Port = 400
)

# ── Payload parser (operates on $script:_buf / $script:_pos) ─────────────────
$script:_buf = $null
$script:_pos = 0

function p-set([byte[]]$b)        { $script:_buf = $b; $script:_pos = 0 }
function p-int                    { $v = [System.BitConverter]::ToInt32($script:_buf, $script:_pos); $script:_pos += 4; $v }
function p-long                   { $v = [System.BitConverter]::ToInt64($script:_buf, $script:_pos); $script:_pos += 8; $v }
function p-str {
    $n = p-int
    if ($n -le 0) { return "" }
    $v = [System.Text.Encoding]::Unicode.GetString($script:_buf, $script:_pos, $n * 2)
    $script:_pos += $n * 2; $v
}
function p-skip-int([int]$c  = 1) { $script:_pos += $c * 4 }
function p-skip-long([int]$c = 1) { $script:_pos += $c * 8 }
function p-skip-str([int]$c  = 1) { for ($i = 0; $i -lt $c; $i++) { p-str | Out-Null } }

# Every VirtualTable.WriteData begins with the same 6-field metadata header:
# String tableName, String internalID, String primaryIDName,
# String condition, Int32 cmd, String fieldlist
function p-hdr { p-skip-str 4; p-skip-int; p-skip-str }

# ── Table skip/read functions (schemas from decompiled WriteData) ─────────────

function skip-Conference {          # header + Long,Long + Str + Long,Long + Str,Str,Str + Int,Int + Long*4 + Int + Str + Int + Str + Int,Int + Str + Long,Long + Str + Int
    p-hdr
    p-skip-long 2; p-skip-str; p-skip-long 2; p-skip-str 3
    p-skip-int 2; p-skip-long 4; p-skip-int; p-skip-str; p-skip-int
    p-skip-str; p-skip-int 2; p-skip-str; p-skip-long 2; p-skip-str; p-skip-int
}

function read-DelegateData {        # header + Long + Str*6 + Long + Str*3 + Long + Str*8 + Int + Str + Int
    p-hdr
    $id  = p-long                   # DelegateDataID
    $ln  = p-str                    # LastName
    $fn  = p-str                    # FirstName
    p-skip-str 3                    # MiddleName, Title, EMailAddress
    $org = p-str                    # Organisation
    p-skip-long                     # DefaultCardID
    p-skip-str 3                    # DefaultPassword, Image, Telephone
    p-skip-long                     # Birthday
    p-skip-str 8                    # DelegateInformation, WebAddress, Addr1, Addr2, City, ZipCode, Country, UserID
    p-skip-int                      # Flags
    p-skip-str                      # DDParameter
    p-skip-int                      # FingerprintID
    @{ ID = $id; Last = $ln; First = $fn; Org = $org }
}

function read-Delegates {           # header + Long*3 + Int*2 + Str*2 + Long + Str*3
    p-hdr
    $did  = p-long                  # DelegateID
    $ddid = p-long                  # DelegateData_DelegateID FK
    p-skip-long                     # Conference FK
    p-skip-int 2                    # SpeakTimeLimit, SpeakTimeInterval
    p-skip-str 2                    # Weighting, Attendance (stored as strings)
    p-skip-long                     # CardID
    p-skip-str 3                    # Password, Flags (as string), Customfield
    @{ DID = $did; DDID = $ddid }
}

function skip-Seats {               # header + Long*3 + Int + Long + Int*2 + Long + Str + Long
    p-hdr; p-skip-long 3; p-skip-int; p-skip-long; p-skip-int 2; p-skip-long; p-skip-str; p-skip-long
}

function read-CDSMap {              # header + Long*4: MapID, ConferenceID, DelegateID, SeatNum
    p-hdr
    p-skip-long 2                   # MapID, ConferenceID
    $did = p-long                   # DelegateID (DB key)
    $sn  = p-long                   # plain seat number
    if ($sn -ne 0) { $seatMap[[int]$sn] = [long]$did }
}

function skip-AgendaItem {          # header + Long*2 + Str*2 + Int + Long*4 + Int + Str + Long + Str*4 + Int
    p-hdr; p-skip-long 2; p-skip-str 2; p-skip-int; p-skip-long 4
    p-skip-int; p-skip-str; p-skip-long; p-skip-str 4; p-skip-int
}

function skip-DelAgendaItem {       # header + Long*4
    p-hdr; p-skip-long 4
}

function skip-DocAgendaItem {       # header + Long*4
    p-hdr; p-skip-long 4
}

function skip-Documents {           # header + Long*2 + Str + Long + Str + Int*2 + Str*2
    p-hdr; p-skip-long 2; p-skip-str; p-skip-long; p-skip-str; p-skip-int 2; p-skip-str 2
}

# ── Initialize(cmd=1) parser ──────────────────────────────────────────────────
$ddMap   = @{}   # DelegateDataID  -> @{Last, First, Org}
$delMap  = @{}   # DelegateID      -> DelegateDataID
$seatMap = @{}   # SeatID (wire Int64) -> DelegateID (DB key)

function parse-Initialize([byte[]]$payload) {
    p-set $payload
    p-skip-int   # version/count header (value=9, ignored by clients)

    $tables = @(
        @{ Name = "Conference";               Fn = { skip-Conference };    Count = 1 },
        @{ Name = "DelegateData";             Fn = { $null };              Count = -1 },
        @{ Name = "Delegates";                Fn = { $null };              Count = -1 },
        @{ Name = "Seats";                    Fn = { skip-Seats };         Count = -1 },
        @{ Name = "ConferenceDelegateSeatMap";Fn = { $null };               Count = -1 },
        @{ Name = "AgendaItem";               Fn = { skip-AgendaItem };    Count = -1 },
        @{ Name = "DelAgendaItem";            Fn = { skip-DelAgendaItem }; Count = -1 },
        @{ Name = "DocAgendaItem";            Fn = { skip-DocAgendaItem }; Count = -1 },
        @{ Name = "Documents";                Fn = { skip-Documents };     Count = -1 }
    )

    foreach ($t in $tables) {
        $tName = p-str
        $count = p-int
        if ($tName -ne $t.Name) {
            Write-Host "  [WARN] Expected '$($t.Name)', got '$tName' at pos $($script:_pos)"
        }
        for ($r = 0; $r -lt $count; $r++) {
            if ($t.Name -eq "DelegateData") {
                $d = read-DelegateData
                $ddMap[[long]$d.ID] = $d
            } elseif ($t.Name -eq "Delegates") {
                $d = read-Delegates
                $delMap[[long]$d.DID] = [long]$d.DDID
            } elseif ($t.Name -eq "ConferenceDelegateSeatMap") {
                read-CDSMap
            } else {
                & $t.Fn
            }
        }
        Write-Host "  [INIT] ${tName}: $count rows"
    }
}

function get-name([int]$seatNum) {
    $did  = $seatMap[$seatNum]
    $ddID = if ($null -ne $did) { $delMap[$did] } else { $null }
    if ($null -ne $ddID -and $ddMap.ContainsKey($ddID)) {
        $d = $ddMap[$ddID]
        "$($d.First) $($d.Last)$(if($d.Org){" [$($d.Org)]"})"
    } else { "seat#$seatNum" }
}

# ── TCP primitives ────────────────────────────────────────────────────────────
function tcp-read([System.IO.Stream]$s, [int]$n) {
    $b = [byte[]]::new($n); $off = 0
    while ($off -lt $n) {
        try {
            $r = $s.Read($b, $off, $n - $off)
            if ($r -eq 0) { throw "Connection closed" }
            $off += $r
        } catch [System.IO.IOException] {
            $inner = $_.Exception.InnerException
            if ($inner -is [System.Net.Sockets.SocketException] -and
                $inner.SocketErrorCode -eq [System.Net.Sockets.SocketError]::TimedOut) {
                # receive timeout — retry, giving PowerShell time to handle Ctrl+C
            } else { throw }
        }
    }
    ,$b
}

function tcp-read-packet([System.IO.Stream]$s) {
    $h   = tcp-read $s 8
    $cmd = [System.BitConverter]::ToInt32($h, 0)
    $len = [System.BitConverter]::ToInt32($h, 4)
    $pl  = if ($len -gt 0) { tcp-read $s $len } else { [byte[]]@() }
    [PSCustomObject]@{ Cmd = $cmd; Payload = $pl }
}

function tcp-send([System.IO.Stream]$s, [int]$cmd, [byte[]]$pl) {
    $h = [byte[]]::new(8)
    [System.BitConverter]::GetBytes($cmd).CopyTo($h, 0)
    [System.BitConverter]::GetBytes($pl.Length).CopyTo($h, 4)
    $s.Write($h, 0, 8)
    if ($pl.Length -gt 0) { $s.Write($pl, 0, $pl.Length) }
    $s.Flush()
}

# Build ClientIdentification payload: WriteString(guid) + WriteInt(clientType)
# WriteString = [Int32 charCount][UTF-16LE bytes]
function build-ident([string]$g, [int]$typ) {
    $ms = [System.IO.MemoryStream]::new()
    $gb = [System.Text.Encoding]::Unicode.GetBytes($g)
    $ms.Write([System.BitConverter]::GetBytes([int]$g.Length), 0, 4)
    $ms.Write($gb, 0, $gb.Length)
    $ms.Write([System.BitConverter]::GetBytes($typ), 0, 4)
    ,$ms.ToArray()
}

# ── Speaker event helpers ─────────────────────────────────────────────────────
# Live add/remove: single entry, compound encoding — seat=(seatNum<<32)|line
function show-speaker([byte[]]$pl, [string]$lbl) {
    p-set $pl
    $seat = p-long; p-skip-long; $pos = p-int; p-skip-int 2
    $sn = [int]($seat -shr 32)
    Write-Host "  [$lbl] pos=$pos  seat=$sn  $(get-name $sn)"
}

function show-removed([byte[]]$pl, [string]$lbl) {
    p-set $pl
    $seat = p-long; p-skip-long
    $sn = [int]($seat -shr 32)
    Write-Host "  [$lbl] seat=$sn  $(get-name $sn)"
}

# Initial state dump: [Int32 count][entries...] — plain (non-compound) seat number
function show-speaker-list([byte[]]$pl, [string]$lbl) {
    p-set $pl
    $count = p-int
    for ($i = 0; $i -lt $count; $i++) {
        $seat = p-long; p-skip-long; p-skip-int 3
        $sn = [int]$seat
        Write-Host "  [$lbl] pos=$($i+1)  seat=$sn  $(get-name $sn)"
    }
}

# ── Connect ───────────────────────────────────────────────────────────────────
Write-Host "[*] Connecting to ${ServerIP}:${Port} ..."
$tcp    = [System.Net.Sockets.TcpClient]::new()
$tcp.Connect($ServerIP, $Port)
$tcp.Client.ReceiveTimeout = 500   # ms — keeps Ctrl+C responsive
$stream = $tcp.GetStream()
Write-Host "[+] Connected."

# ── Send ClientIdentification ─────────────────────────────────────────────────
$guid = [System.Guid]::NewGuid().ToString()
tcp-send $stream 58 (build-ident $guid 2)
Write-Host "[+] Sent ClientIdentification (GUID=$guid, type=Client)"
Write-Host "[*] Waiting for license approval..."

# ── Receive loop ──────────────────────────────────────────────────────────────
$initialized = $false

try {
    while ($true) {
        $pkt     = tcp-read-packet $stream
        $cmd     = $pkt.Cmd
        $payload = $pkt.Payload

        try { switch ($cmd) {
            58 {  # ClientIdentification ack
                p-set $payload
                $state = p-int; $ver = p-str
                if ($state -eq 1) {
                    Write-Host "[+] License APPROVED  (server: $ver)"
                } else {
                    Write-Host "[!] License DENIED (state=$state). Exiting."
                    exit 1
                }
            }
            2 {   # ConferenceState
                p-set $payload
                $cid = p-long; $cs = p-int
                Write-Host "  [CONF STATE] confID=$cid  state=$cs"
            }
            1 {   # Initialize
                Write-Host ">> Initialize ($($payload.Length) bytes) ..."
                parse-Initialize $payload
                Write-Host "[+] Name table: $($ddMap.Count) people, $($delMap.Count) delegates, $($seatMap.Count) seat mappings"
            }
            66 { Write-Host ">> BeginInitialize" }
            67 {  # EndInitialize
                Write-Host ">> EndInitialize"
                $initialized = $true
                Write-Host ""
                Write-Host "[+] Ready. Monitoring speaker / request lists (Ctrl+C to stop)..."
                Write-Host ""
            }
            3  { if ($initialized) { show-speaker      $payload "SPEAKER ADDED"        } else { show-speaker-list $payload "INIT SPEAKER"       } }
            4  { show-removed  $payload "SPEAKER REMOVED"      }
            5  { if ($initialized) { show-speaker      $payload "REQUEST ADDED"        } else { show-speaker-list $payload "INIT REQUEST"       } }
            6  { show-removed  $payload "REQUEST REMOVED"      }
            46 { if ($initialized) { show-speaker      $payload "INTERVENTION ADDED"   } else { show-speaker-list $payload "INIT INTERVENTION"  } }
            47 { show-removed  $payload "INTERVENTION REMOVED" }
            50 { }  # prev speaker added — ignored
            51 { }  # prev speaker removed — ignored
            11 {  # DelegateLogin
                p-set $payload; $seat = p-long; $del = p-long
                Write-Host "  [LOGIN] seat=$seat  $(get-name $del)"
            }
            default {
                if (-not $initialized) {
                    Write-Host "  [INIT STREAM] cmd=$cmd  $($payload.Length)b"
                }
            }
        } } catch {
            Write-Host "  [PARSE ERROR] cmd=$cmd  $($payload.Length)b  pos=$($script:_pos)  err=$($_.Exception.Message)"
            Write-Host "  [PARSE ERROR] hex=$(($payload | ForEach-Object { $_.ToString('x2') }) -join ' ')"
        }
    }
} finally {
    $tcp.Close()
}
