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
  What every part of DrawingTest checks with: a check prints a line and
  counts, and a few helpers for surfaces and files.
}
unit DrawingTest.Checks;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Drawing.Colors,
  Drawing.Surfaces;

var
  Failures: Integer = 0;
  Checks: Integer = 0;

procedure Check(Name: string; Passed: Boolean);
function ColorText(Color: TColor): string;
procedure CheckColor(Name: string; Got, Expected: TColor);
{ Pixels of Surface equal to Color. }
function CountPixels(const Surface: TSurface; Color: TColor): Integer;
function NewSurface(Width, Height: Integer; Fill: TColor): TSurface;
function ReadFileBytes(Path: string; out Data: TBytes): Boolean;

implementation

uses
  Classes;

procedure Check(Name: string; Passed: Boolean);
begin
  Inc(Checks);
  if Passed then
    WriteLn('[drawing] pass: ', Name)
  else
  begin
    WriteLn('[drawing] FAIL: ', Name);
    Inc(Failures);
  end;
end;

function ColorText(Color: TColor): string;
begin
  Result := '$' + IntToHex(Color, 8);
end;

procedure CheckColor(Name: string; Got, Expected: TColor);
begin
  if Got <> Expected then
    Name := Name + ' (got ' + ColorText(Got) + ', expected ' + ColorText(Expected) + ')';
  Check(Name, Got = Expected);
end;

function CountPixels(const Surface: TSurface; Color: TColor): Integer;
var
  X: Integer;
  Y: Integer;
begin
  Result := 0;
  for Y := 0 to Surface.Height - 1 do
    for X := 0 to Surface.Width - 1 do
      if GetSurfacePixel(Surface, X, Y) = Color then
        Inc(Result);
end;

function NewSurface(Width, Height: Integer; Fill: TColor): TSurface;
begin
  if not CreateSurface(Result, Width, Height, Fill) then
    raise Exception.Create('out of memory');
end;

function ReadFileBytes(Path: string; out Data: TBytes): Boolean;
var
  Stream: TFileStream;
begin
  Result := False;
  Data := nil;
  if not FileExists(Path) then
    Exit;
  Stream := TFileStream.Create(Path, fmOpenRead);
  try
    SetLength(Data, Stream.Size);
    if Stream.Size > 0 then
      Stream.ReadBuffer(Data[0], Stream.Size);
    Result := True;
  finally
    Stream.Free;
  end;
end;

end.
