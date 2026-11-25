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
  The xHCI driver's bookkeeping of the transfer waited for, and which
  device context an endpoint takes, kept apart from the hardware so the
  host test (tools/UsbDescriptorTest) can check it.

  An endpoint address (its number, 80h set for IN) takes device context
  number * 2 + 1 for IN, number * 2 for OUT. Context 0 is the slot's
  and context 1 the default control endpoint's: an address that maps to
  either (endpoint 0, in or out) is refused, never used to index the
  device's rings.

  The transfer waited for is a list of its TRBs (bus addresses) and the
  bytes each moves. Its event names one of them and the bytes left over
  of it (the residue); the bytes moved are those of the TRBs before it
  and that one, less the residue. A residue larger than its TRB (a
  faulty controller) counts as nothing moved by that TRB, so the count
  can never wrap past the transfer's length.
}
unit Drivers.XhciTransfers;

{$mode objfpc}

interface

const
  { Device contexts: 0 the slot, 1 the default control endpoint, 2-31
    the other endpoints. }
  FirstEndpointContext = 2;
  LastEndpointContext = 31;
  MaximumPendingTrbs = 20;

type
  TPendingTransfer = record
    Trbs: array[0..MaximumPendingTrbs - 1] of QWord;
    Lengths: array[0..MaximumPendingTrbs - 1] of LongWord;
    Count: Integer;
  end;

{ The device context of endpoint Address; False for endpoint 0 or an
  address with reserved bits. }
function EndpointContextIndex(Address: Byte; out ContextIndex: LongWord): Boolean;

procedure ClearPendingTransfer(out Pending: TPendingTransfer);
{ Notes a TRB of Length bytes; False if the list is full. }
function NotePendingTrb(var Pending: TPendingTransfer; Trb: QWord; Length: LongWord): Boolean;
{ True if Trb is one of the transfer's. }
function IsPendingTrb(const Pending: TPendingTransfer; Trb: QWord): Boolean;
{ The bytes moved when the event named EventTrb with Residue bytes left
  over (at most the transfer's length; 0 if EventTrb is not one of
  its TRBs). }
function CompletedBytes(const Pending: TPendingTransfer; EventTrb: QWord; Residue: LongWord): LongWord;

implementation

function EndpointContextIndex(Address: Byte; out ContextIndex: LongWord): Boolean;
begin
  ContextIndex := LongWord(Address and $0F) * 2;
  if (Address and $80) <> 0 then
    Inc(ContextIndex);
  Result := ((Address and $70) = 0) and (ContextIndex >= FirstEndpointContext) and
    (ContextIndex <= LastEndpointContext);
  if not Result then
    ContextIndex := 0;
end;

procedure ClearPendingTransfer(out Pending: TPendingTransfer);
begin
  Pending.Count := 0;
end;

function NotePendingTrb(var Pending: TPendingTransfer; Trb: QWord; Length: LongWord): Boolean;
begin
  Result := Pending.Count < MaximumPendingTrbs;
  if not Result then
    Exit;
  Pending.Trbs[Pending.Count] := Trb;
  Pending.Lengths[Pending.Count] := Length;
  Inc(Pending.Count);
end;

function IsPendingTrb(const Pending: TPendingTransfer; Trb: QWord): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to Pending.Count - 1 do
    if Pending.Trbs[Index] = Trb then
      Exit(True);
  Result := False;
end;

function CompletedBytes(const Pending: TPendingTransfer; EventTrb: QWord; Residue: LongWord): LongWord;
var
  Index: Integer;
  Before: QWord;
begin
  Before := 0;
  for Index := 0 to Pending.Count - 1 do
  begin
    if Pending.Trbs[Index] = EventTrb then
    begin
      if Residue < Pending.Lengths[Index] then
        Before := Before + Pending.Lengths[Index] - Residue;
      Exit(LongWord(Before));
    end;
    Before := Before + Pending.Lengths[Index];
  end;
  Result := 0;
end;

end.
