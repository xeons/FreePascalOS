{
  FreePascalOS
  Copyright (C) 2026 Brandon Scott

  This program is free software: you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation, either version 3 of the License, or
  (at your option) any later version.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with this program.  If not, see <https://www.gnu.org/licenses/>.
}

{
  The destination cache's table (RFC 4861 5.1): what this machine
  learned about single destinations, apart from the routes:
    - the path MTU (RFC 8201), from Packet Too Big messages: smaller
      than the link's, never below 1280, forgotten after its lifetime
      (ten minutes) so that a larger one is tried again;
    - a redirect (RFC 4861 8): a better first hop on the same link (a
      router, or the destination itself), kept for its lifetime.
  An entry holds both and goes when neither is left. The table is a
  fixed array; when it is full the entry used least recently gives way.
  Times are a caller's clock (the network's nanoseconds); nothing here
  reads one, so the host tests drive it with their own. Self-contained.
}
unit Network.DestinationTable;

{$mode objfpc}

interface

const
  MaximumDestinationEntries = 64;
  DestinationAddressBytes = 16;
  { RFC 8200: IPv6 never needs less. }
  MinimumPathMtu = 1280;
  NoExpiry = High(QWord);

type
  TDestinationAddress = array[0..DestinationAddressBytes - 1] of Byte;

  TDestinationEntry = record
    InUse: Boolean;
    Destination: TDestinationAddress;
    { The interface (index) the destination is reached by. }
    InterfaceIndex: LongWord;
    { 0: none learned. }
    PathMtu: LongWord;
    PathMtuExpiresAt: QWord;
    HasRedirect: Boolean;
    RedirectNextHop: TDestinationAddress;
    RedirectExpiresAt: QWord;
    LastUsed: QWord;
  end;

  TDestinationTable = record
    Entries: array[0..MaximumDestinationEntries - 1] of TDestinationEntry;
  end;

procedure ClearDestinationTable(out Table: TDestinationTable);
{ A Packet Too Big for Destination said Mtu (raised to 1280 if lower).
  True if the path MTU became smaller than it was (or than LinkMtu, if
  none was known): TCP then sends smaller segments. }
function RecordPathMtu(var Table: TDestinationTable; constref Destination: TDestinationAddress;
  InterfaceIndex, Mtu, LinkMtu: LongWord; Now, Lifetime: QWord): Boolean;
{ The path MTU learned for Destination, 0 if none (or it expired). }
function LookupPathMtu(var Table: TDestinationTable; constref Destination: TDestinationAddress; Now: QWord): LongWord;
{ A redirect: Destination is reached through NextHop on the interface. }
procedure RecordRedirect(var Table: TDestinationTable; constref Destination, NextHop: TDestinationAddress;
  InterfaceIndex: LongWord; Now, Lifetime: QWord);
{ The first hop a redirect gave for Destination; False if none. }
function LookupRedirect(var Table: TDestinationTable; constref Destination: TDestinationAddress; Now: QWord;
  out NextHop: TDestinationAddress; out InterfaceIndex: LongWord): Boolean;
{ Forgets the redirects whose first hop is NextHop on the interface
  (the router went away). }
procedure ForgetRedirectsThrough(var Table: TDestinationTable; constref NextHop: TDestinationAddress;
  InterfaceIndex: LongWord);
{ Forgets everything learned through the interface (it went down). }
procedure ForgetDestinationsOn(var Table: TDestinationTable; InterfaceIndex: LongWord);
{ Drops what expired; returns the next time something will (NoExpiry if
  nothing will). }
function ExpireDestinations(var Table: TDestinationTable; Now: QWord): QWord;
function DestinationEntryCount(constref Table: TDestinationTable): LongInt;

implementation

procedure ClearDestinationTable(out Table: TDestinationTable);
var
  Index: Integer;
