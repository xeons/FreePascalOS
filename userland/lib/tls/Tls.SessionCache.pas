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
  The session tickets a process has been given (RFC 8446 section 4.6.1),
  kept in memory by a key the program chooses ("host:port"), for the
  next connection to the same server to resume with (a PSK with a fresh
  (EC)DHE exchange; no early data).

  A ticket is used once: taking it removes it (section C.4 asks clients
  not to reuse tickets), and the server hands out new ones on the
  resumed connection. A ticket lives as long as the server said, seven
  days at most; old ones are dropped when a key has too many. Nothing
  is written to disk. The cache is guarded by a spin lock, so threads
  may share it.
}
unit Tls.SessionCache;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Crypto.Digests,
  Tls.KeySchedule;

const
  MaximumTicketsPerKey = 4;
  MaximumCachedTickets = 64;
  { RFC 8446 section 4.6.1: seven days. }
  MaximumTicketLifetimeSeconds = 7 * 24 * 60 * 60;

type
  TTlsSessionTicket = record
    Ticket: TBytes;
    { The resumption PSK and the hash it goes with (the suite's). }
    Psk: TTlsSecret;
    Hash: TDigestAlgorithm;
    Suite: Word;
    AgeAdd: LongWord;
    LifetimeSeconds: LongWord;
    { When it arrived, in milliseconds (the program's clock). }
    ReceivedAt: Int64;
  end;

procedure StoreSessionTicket(const Key: string; constref Ticket: TTlsSessionTicket);
{ The newest live ticket for Key, taken out of the cache. Now is in
  milliseconds. }
function TakeSessionTicket(const Key: string; Now: Int64; out Ticket: TTlsSessionTicket): Boolean;
function CachedTicketCount(const Key: string): Integer;
procedure ClearSessionCache;
procedure WipeSessionTicket(var Ticket: TTlsSessionTicket);

implementation

uses
  Crypto.Bits;

type
  TCacheEntry = record
    Key: string;
    Ticket: TTlsSessionTicket;
  end;

var
  Entries: array of TCacheEntry;
  CacheLock: LongInt = 0;

procedure Lock;
begin
  while InterlockedExchange(CacheLock, 1) <> 0 do
    ThreadSwitch;
end;

procedure Unlock;
begin
  InterlockedExchange(CacheLock, 0);
end;

procedure WipeSessionTicket(var Ticket: TTlsSessionTicket);
begin
  if Length(Ticket.Ticket) > 0 then
    WipeMemory(@Ticket.Ticket[0], Length(Ticket.Ticket));
  Ticket.Ticket := nil;
  WipeMemory(@Ticket.Psk[0], SizeOf(Ticket.Psk));
end;

procedure RemoveEntry(Index: Integer);
begin
  WipeSessionTicket(Entries[Index].Ticket);
  Delete(Entries, Index, 1);
end;

function CountForKey(const Key: string): Integer;
var
  Index: Integer;
begin
  Result := 0;
  for Index := 0 to High(Entries) do
    if Entries[Index].Key = Key then
      Inc(Result);
end;

{ The oldest entry for Key (or of all, when Key is empty). }
function OldestEntry(const Key: string): Integer;
var
  Index: Integer;
begin
  Result := -1;
  for Index := 0 to High(Entries) do
    if (Key = '') or (Entries[Index].Key = Key) then
      if (Result < 0) or (Entries[Index].Ticket.ReceivedAt < Entries[Result].Ticket.ReceivedAt) then
        Result := Index;
end;

procedure StoreSessionTicket(const Key: string; constref Ticket: TTlsSessionTicket);
var
  Entry: TCacheEntry;
begin
  if (Key = '') or (Length(Ticket.Ticket) = 0) or (Ticket.LifetimeSeconds = 0) then
    Exit;
  Entry.Key := Key;
  Entry.Ticket := Ticket;
  Entry.Ticket.Ticket := Copy(Ticket.Ticket);
  if Entry.Ticket.LifetimeSeconds > MaximumTicketLifetimeSeconds then
    Entry.Ticket.LifetimeSeconds := MaximumTicketLifetimeSeconds;
  Lock;
  try
    while CountForKey(Key) >= MaximumTicketsPerKey do
      RemoveEntry(OldestEntry(Key));
    while Length(Entries) >= MaximumCachedTickets do
      RemoveEntry(OldestEntry(''));
    Insert(Entry, Entries, Length(Entries));
  finally
    Unlock;
  end;
end;

function TicketIsLive(constref Ticket: TTlsSessionTicket; Now: Int64): Boolean;
begin
  Result := (Now >= Ticket.ReceivedAt) and (Now - Ticket.ReceivedAt < Int64(Ticket.LifetimeSeconds) * 1000);
end;

function TakeSessionTicket(const Key: string; Now: Int64; out Ticket: TTlsSessionTicket): Boolean;
var
  Index, Newest: Integer;
begin
  Ticket := Default(TTlsSessionTicket);
  Result := False;
  Lock;
  try
    { Dead tickets go first. }
    Index := 0;
    while Index < Length(Entries) do
      if not TicketIsLive(Entries[Index].Ticket, Now) then
        RemoveEntry(Index)
      else
        Inc(Index);
    Newest := -1;
    for Index := 0 to High(Entries) do
      if Entries[Index].Key = Key then
        if (Newest < 0) or (Entries[Index].Ticket.ReceivedAt >= Entries[Newest].Ticket.ReceivedAt) then
          Newest := Index;
    if Newest >= 0 then
    begin
      Ticket := Entries[Newest].Ticket;
      Ticket.Ticket := Copy(Entries[Newest].Ticket.Ticket);
      RemoveEntry(Newest);
      Result := True;
    end;
  finally
    Unlock;
  end;
end;

function CachedTicketCount(const Key: string): Integer;
begin
  Lock;
  try
    Result := CountForKey(Key);
  finally
    Unlock;
  end;
end;

procedure ClearSessionCache;
begin
  Lock;
  try
    while Length(Entries) > 0 do
      RemoveEntry(High(Entries));
  finally
    Unlock;
  end;
end;

end.
