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
  What every part of FontTest checks with: a check prints a line and
  counts; and reading files and fonts on the host.
}
unit FontTest.Checks;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Font.TrueType;

var
  Failures: Integer = 0;
  Checks: Integer = 0;

procedure Check(const Name: string; Passed: Boolean);
function ReadFileBytes(const Path: string; out Data: TBytes): Boolean;
{ The TrueType font in the file at Path; nil if it cannot be read or is
  refused. }
function LoadFontFile(const Path: string; FaceIndex: LongInt = 0): TTrueTypeFont;

implementation

uses
  Classes;

procedure Check(const Name: string; Passed: Boolean);
begin
  Inc(Checks);
  if Passed then
    WriteLn('[font] pass: ', Name)
  else
  begin
    WriteLn('[font] FAIL: ', Name);
    Inc(Failures);
  end;
end;

function ReadFileBytes(const Path: string; out Data: TBytes): Boolean;
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

function LoadFontFile(const Path: string; FaceIndex: LongInt): TTrueTypeFont;
var
  Data: TBytes;
begin
  Result := nil;
  if ReadFileBytes(Path, Data) then
    Result := LoadTrueTypeFont(Data, FaceIndex);
end;

end.