begin
  for Index := 0 to MaximumDestinationEntries - 1 do
  begin
    Table.Entries[Index].InUse := False;
    Table.Entries[Index].PathMtu := 0;
    Table.Entries[Index].HasRedirect := False;
  end;
end;

function SameDestination(constref First, Second: TDestinationAddress): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to DestinationAddressBytes - 1 do
    if First[Index] <> Second[Index] then
      Exit(False);
  Result := True;
end;

function FindEntry(var Table: TDestinationTable; constref Destination: TDestinationAddress): Integer;
var
  Index: Integer;
begin
  for Index := 0 to MaximumDestinationEntries - 1 do
    if Table.Entries[Index].InUse and SameDestination(Table.Entries[Index].Destination, Destination) then
      Exit(Index);
  Result := -1;
end;

{ The entry for Destination, made (pushing out the least recently used
  one if the table is full) if there is none. }
function ObtainEntry(var Table: TDestinationTable; constref Destination: TDestinationAddress; Now: QWord): Integer;
var
  Index: Integer;
begin
  Result := FindEntry(Table, Destination);
  if Result >= 0 then
    Exit;
  Result := 0;
  for Index := 0 to MaximumDestinationEntries - 1 do
  begin
    if not Table.Entries[Index].InUse then
    begin
      Result := Index;
      Break;
    end;
    if Table.Entries[Index].LastUsed < Table.Entries[Result].LastUsed then
      Result := Index;
  end;
  Table.Entries[Result].InUse := True;
  Table.Entries[Result].Destination := Destination;
  Table.Entries[Result].InterfaceIndex := 0;
  Table.Entries[Result].PathMtu := 0;
  Table.Entries[Result].PathMtuExpiresAt := 0;
  Table.Entries[Result].HasRedirect := False;
  Table.Entries[Result].RedirectExpiresAt := 0;
  Table.Entries[Result].LastUsed := Now;
end;

function ExpiryAfter(Now, Lifetime: QWord): QWord;
begin
  if Lifetime >= NoExpiry - Now then
    Result := NoExpiry
  else
    Result := Now + Lifetime;
end;

procedure DropIfEmpty(var Entry: TDestinationEntry);
begin
  if (Entry.PathMtu = 0) and not Entry.HasRedirect then
    Entry.InUse := False;
end;

function RecordPathMtu(var Table: TDestinationTable; constref Destination: TDestinationAddress;
  InterfaceIndex, Mtu, LinkMtu: LongWord; Now, Lifetime: QWord): Boolean;
var
  Position: Integer;
  Previous: LongWord;
begin
  if Mtu < MinimumPathMtu then
    Mtu := MinimumPathMtu;
  if Mtu >= LinkMtu then
    Exit(False);
  { Looked up before the entry is obtained: an expired path MTU makes
    the lookup drop the entry, which must not take the new one with it. }
  Previous := LookupPathMtu(Table, Destination, Now);
  Position := ObtainEntry(Table, Destination, Now);
  if Previous = 0 then
    Previous := LinkMtu;
  Result := Mtu < Previous;
  if Result or (Table.Entries[Position].PathMtu = 0) then
    Table.Entries[Position].PathMtu := Mtu;
  Table.Entries[Position].PathMtuExpiresAt := ExpiryAfter(Now, Lifetime);
  Table.Entries[Position].LastUsed := Now;
  Table.Entries[Position].InterfaceIndex := InterfaceIndex;
end;

function LookupPathMtu(var Table: TDestinationTable; constref Destination: TDestinationAddress; Now: QWord): LongWord;
var
  Position: Integer;
begin
  Position := FindEntry(Table, Destination);
  if Position < 0 then
    Exit(0);
  with Table.Entries[Position] do
  begin
    if (PathMtu <> 0) and (PathMtuExpiresAt <= Now) then
    begin
      PathMtu := 0;
      DropIfEmpty(Table.Entries[Position]);
    end;
    Result := PathMtu;
    if Result <> 0 then
      LastUsed := Now;
  end;
end;

