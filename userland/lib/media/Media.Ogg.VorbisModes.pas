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
  How long a Vorbis packet is, without decoding it: what the containers
  need for exact timestamps.

  The identification header gives the two block sizes; an audio packet
  starts with a 0 bit and its mode number (ilog(modes - 1) bits), and the
  mode's block flag picks the size. The modes are the last thing in the
  setup header, before its framing bit, 41 bits each (block flag, window
  type 0, transform type 0, mapping number), preceded by the mode count
  less one (6 bits): rather than parse the codebooks, floors and residues
  before them, they are found by reading backwards from the framing bit
  while they look like modes, taking the longest run whose count field
  agrees.

  Packet durations follow the convention of counting each packet as half
  of the previous block and half of its own (prev / 4 + current / 4), the
  first as though the previous block were the same size; a decoder gives
  nothing for the first packet, so the decoded total is the sum less the
  first packet's.
}
unit Media.Ogg.VorbisModes;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils;

type
  TVorbisModes = record
    Valid: Boolean;
    ShortBlock, LongBlock: Integer;
    ModeCount: Integer;
    ModeBits: Integer;
    LongFlags: array[0..63] of Boolean;
    { The previous packet's block size; 0 before the first. }
    PreviousBlock: Integer;
  end;

{ Reads the identification header (Identification) and the modes of the
  setup header (Setup); Valid is False if they are not Vorbis headers. }
function ReadVorbisModes(const Identification, Setup: TBytes): TVorbisModes;
{ The block size of an audio packet; 0 if it is not one. }
function VorbisBlockSize(const Modes: TVorbisModes; const Packet: TBytes): Integer;
{ The packet's duration (and Modes.PreviousBlock moves on); 0 for a
  header or empty packet. }
function VorbisPacketDuration(var Modes: TVorbisModes; const Packet: TBytes): Integer;

implementation

function BitAt(const Bytes: TBytes; Position: Integer): Integer; inline;
begin
  Result := (Bytes[Position shr 3] shr (Position and 7)) and 1;
end;

{ Count bits from Position, least significant first, as the Vorbis bit
  packer writes them. }
function BitsAt(const Bytes: TBytes; Position, Count: Integer): LongWord;
var
  Index: Integer;
begin
  Result := 0;
  for Index := Count - 1 downto 0 do
    Result := (Result shl 1) or LongWord(BitAt(Bytes, Position + Index));
end;

function IntegerLog(Value: Integer): Integer;
begin
  Result := 0;
  while Value > 0 do
  begin
    Inc(Result);
    Value := Value shr 1;
  end;
end;

function ReadVorbisModes(const Identification, Setup: TBytes): TVorbisModes;
const
  ModeBitsEach = 41;
var
  Framing, Count, Best, Start, Mode: Integer;
  Exponents: Byte;
begin
  Result := Default(TVorbisModes);
  if (Length(Identification) < 30) or (Identification[0] <> 1) or (Length(Setup) < 8) or (Setup[0] <> 5) then
    Exit;
  Exponents := Identification[28];
  Result.ShortBlock := 1 shl (Exponents and 15);
  Result.LongBlock := 1 shl (Exponents shr 4);
  if (Result.ShortBlock < 64) or (Result.LongBlock < Result.ShortBlock) or (Result.LongBlock > 8192) then
    Exit;
  { The framing bit: the last 1 bit of the packet. }
  Framing := Length(Setup) * 8 - 1;
  while (Framing >= 56) and (BitAt(Setup, Framing) = 0) do
    Dec(Framing);
  if Framing < 56 then
    Exit;
  Count := 0;
  Best := 0;
  while Count < 64 do
  begin
    Start := Framing - ModeBitsEach * (Count + 1);
    if Start < 56 + 6 then
      Break;
    if (BitsAt(Setup, Start + 1, 16) <> 0) or (BitsAt(Setup, Start + 17, 16) <> 0) or
      (BitsAt(Setup, Start + 33, 8) >= 64) then
      Break;
    Inc(Count);
    if Integer(BitsAt(Setup, Start - 6, 6)) + 1 = Count then
      Best := Count;
  end;
  if Best = 0 then
    Exit;
  Result.ModeCount := Best;
  Result.ModeBits := IntegerLog(Best - 1);
  for Mode := 0 to Best - 1 do
    Result.LongFlags[Mode] := BitAt(Setup, Framing - ModeBitsEach * (Best - Mode)) = 1;
  Result.Valid := True;
end;

function VorbisBlockSize(const Modes: TVorbisModes; const Packet: TBytes): Integer;
var
  Mode: Integer;
begin
  Result := 0;
  if not Modes.Valid or (Length(Packet) = 0) or ((Packet[0] and 1) <> 0) then
    Exit;
  if Modes.ModeBits > 0 then
  begin
    if Length(Packet) * 8 < 1 + Modes.ModeBits then
      Exit;
    Mode := BitsAt(Packet, 1, Modes.ModeBits);
  end
  else
    Mode := 0;
  if Mode >= Modes.ModeCount then
    Exit;
  if Modes.LongFlags[Mode] then
    Result := Modes.LongBlock
  else
    Result := Modes.ShortBlock;
end;

function VorbisPacketDuration(var Modes: TVorbisModes; const Packet: TBytes): Integer;
var
  Block: Integer;
begin
  Block := VorbisBlockSize(Modes, Packet);
  if Block = 0 then
    Exit(0);
  if Modes.PreviousBlock = 0 then
    Result := Block div 2
  else
    Result := Modes.PreviousBlock div 4 + Block div 4;
  Modes.PreviousBlock := Block;
end;

end.
