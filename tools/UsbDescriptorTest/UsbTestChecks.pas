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
  What every part of the USB host test shares: checks (a failed one is
  printed and counted), and guarded buffers: bytes placed right before
  a page the process may not touch, so reading one byte past them
  crashes the test instead of going unnoticed.
}
unit UsbTestChecks;

{$mode objfpc}
{$pointermath on}

interface

var
  Failures: Integer = 0;

procedure Check(Condition: Boolean; const What: string);
procedure CheckNumber(Actual, Expected: Int64; const What: string);

{ Length bytes copied from Source (nil: zeros) to the end of a page
  followed by an inaccessible one; the result stays valid until the
  next call. Length is at most 4096. }
function GuardedCopy(Source: Pointer; Length: LongWord): PByte;

implementation

uses
  SysUtils,
  BaseUnix;

const
  GuardPageSize = 4096;

var
  GuardArea: PByte = nil;

procedure Check(Condition: Boolean; const What: string);
begin
  if not Condition then
  begin
    WriteLn('USB DESCRIPTOR TEST: failed: ', What);
    Inc(Failures);
  end;
end;

procedure CheckNumber(Actual, Expected: Int64; const What: string);
begin
  Check(Actual = Expected, What + ' is ' + IntToStr(Actual) + ', expected ' + IntToStr(Expected));
end;

procedure MapGuardArea;
begin
  GuardArea := PByte(Fpmmap(nil, 2 * GuardPageSize, PROT_READ or PROT_WRITE, MAP_PRIVATE or MAP_ANONYMOUS, -1, 0));
  if (GuardArea = nil) or (GuardArea = PByte(MAP_FAILED)) then
  begin
    WriteLn('USB DESCRIPTOR TEST: no guard pages');
    Halt(1);
  end;
  if Fpmprotect(GuardArea + GuardPageSize, GuardPageSize, PROT_NONE) <> 0 then
  begin
    WriteLn('USB DESCRIPTOR TEST: the guard page could not be protected');
    Halt(1);
  end;
end;

function GuardedCopy(Source: Pointer; Length: LongWord): PByte;
begin
  if GuardArea = nil then
    MapGuardArea;
  if Length > GuardPageSize then
    Length := GuardPageSize;
  Result := GuardArea + GuardPageSize - Length;
  if Length = 0 then
    Exit;
  if Source <> nil then
    Move(Source^, Result^, Length)
  else
    FillChar(Result^, Length, 0);
end;

end.