procedure RecordRedirect(var Table: TDestinationTable; constref Destination, NextHop: TDestinationAddress;
  InterfaceIndex: LongWord; Now, Lifetime: QWord);
var
  Position: Integer;
begin
  Position := ObtainEntry(Table, Destination, Now);
  Table.Entries[Position].InterfaceIndex := InterfaceIndex;
  Table.Entries[Position].HasRedirect := True;
  Table.Entries[Position].RedirectNextHop := NextHop;
  Table.Entries[Position].RedirectExpiresAt := ExpiryAfter(Now, Lifetime);
  Table.Entries[Position].LastUsed := Now;
end;

function LookupRedirect(var Table: TDestinationTable; constref Destination: TDestinationAddress; Now: QWord;
  out NextHop: TDestinationAddress; out InterfaceIndex: LongWord): Boolean;
var
  Position: Integer;
  Entry: ^TDestinationEntry;
begin
  NextHop := Destination;
  InterfaceIndex := 0;
  Position := FindEntry(Table, Destination);
  if Position < 0 then
    Exit(False);
  { No "with" here: the entry's InterfaceIndex field would hide the
    parameter of the same name. }
  Entry := @Table.Entries[Position];
  if Entry^.HasRedirect and (Entry^.RedirectExpiresAt <= Now) then
  begin
    Entry^.HasRedirect := False;
    DropIfEmpty(Entry^);
  end;
  Result := Entry^.HasRedirect;
  if Result then
  begin
    NextHop := Entry^.RedirectNextHop;
    InterfaceIndex := Entry^.InterfaceIndex;
    Entry^.LastUsed := Now;
  end;
end;

procedure ForgetRedirectsThrough(var Table: TDestinationTable; constref NextHop: TDestinationAddress;
  InterfaceIndex: LongWord);
var
  Index: Integer;
  Entry: ^TDestinationEntry;
begin
  for Index := 0 to MaximumDestinationEntries - 1 do
  begin
    Entry := @Table.Entries[Index];
    if Entry^.InUse and Entry^.HasRedirect and (Entry^.InterfaceIndex = InterfaceIndex) and
       SameDestination(Entry^.RedirectNextHop, NextHop) then
    begin
      Entry^.HasRedirect := False;
      DropIfEmpty(Entry^);
    end;
  end;
end;

procedure ForgetDestinationsOn(var Table: TDestinationTable; InterfaceIndex: LongWord);
var
  Index: Integer;
begin
  for Index := 0 to MaximumDestinationEntries - 1 do
    if Table.Entries[Index].InUse and (Table.Entries[Index].InterfaceIndex = InterfaceIndex) then
    begin
      Table.Entries[Index].InUse := False;
      Table.Entries[Index].PathMtu := 0;
      Table.Entries[Index].HasRedirect := False;
    end;
end;

function ExpireDestinations(var Table: TDestinationTable; Now: QWord): QWord;
var
  Index: Integer;
begin
  Result := NoExpiry;
  for Index := 0 to MaximumDestinationEntries - 1 do
    with Table.Entries[Index] do
    begin
      if not InUse then
        Continue;
      if (PathMtu <> 0) and (PathMtuExpiresAt <= Now) then
        PathMtu := 0;
      if HasRedirect and (RedirectExpiresAt <= Now) then
        HasRedirect := False;
      DropIfEmpty(Table.Entries[Index]);
      if not InUse then
        Continue;
      if (PathMtu <> 0) and (PathMtuExpiresAt < Result) then
        Result := PathMtuExpiresAt;
      if HasRedirect and (RedirectExpiresAt < Result) then
        Result := RedirectExpiresAt;
    end;
end;

function DestinationEntryCount(constref Table: TDestinationTable): LongInt;
var
  Index: Integer;
begin
  Result := 0;
  for Index := 0 to MaximumDestinationEntries - 1 do
    if Table.Entries[Index].InUse then
      Inc(Result);
end;

end.
