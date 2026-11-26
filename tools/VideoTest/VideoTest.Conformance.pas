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
  Conformance: every stream of a manifest ('stream md5file' lines)
  decoded on one thread and on several must give, picture by picture,
  the reference decoder's MD5s.
}
unit VideoTest.Conformance;

{$mode objfpc}
{$H+}

interface

{ Checks the streams of Directory/manifest.txt. }
procedure CheckManifest(const Directory: string);

implementation

uses
  SysUtils, Classes, TestChecks, VideoTest.Streams;

procedure CheckStream(const Directory, StreamName, Md5Name: string; ThreadCount: LongInt);
var
  Expected, Actual: TStringArray;
  Index, Bad, FirstBad: LongInt;
  Name: string;
begin
  Name := Format('%s (%d thread(s))', [StreamName, ThreadCount]);
  Expected := ReadExpected(IncludeTrailingPathDelimiter(Directory) + Md5Name);
  try
    Actual := DecodeStream(LoadFile(IncludeTrailingPathDelimiter(Directory) + StreamName), ThreadCount);
  except
    on E: Exception do
    begin
      Check(False, Name + ': ' + E.ClassName + ': ' + E.Message);
      Exit;
    end;
  end;
  Bad := 0;
  FirstBad := -1;
  for Index := 0 to High(Actual) do
    if (Index > High(Expected)) or (Actual[Index] <> Expected[Index]) then
    begin
      if FirstBad < 0 then
        FirstBad := Index;
      Inc(Bad);
    end;
  Check((Bad = 0) and (Length(Actual) = Length(Expected)),
    Format('%s: %d pictures bit exact', [Name, Length(Expected)]));
  if (Bad > 0) or (Length(Actual) <> Length(Expected)) then
    WriteLn(Format('     %d pictures decoded, %d expected, %d differ, the first at %d',
      [Length(Actual), Length(Expected), Bad, FirstBad]));
end;

procedure CheckManifest(const Directory: string);
var
  Manifest: TStringList;
  Index, Separator: LongInt;
  Line: string;
begin
  Manifest := TStringList.Create;
  try
    Manifest.LoadFromFile(IncludeTrailingPathDelimiter(Directory) + 'manifest.txt');
    for Index := 0 to Manifest.Count - 1 do
    begin
      Line := Trim(Manifest[Index]);
      if Line = '' then
        Continue;
      Separator := Pos(' ', Line);
      CheckStream(Directory, Copy(Line, 1, Separator - 1), Trim(Copy(Line, Separator + 1, MaxInt)), 1);
      CheckStream(Directory, Copy(Line, 1, Separator - 1), Trim(Copy(Line, Separator + 1, MaxInt)), 3);
    end;
  finally
    Manifest.Free;
  end;
end;

end.
