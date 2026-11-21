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
  Where a command bar's buttons go (Controls.CommandBar), as plain
  arithmetic in pixels.

  The commands stand left to right from 0, each Gap apart; the overflow
  button follows the last one shown; right-aligned commands stand at
  the far end, in their order. When they do not all fit, commands leave
  from the end of the left group first (a separator left at its end
  goes too), then the right-aligned ones from the first of them; what
  left goes into the overflow button's menu.

  Plain logic, no system calls: it builds for the host too and is
  checked there (tools/NavigationControlsTest).
}
unit Controls.CommandLayout;

{$mode objfpc}
{$H+}

interface

type
  TCommandSlot = record
    Width: LongInt;
    AlignRight: Boolean;
    IsSeparator: Boolean;
  end;

  TCommandPlacement = record
    Shown: Boolean;
    Left: LongInt;
  end;

  TCommandSlots = array of TCommandSlot;
  TCommandPlacements = array of TCommandPlacement;

{ Places Slots (in their order) and the overflow button (OverflowWidth
  wide, always shown) in Available pixels. }
procedure ArrangeCommands(const Slots: TCommandSlots; Available, OverflowWidth, Gap: LongInt;
  out Placements: TCommandPlacements; out OverflowLeft: LongInt);

implementation

{ The pixels Slots take when those Shown stand in a row, Gap apart. }
function ShownWidth(const Slots: TCommandSlots; const Shown: array of Boolean; RightGroup: Boolean;
  Gap: LongInt): LongInt;
var
  Index: LongInt;
begin
  Result := 0;
  for Index := 0 to High(Slots) do
    if Shown[Index] and (Slots[Index].AlignRight = RightGroup) then
      Result := Result + Slots[Index].Width + Gap;
end;

{ The last shown slot of a group (-1: none). }
function LastShown(const Slots: TCommandSlots; const Shown: array of Boolean; RightGroup: Boolean): LongInt;
var
  Index: LongInt;
begin
  Result := -1;
  for Index := 0 to High(Slots) do
    if Shown[Index] and (Slots[Index].AlignRight = RightGroup) then
      Result := Index;
end;

function FirstShown(const Slots: TCommandSlots; const Shown: array of Boolean; RightGroup: Boolean): LongInt;
var
  Index: LongInt;
begin
  for Index := 0 to High(Slots) do
    if Shown[Index] and (Slots[Index].AlignRight = RightGroup) then
      Exit(Index);
  Result := -1;
end;

{ A separator left at the end of the left group goes. }
procedure DropTrailingSeparators(const Slots: TCommandSlots; var Shown: array of Boolean);
var
  Last: LongInt;
begin
  Last := LastShown(Slots, Shown, False);
  while (Last >= 0) and Slots[Last].IsSeparator do
  begin
    Shown[Last] := False;
    Last := LastShown(Slots, Shown, False);
  end;
end;

procedure ArrangeCommands(const Slots: TCommandSlots; Available, OverflowWidth, Gap: LongInt;
  out Placements: TCommandPlacements; out OverflowLeft: LongInt);
var
  Shown: array of Boolean;
  Index: LongInt;
  Victim: LongInt;
  Left: LongInt;
  Right: LongInt;
begin
  Placements := nil;
  SetLength(Placements, Length(Slots));
  Shown := nil;
  SetLength(Shown, Length(Slots));
  for Index := 0 to High(Slots) do
    Shown[Index] := True;
  while ShownWidth(Slots, Shown, False, Gap) + OverflowWidth + ShownWidth(Slots, Shown, True, Gap) > Available do
  begin
    Victim := LastShown(Slots, Shown, False);
    if Victim < 0 then
      Victim := FirstShown(Slots, Shown, True);
    if Victim < 0 then
      Break;
    Shown[Victim] := False;
    DropTrailingSeparators(Slots, Shown);
  end;
  DropTrailingSeparators(Slots, Shown);
  Left := 0;
  for Index := 0 to High(Slots) do
    if Shown[Index] and not Slots[Index].AlignRight then
    begin
      Placements[Index].Shown := True;
      Placements[Index].Left := Left;
      Left := Left + Slots[Index].Width + Gap;
    end;
  OverflowLeft := Left;
  { The right group ends at the far edge. }
  Right := Available;
  for Index := High(Slots) downto 0 do
    if Shown[Index] and Slots[Index].AlignRight then
    begin
      Right := Right - Slots[Index].Width;
      Placements[Index].Shown := True;
      Placements[Index].Left := Right;
      Right := Right - Gap;
    end;
end;

end.
