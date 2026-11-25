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
  Interrupt remapping: device interrupts named by an entry of the
  IOMMU's table instead of a processor's 8-bit APIC id, so they can
  reach every processor, x2APIC ids above 255 included.

  Without it an I/O APIC entry or a message names its processor in 8
  bits, and interrupts for a processor whose id is larger go to the
  boot processor instead (Hal.InterruptController). With it each route
  takes an entry (Intel VT-d: Hal.IntelRemapping; AMD-Vi:
  Hal.AmdRemapping) holding the vector and the full destination, and
  the I/O APIC entry or the message is written in the remappable form:
  - VT-d: the I/O APIC entry's format bit (48) and handle (bits 63-49
    and 11), its vector field still the real vector (the I/O APIC
    matches end-of-interrupt messages against it); a message's address
    with the format bit (4) and the handle (bits 19-5 and 2), data 0;
  - AMD-Vi: the index in the source's table goes where the vector was
    (an I/O APIC entry's vector field, a message's data); the index of
    an I/O APIC's entry is its vector where that slot is free, for the
    same reason.
  The I/O APICs' and the devices' source ids are their requester ids
  (the DMAR's device scope, the IVRS's special entries; bus, device and
  function for PCI).

  It is turned on where a processor's APIC id is above 255 and the
  firmware describes an IOMMU that can (kernel option intremap=on turns
  it on wherever it can, the tests' way; intremap=off never), with
  extended (32-bit) destinations when the local APICs are in x2APIC
  mode. After suspend to RAM it is turned on again before the I/O APIC
  entries are written back.
}
unit Hal.InterruptRemapping;

{$mode objfpc}

interface

type
  TRemappingKind = (RemappingNone, RemappingIntel, RemappingAmd);

{ Before any interrupt is routed: turns remapping on if it is wanted and
  possible. }
procedure StartInterruptRemapping;
function InterruptRemappingKind: TRemappingKind;
procedure ResumeInterruptRemapping;
{ The I/O APIC entry (low and high words) for Vector to Destination,
  from the I/O APIC with id IoApicId. False if no entry was left. }
function RemapIoApicEntry(IoApicId: Byte; Vector: Byte; Destination: LongWord; ActiveLow, LevelTriggered: Boolean;
  out Low, High: LongWord): Boolean;
{ A message for Vector to Destination from requester RequesterId. }
function RemapMessage(RequesterId: LongWord; Vector: Byte; Destination: LongWord; out Address: QWord;
  out Data: LongWord): Boolean;
procedure WriteInterruptRemapping;

implementation

uses
  Runtime.Text,
  Kernel.Options,
  Firmware.Madt,
  Hal.LocalApic,
  Hal.IntelRemapping,
  Hal.AmdRemapping,
  Debug.Output;

const
  EntryActiveLow = $2000;
  EntryLevelTriggered = $8000;
  IntelEntryFormat = LongWord(1) shl 16;
  IntelHandleHighShift = 11;
  IntelHandleLowShift = 17;
  MessageAddressBase = $FEE00000;
  IntelMessageFormat = 1 shl 4;
  IntelMessageHandleLowShift = 5;
  IntelMessageHandleHighShift = 2;
  HighestLegacyApicId = 255;

var
  Kind: TRemappingKind = RemappingNone;
  ExtendedIds: Boolean = False;

function OptionIs(Value: PChar): Boolean;
var
  Text: array[0..15] of Char;
begin
  Result := GetKernelOptionValue('intremap', @Text[0], SizeOf(Text)) and TextIsEqual(@Text[0], Value);
end;

function SomeApicIdIsWide: Boolean;
var
  Index: Integer;
begin
  for Index := 0 to ListedProcessorCount - 1 do
    if ListedProcessorApicId(Index) > HighestLegacyApicId then
      Exit(True);
  Result := False;
end;

procedure StartInterruptRemapping;
begin
  if OptionIs('off') or (not OptionIs('on') and not SomeApicIdIsWide) then
    Exit;
  ExtendedIds := LocalApicUsesX2ApicMode;
  if StartIntelRemapping(ExtendedIds) then
    Kind := RemappingIntel
  else if StartAmdRemapping(ExtendedIds) then
    Kind := RemappingAmd;
  WriteInterruptRemapping;
end;

function InterruptRemappingKind: TRemappingKind;
begin
  Result := Kind;
end;

procedure ResumeInterruptRemapping;
begin
  case Kind of
    RemappingIntel: ResumeIntelRemapping;
    RemappingAmd: ResumeAmdRemapping;
  end;
end;

function RemapIoApicEntry(IoApicId: Byte; Vector: Byte; Destination: LongWord; ActiveLow, LevelTriggered: Boolean;
  out Low, High: LongWord): Boolean;
var
  Handle: LongInt;
begin
  Low := 0;
  High := 0;
  case Kind of
    RemappingIntel:
      begin
        Handle := AddIntelRemapEntry(Vector, Destination, LevelTriggered, IntelIoApicSourceId(IoApicId));
        if Handle < 0 then
          Exit(False);
        Low := Vector or (LongWord((Handle shr 15) and 1) shl IntelHandleHighShift);
        High := IntelEntryFormat or (LongWord(Handle and $7FFF) shl IntelHandleLowShift);
      end;
    RemappingAmd:
      begin
        Handle := AddAmdRemapEntry(AmdIoApicSourceId(IoApicId), Vector, Destination, Vector);
        if Handle < 0 then
          Exit(False);
        Low := LongWord(Handle and $FF);
      end;
  else
    Exit(False);
  end;
  if ActiveLow then
    Low := Low or EntryActiveLow;
  if LevelTriggered then
    Low := Low or EntryLevelTriggered;
  Result := True;
end;

function RemapMessage(RequesterId: LongWord; Vector: Byte; Destination: LongWord; out Address: QWord;
  out Data: LongWord): Boolean;
var
  Handle: LongInt;
begin
  Address := MessageAddressBase;
  Data := 0;
  case Kind of
    RemappingIntel:
      begin
        Handle := AddIntelRemapEntry(Vector, Destination, False, RequesterId);
        if Handle < 0 then
          Exit(False);
        Address := Address or IntelMessageFormat or (QWord(Handle and $7FFF) shl IntelMessageHandleLowShift) or
          (QWord((Handle shr 15) and 1) shl IntelMessageHandleHighShift);
      end;
    RemappingAmd:
      begin
        Handle := AddAmdRemapEntry(RequesterId, Vector, Destination, Vector);
        if Handle < 0 then
          Exit(False);
        Data := LongWord(Handle);
      end;
  else
    Exit(False);
  end;
  Result := True;
end;

procedure WriteInterruptRemapping;
begin
  DebugBeginMessage;
  DebugWriteTag('interrupts');
  case Kind of
    RemappingIntel:
      begin
        DebugWrite('interrupt remapping on (VT-d, ');
        DebugWriteDecimal(IntelRemappingUnitCount);
        DebugWrite(' units');
      end;
    RemappingAmd:
      begin
        DebugWrite('interrupt remapping on (AMD-Vi, ');
        DebugWriteDecimal(AmdRemappingUnitCount);
        DebugWrite(' IOMMUs');
      end;
  else
    DebugWrite('interrupt remapping wanted, but no IOMMU can do it (');
  end;
  if ExtendedIds then
    DebugWriteLine(', 32-bit destinations)')
  else
    DebugWriteLine(', 8-bit destinations)');
  DebugEndMessage;
end;

end.
