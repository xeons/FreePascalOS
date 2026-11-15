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
  ACPI resource templates (the buffers _CRS, _PRS and _SRS deal in):
  finding the interrupts in them.

  A template is a run of descriptors ending with an end tag. Small ones
  have their type and length in one byte; large ones a type byte and a
  16-bit length. Interrupts are in the small IRQ descriptor (a mask of
  ISA IRQs, and flags: edge or level, active high or low) and the large
  extended interrupt descriptor (a list of global system interrupts,
  with the same flags).
}
unit Firmware.AcpiResources;

{$mode objfpc}
{$pointermath on}

interface

type
  TInterruptResource = record
    { The descriptor's interrupts. }
    Count: Integer;
    Interrupts: array[0..15] of LongWord;
    LevelTriggered: Boolean;
    ActiveLow: Boolean;
    Shared: Boolean;
    { Where it is in the template, and whether it is the extended kind. }
    Offset: LongWord;
    Extended: Boolean;
  end;

{ The first interrupt descriptor in a template; False if there is none. }
function FindInterruptResource(Data: PByte; Length: LongWord; out Resource: TInterruptResource): Boolean;
{ A template with one interrupt descriptor, like Resource's but naming
  only Interrupt, into Data (at least 16 bytes); returns its length. }
function MakeInterruptTemplate(const Resource: TInterruptResource; Interrupt: LongWord; Data: PByte): LongWord;

implementation

uses
  Runtime.Memory;

const
  SmallIrq = $04;
  SmallEnd = $0F;
  LargeExtendedInterrupt = $09;

function FindInterruptResource(Data: PByte; Length: LongWord; out Resource: TInterruptResource): Boolean;
var
  Position: LongWord;
  Tag: Byte;
  Size: LongWord;
  Mask: Word;
  Flags: Byte;
  Bit: Integer;
  Index: LongWord;
begin
  ZeroMemory(@Resource, SizeOf(Resource));
  Result := False;
  Position := 0;
  while Position < Length do
  begin
    Tag := Data[Position];
    if (Tag and $80) = 0 then
    begin
      Size := Tag and 7;
      if ((Tag shr 3) and $F) = SmallEnd then
        Exit;
      if (((Tag shr 3) and $F) = SmallIrq) and (Size >= 2) and (Position + 1 + Size <= Length) then
      begin
        Mask := Data[Position + 1] or (Word(Data[Position + 2]) shl 8);
        { Without the flags byte: edge triggered, active high. }
        Flags := 1;
        if Size >= 3 then
          Flags := Data[Position + 3];
        Resource.LevelTriggered := (Flags and 1) = 0;
        Resource.ActiveLow := (Flags and 8) <> 0;
        Resource.Shared := (Flags and $10) <> 0;
        for Bit := 0 to 15 do
          if (Mask and (1 shl Bit)) <> 0 then
          begin
            Resource.Interrupts[Resource.Count] := Bit;
            Inc(Resource.Count);
          end;
        Resource.Offset := Position;
        Exit(True);
      end;
      Position := Position + 1 + Size;
    end
    else
    begin
      if Position + 3 > Length then
        Exit;
      Size := Data[Position + 1] or (LongWord(Data[Position + 2]) shl 8);
      if ((Tag and $7F) = LargeExtendedInterrupt) and (Size >= 6) and (Position + 3 + Size <= Length) then
      begin
        Flags := Data[Position + 3];
        Resource.LevelTriggered := (Flags and 2) = 0;
        Resource.ActiveLow := (Flags and 4) <> 0;
        Resource.Shared := (Flags and 8) <> 0;
        Index := 0;
        while (Index < Data[Position + 4]) and (Index < 16) and (5 + Index * 4 + 4 <= Size + 3) do
        begin
          Resource.Interrupts[Index] := PLongWord(Data + Position + 5 + Index * 4)^;
          Inc(Index);
        end;
        Resource.Count := Index;
        Resource.Offset := Position;
        Resource.Extended := True;
        Exit(True);
      end;
      Position := Position + 3 + Size;
    end;
  end;
end;

function MakeInterruptTemplate(const Resource: TInterruptResource; Interrupt: LongWord; Data: PByte): LongWord;
var
  Flags: Byte;
begin
  if Resource.Extended then
  begin
    Flags := 1; { consumer }
    if not Resource.LevelTriggered then
      Flags := Flags or 2;
    if Resource.ActiveLow then
      Flags := Flags or 4;
    if Resource.Shared then
      Flags := Flags or 8;
    Data[0] := $80 or LargeExtendedInterrupt;
    Data[1] := 6;
    Data[2] := 0;
    Data[3] := Flags;
    Data[4] := 1;
    PLongWord(Data + 5)^ := Interrupt;
    Result := 9;
  end
  else
  begin
    Flags := 0;
    if not Resource.LevelTriggered then
      Flags := 1;
    if Resource.ActiveLow then
      Flags := Flags or 8;
    if Resource.Shared then
      Flags := Flags or $10;
    Data[0] := (SmallIrq shl 3) or 3;
    Data[1] := Byte(Word(1 shl (Interrupt and 15)));
    Data[2] := Byte(Word(1 shl (Interrupt and 15)) shr 8);
    Data[3] := Flags;
    Result := 4;
  end;
  { The end tag, with a zero checksum. }
  Data[Result] := (SmallEnd shl 3) or 1;
  Data[Result + 1] := 0;
  Result := Result + 2;
end;

end.
