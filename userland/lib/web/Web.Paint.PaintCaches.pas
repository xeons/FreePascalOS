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
  A cache of pixels the rasterizer worked out (blurred shadow masks,
  scaled images), so that painting the same page again does not do the
  work again.

  An entry is found by its key, the bytes of a packed record its user
  fills in (every byte of it: the record is cleared first). It holds a
  block from GetMem, freed when the entry goes. The cache keeps at most
  ByteLimit bytes: adding an entry drops the least recently used ones
  until it fits. There are few entries (hundreds), so they are found by
  a scan comparing hashes first.
}
unit Web.Paint.PaintCaches;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

type
  PPaintCacheEntry = ^TPaintCacheEntry;
  TPaintCacheEntry = record
    Key: RawByteString;
    Hash: QWord;
    { The pixels (GetMem; the cache frees them), Bytes long. }
    Data: Pointer;
    Bytes: PtrUInt;
    Width, Height: LongInt;
    { The user's: what the entry was made from (a checksum of the
      source) and when that was last checked (a display list
      revision). }
    Fingerprint: QWord;
    Revision: LongWord;
    LastUse: QWord;
  end;

  TPaintCache = class
  private
    FEntries: array of PPaintCacheEntry;
    FCount: Integer;
    FBytes: PtrUInt;
    FByteLimit: PtrUInt;
    FUseClock: QWord;
    procedure RemoveAt(Index: Integer);
    procedure DropLeastRecentlyUsed;
  public
    constructor Create(ByteLimit: PtrUInt);
    destructor Destroy; override;
    { The entry for the key (KeySize bytes at Key), marked as used; nil
      when there is none. }
    function Find(const Key; KeySize: Integer): PPaintCacheEntry;
    { A new entry for the key holding Data (Bytes long, from GetMem; the
      cache takes it). nil when it is bigger than the whole budget (Data
      is freed then). }
    function Add(const Key; KeySize: Integer; Data: Pointer; Bytes: PtrUInt; Width, Height: LongInt): PPaintCacheEntry;
    { The entry goes (its pixels are freed). }
    procedure Remove(Entry: PPaintCacheEntry);
    procedure Clear;
    property ByteLimit: PtrUInt read FByteLimit;
  end;

{ A 64-bit hash of Count bytes (also a checksum of pixels). }
function HashBytes(Data: PByte; Count: PtrUInt): QWord;

implementation

function HashBytes(Data: PByte; Count: PtrUInt): QWord;
const
  Multiplier = QWord($9E3779B97F4A7C15);
var
  Words: PQWord;
  First, Second, Third, Fourth: QWord;
  Index, BlockCount, WordCount: PtrInt;
begin
  { Four lanes of 8 bytes each, independent of each other so that the
    processor works on them at once (a checksum of a large image every
    time the display list is built must be cheap), then the rest. }
  First := QWord($CBF29CE484222325);
  Second := First + Multiplier;
  Third := Second + Multiplier;
  Fourth := Third + Multiplier;
  Words := PQWord(Data);
  BlockCount := PtrInt(Count div 32);
  for Index := 0 to BlockCount - 1 do
  begin
    First := (RolQWord(First, 23) xor Words[0]) * Multiplier;
    Second := (RolQWord(Second, 23) xor Words[1]) * Multiplier;
    Third := (RolQWord(Third, 23) xor Words[2]) * Multiplier;
    Fourth := (RolQWord(Fourth, 23) xor Words[3]) * Multiplier;
    Inc(Words, 4);
  end;
  Result := (RolQWord(Count, 23) xor First) * Multiplier;
  Result := (RolQWord(Result, 23) xor Second) * Multiplier;
  Result := (RolQWord(Result, 23) xor Third) * Multiplier;
  Result := (RolQWord(Result, 23) xor Fourth) * Multiplier;
  Words := PQWord(Data);
  WordCount := PtrInt(Count div 8);
  for Index := BlockCount * 4 to WordCount - 1 do
    Result := (RolQWord(Result, 23) xor Words[Index]) * Multiplier;
  for Index := WordCount * 8 to PtrInt(Count) - 1 do
    Result := (RolQWord(Result, 23) xor Data[Index]) * Multiplier;
  Result := Result xor (Result shr 29);
end;

constructor TPaintCache.Create(ByteLimit: PtrUInt);
begin
  inherited Create;
  FByteLimit := ByteLimit;
end;

destructor TPaintCache.Destroy;
begin
  Clear;
  inherited Destroy;
end;

procedure TPaintCache.RemoveAt(Index: Integer);
var
  Entry: PPaintCacheEntry;
begin
  Entry := FEntries[Index];
  Dec(FBytes, Entry^.Bytes);
  FreeMem(Entry^.Data);
  Dispose(Entry);
  FEntries[Index] := FEntries[FCount - 1];
  Dec(FCount);
end;

procedure TPaintCache.DropLeastRecentlyUsed;
var
  Index, Oldest: Integer;
begin
  if FCount = 0 then
    Exit;
  Oldest := 0;
  for Index := 1 to FCount - 1 do
    if FEntries[Index]^.LastUse < FEntries[Oldest]^.LastUse then
      Oldest := Index;
  RemoveAt(Oldest);
end;

function TPaintCache.Find(const Key; KeySize: Integer): PPaintCacheEntry;
var
  Hash: QWord;
  Index: Integer;
begin
  Hash := HashBytes(@Key, KeySize);
  for Index := 0 to FCount - 1 do
  begin
    Result := FEntries[Index];
    if (Result^.Hash = Hash) and (Length(Result^.Key) = KeySize) and
       (CompareByte(Result^.Key[1], Key, KeySize) = 0) then
    begin
      Inc(FUseClock);
      Result^.LastUse := FUseClock;
      Exit;
    end;
  end;
  Result := nil;
end;

function TPaintCache.Add(const Key; KeySize: Integer; Data: Pointer; Bytes: PtrUInt; Width,
  Height: LongInt): PPaintCacheEntry;
begin
  if Bytes > FByteLimit then
  begin
    FreeMem(Data);
    Exit(nil);
  end;
  while (FCount > 0) and (FBytes + Bytes > FByteLimit) do
    DropLeastRecentlyUsed;
  New(Result);
  Result^ := Default(TPaintCacheEntry);
  SetLength(Result^.Key, KeySize);
  Move(Key, Result^.Key[1], KeySize);
  Result^.Hash := HashBytes(@Key, KeySize);
  Result^.Data := Data;
  Result^.Bytes := Bytes;
  Result^.Width := Width;
  Result^.Height := Height;
  Inc(FUseClock);
  Result^.LastUse := FUseClock;
  if FCount >= Length(FEntries) then
    SetLength(FEntries, FCount * 2 + 16);
  FEntries[FCount] := Result;
  Inc(FCount);
  Inc(FBytes, Bytes);
end;

procedure TPaintCache.Remove(Entry: PPaintCacheEntry);
var
  Index: Integer;
begin
  for Index := 0 to FCount - 1 do
    if FEntries[Index] = Entry then
    begin
      RemoveAt(Index);
      Exit;
    end;
end;

procedure TPaintCache.Clear;
begin
  while FCount > 0 do
    RemoveAt(FCount - 1);
end;

end.
