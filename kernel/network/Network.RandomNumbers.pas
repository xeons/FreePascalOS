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
  Random numbers for the network stack: temporary interface identifiers,
  the first stable-privacy secret, fragment identifications, the jitter
  of timers. From the processor's generator (RDRAND, RNDR) where there
  is one, else from a xorshift generator stirred with the time stamp
  counter. Under the network lock.
}
unit Network.RandomNumbers;

{$mode objfpc}
{$rangechecks off}
{$overflowchecks off}

interface

function NetworkRandom: QWord;
{ A random number from 0 to Limit - 1 (Limit > 0). }
function NetworkRandomBelow(Limit: QWord): QWord;
procedure FillNetworkRandom(Buffer: PByte; Length: LongWord);

implementation

uses
  Kernel.Arch.Cpu;

var
  FallbackState: QWord = $1E3779B97F4A7C15;

function NextFallbackRandom: QWord;
var
  State: QWord;
begin
  State := FallbackState xor ReadTimeStampCounter;
  State := State xor (State shl 13);
  State := State xor (State shr 7);
  State := State xor (State shl 17);
  FallbackState := State;
  Result := State * QWord($2545F4914F6CDD1D);
end;

function NetworkRandom: QWord;
begin
  if not ReadHardwareRandom(Result) then
    Result := NextFallbackRandom;
end;

function NetworkRandomBelow(Limit: QWord): QWord;
begin
  Result := NetworkRandom mod Limit;
end;

procedure FillNetworkRandom(Buffer: PByte; Length: LongWord);
var
  Value: QWord;
  Index: LongWord;
  Part: Integer;
begin
  Index := 0;
  while Index < Length do
  begin
    Value := NetworkRandom;
    for Part := 0 to 7 do
    begin
      if Index >= Length then
        Break;
      Buffer[Index] := Byte(Value shr (Part * 8));
      Inc(Index);
    end;
  end;
end;

end.
