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
  Unpredictable numbers for what libsystem itself needs them for (the
  DNS resolver's query ids and source ports, a DHCP client's transaction
  ids), read from /dev/urandom, the kernel's generator. Programs that
  need many, or keys, use libcryptography (Crypto.Random).

  Should /dev/urandom not open (a chroot without /dev), the clock and
  the process id are mixed instead: not secret, but different each time.
}
unit Sys.RandomNumbers;

{$mode objfpc}
{$pointermath on}

interface

procedure FillRandomBytes(Destination: PByte; Count: QWord);
function RandomWord: Word;
function RandomLongWord: LongWord;
{ A number from 0 to Bound - 1. }
function RandomBelow(Bound: LongWord): LongWord;

implementation

uses
  Abi.SystemCalls,
  Sys.Kernel,
  Sys.Files;

var
  FallbackState: QWord;

function NextFallbackValue: QWord;
begin
  if FallbackState = 0 then
    FallbackState := QWord(KernelGetTime(TimeUptimeNanoseconds)) xor (QWord(KernelGetProcessId(-1)) shl 32) or 1;
  { xorshift64 }
  FallbackState := FallbackState xor (FallbackState shl 13);
  FallbackState := FallbackState xor (FallbackState shr 7);
  FallbackState := FallbackState xor (FallbackState shl 17);
  Result := FallbackState;
end;

procedure FillRandomBytes(Destination: PByte; Count: QWord);
var
  Handle: Int64;
  Read: Int64;
  Index: QWord;
begin
  Read := 0;
  Handle := OpenFile('/dev/urandom', OpenRead);
  if Handle >= 0 then
  begin
    Read := ReadFile(Handle, Destination, Count);
    CloseFile(Handle);
  end;
  if (Read >= 0) and (QWord(Read) = Count) then
    Exit;
  Index := 0;
  while Index < Count do
  begin
    Destination[Index] := Byte(NextFallbackValue shr 24);
    Inc(Index);
  end;
end;

function RandomWord: Word;
begin
  FillRandomBytes(@Result, SizeOf(Result));
end;

function RandomLongWord: LongWord;
begin
  FillRandomBytes(@Result, SizeOf(Result));
end;

function RandomBelow(Bound: LongWord): LongWord;
begin
  if Bound <= 1 then
    Exit(0);
  Result := LongWord(QWord(RandomLongWord) * Bound shr 32);
end;

end.
