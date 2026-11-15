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
  Display modes: the list of sizes a display can be set to.

  A list is gathered from what the display says it shows well (its
  EDID's timings), the sizes most displays take, and the mode it has
  now, each only if the adapter can make it (within its largest width
  and height, and its framebuffer memory at 4 bytes a pixel). It is kept
  without repeats, smallest first (by area, then width).
}
unit Drivers.DisplayModes;

{$mode objfpc}

interface

const
  MaximumDisplayModes = 48;
  { Below this a window system has no room; QEMU's EDID lists 640x480. }
  SmallestModeWidth = 640;
  SmallestModeHeight = 480;

type
  TDisplayMode = record
    Width: LongWord;
    Height: LongWord;
  end;

  { What an adapter can make: modes beyond these are left out. }
  TDisplayModeLimits = record
    MaximumWidth: LongWord;
    MaximumHeight: LongWord;
    FramebufferBytes: QWord;
  end;

  TDisplayModeList = record
    Count: LongInt;
    Modes: array[0..MaximumDisplayModes - 1] of TDisplayMode;
    Limits: TDisplayModeLimits;
  end;

procedure BeginModeList(out List: TDisplayModeList; const Limits: TDisplayModeLimits);
{ Adds Width x Height if the adapter can make it and it is not listed. }
procedure AddDisplayMode(var List: TDisplayModeList; Width, Height: LongWord);
{ Adds the mode the display has now, whatever the limits (it shows, so
  it can be made). }
procedure AddCurrentDisplayMode(var List: TDisplayModeList; Width, Height: LongWord);
{ Adds the common sizes (4:3, 16:10, 16:9 and 5:4 ones). }
procedure AddCommonDisplayModes(var List: TDisplayModeList);
procedure SortDisplayModes(var List: TDisplayModeList);
function DisplayModeIsListed(const List: TDisplayModeList; Width, Height: LongWord): Boolean;

implementation

const
  CommonModeCount = 14;
  CommonModes: array[0..CommonModeCount - 1] of TDisplayMode = (
    (Width: 640; Height: 480), (Width: 800; Height: 600), (Width: 1024; Height: 768),
    (Width: 1280; Height: 720), (Width: 1280; Height: 800), (Width: 1280; Height: 1024),
    (Width: 1366; Height: 768), (Width: 1440; Height: 900), (Width: 1600; Height: 900),
    (Width: 1600; Height: 1200), (Width: 1680; Height: 1050), (Width: 1920; Height: 1080),
    (Width: 1920; Height: 1200), (Width: 2560; Height: 1440));
  BytesPerPixel = 4;

procedure BeginModeList(out List: TDisplayModeList; const Limits: TDisplayModeLimits);
begin
  List.Count := 0;
  List.Limits := Limits;
end;

function DisplayModeIsListed(const List: TDisplayModeList; Width, Height: LongWord): Boolean;
var
  Index: LongInt;
begin
  for Index := 0 to List.Count - 1 do
    if (List.Modes[Index].Width = Width) and (List.Modes[Index].Height = Height) then
      Exit(True);
  Result := False;
end;

function AdapterCanMake(const Limits: TDisplayModeLimits; Width, Height: LongWord): Boolean;
begin
  Result := (Width >= SmallestModeWidth) and (Height >= SmallestModeHeight) and
    (Width <= Limits.MaximumWidth) and (Height <= Limits.MaximumHeight) and
    (QWord(Width) * Height * BytesPerPixel <= Limits.FramebufferBytes);
end;

procedure AddDisplayMode(var List: TDisplayModeList; Width, Height: LongWord);
begin
  if (List.Count = MaximumDisplayModes) or not AdapterCanMake(List.Limits, Width, Height) or
     DisplayModeIsListed(List, Width, Height) then
    Exit;
  List.Modes[List.Count].Width := Width;
  List.Modes[List.Count].Height := Height;
  Inc(List.Count);
end;

procedure AddCurrentDisplayMode(var List: TDisplayModeList; Width, Height: LongWord);
begin
  if (List.Count = MaximumDisplayModes) or DisplayModeIsListed(List, Width, Height) then
    Exit;
  List.Modes[List.Count].Width := Width;
  List.Modes[List.Count].Height := Height;
  Inc(List.Count);
end;

procedure AddCommonDisplayModes(var List: TDisplayModeList);
var
  Index: LongInt;
begin
  for Index := 0 to CommonModeCount - 1 do
    AddDisplayMode(List, CommonModes[Index].Width, CommonModes[Index].Height);
end;

function ComesBefore(const First, Second: TDisplayMode): Boolean;
var
  FirstArea: QWord;
  SecondArea: QWord;
begin
  FirstArea := QWord(First.Width) * First.Height;
  SecondArea := QWord(Second.Width) * Second.Height;
  if FirstArea <> SecondArea then
    Result := FirstArea < SecondArea
  else
    Result := First.Width < Second.Width;
end;

procedure SortDisplayModes(var List: TDisplayModeList);
var
  Index: LongInt;
  Place: LongInt;
  Mode: TDisplayMode;
begin
  { Insertion sort: the list is short. }
  for Index := 1 to List.Count - 1 do
  begin
    Mode := List.Modes[Index];
    Place := Index;
    while (Place > 0) and ComesBefore(Mode, List.Modes[Place - 1]) do
    begin
      List.Modes[Place] := List.Modes[Place - 1];
      Dec(Place);
    end;
    List.Modes[Place] := Mode;
  end;
end;

end.
