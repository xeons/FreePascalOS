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
  FileSystemImageTest: the kernel's file system drivers against damaged
  disks, on the host.

  A USB stick is mounted as soon as it is plugged in, so whatever is on
  it reaches the drivers. Whatever that is, a driver may refuse to mount,
  mount read-only or report StatusCorrupted - and nothing else: no write
  outside its buffers, no endless loop, no crash, no leaked memory.

    FileSystemImageTest MANIFEST
      Each line of MANIFEST is "IMAGE EXPECTATION DESCRIPTION": the image
      (made by make-images.py, relative to the manifest), then one of
        clean      mounts writable; walking and writing find no error
        readonly   mounts, read-only
        refuse     no driver mounts it
        corrupted  StatusCorrupted, at the mount or while walking
        survives   anything but a fault
    FileSystemImageTest --fuzz IMAGE ITERATIONS SEED
      Damages copies of IMAGE at random (bytes, words set to extremes,
      runs of zeros) and runs each; any fault fails.

  Prints FAIL lines and a summary; exit status 1 on any failure.
}
program FileSystemImageTest;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  Classes,
  FileSystem.Types,
  ImageHarness,
  ImageMutations;

var
  Failures: Integer = 0;
  Checks: Integer = 0;

procedure Fail(const Text: string);
begin
  WriteLn('FAIL ', Text);
  Inc(Failures);
end;

function LoadImage(const Path: string): TBytes;
var
  Stream: TFileStream;
begin
  Result := nil;
  Stream := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Result, Stream.Size);
    if Stream.Size > 0 then
      Stream.ReadBuffer(Result[0], Stream.Size);
  finally
    Stream.Free;
  end;
end;

function DescribeOutcome(const Outcome: TImageOutcome): string;
begin
  if not Outcome.Mounted then
    Result := Format('not mounted (%s: %s)', [Outcome.DriverName, FileSystemStatusText(Outcome.MountStatus)])
  else
    Result := Format('mounted by %s%s, %d nodes, first error: %s',
      [Outcome.DriverName, BoolToStr(Outcome.IsReadOnly, ' read-only', ''), Outcome.NodesVisited,
       FileSystemStatusText(Outcome.FirstError)]);
end;

function OutcomeMeets(const Outcome: TImageOutcome; const Expectation: string): Boolean;
begin
  if Expectation = 'clean' then
    Result := Outcome.Mounted and not Outcome.IsReadOnly and (Outcome.FirstError = StatusSuccess)
  else if Expectation = 'readonly' then
    Result := Outcome.Mounted and Outcome.IsReadOnly
  else if Expectation = 'refuse' then
    Result := not Outcome.Mounted
  else if Expectation = 'corrupted' then
    Result := (not Outcome.Mounted and (Outcome.MountStatus = StatusCorrupted)) or Outcome.SawCorrupted
  else if Expectation = 'survives' then
    Result := True
  else
    raise Exception.Create('unknown expectation ' + Expectation);
end;

procedure RunManifest(const ManifestPath: string);
var
  Lines: TStringList;
  Fields: TStringList;
  Index: Integer;
  Outcome: TImageOutcome;
  ImagePath: string;
  Expectation: string;
  Description: string;
begin
  Lines := TStringList.Create;
  Fields := TStringList.Create;
  try
    Lines.LoadFromFile(ManifestPath);
    for Index := 0 to Lines.Count - 1 do
    begin
      if (Trim(Lines[Index]) = '') or (Lines[Index][1] = '#') then
        Continue;
      Fields.Clear;
      ExtractStrings([' '], [], PChar(Lines[Index]), Fields);
      if Fields.Count < 2 then
        Continue;
      ImagePath := ExtractFilePath(ManifestPath) + Fields[0];
      Expectation := Fields[1];
      Description := Copy(Lines[Index], Length(Fields[0]) + Length(Fields[1]) + 3, MaxInt);
      Inc(Checks);
      if not RunImage(LoadImage(ImagePath), True, Outcome) then
        Fail(Format('%s (%s): %s', [Fields[0], Description, Outcome.Fault]))
      else if not OutcomeMeets(Outcome, Expectation) then
        Fail(Format('%s (%s): expected %s, got %s', [Fields[0], Description, Expectation,
          DescribeOutcome(Outcome)]));
    end;
  finally
    Fields.Free;
    Lines.Free;
  end;
end;

procedure RunFuzz(const ImagePath: string; Iterations: Integer; Seed: LongWord);
var
  Original: TBytes;
  Damaged: TBytes;
  Iteration: Integer;
  Outcome: TImageOutcome;
  Generator: TMutationGenerator;
  Mounted: Integer;
begin
  Original := LoadImage(ImagePath);
  if not RunImage(Original, True, Outcome) or not Outcome.Mounted then
  begin
    Fail(Format('%s: the undamaged image does not mount cleanly: %s %s',
      [ImagePath, Outcome.Fault, DescribeOutcome(Outcome)]));
    Exit;
  end;
  Mounted := 0;
  Generator := Default(TMutationGenerator);
  ChooseTargets(Generator, Original);
  for Iteration := 1 to Iterations do
  begin
    StartMutations(Generator, Seed, Iteration);
    Damaged := Copy(Original);
    DamageImage(Generator, Damaged);
    Inc(Checks);
    if not RunImage(Damaged, True, Outcome) then
      Fail(Format('%s, seed %d, iteration %d: %s', [ExtractFileName(ImagePath), Seed, Iteration, Outcome.Fault]));
    if Outcome.Mounted then
      Inc(Mounted);
  end;
  WriteLn(Format('%s: %d damaged copies, %d of them mounted', [ExtractFileName(ImagePath), Iterations, Mounted]));
end;

begin
  if (ParamCount = 4) and (ParamStr(1) = '--fuzz') then
    RunFuzz(ParamStr(2), StrToInt(ParamStr(3)), LongWord(StrToInt64(ParamStr(4))))
  else if ParamCount = 1 then
    RunManifest(ParamStr(1))
  else
  begin
    WriteLn('usage: FileSystemImageTest MANIFEST | --fuzz IMAGE ITERATIONS SEED');
    Halt(2);
  end;
  if Failures > 0 then
  begin
    WriteLn(Format('FILE SYSTEM IMAGE TEST FAILED: %d of %d', [Failures, Checks]));
    Halt(1);
  end;
  WriteLn(Format('FILE SYSTEM IMAGE TEST PASSED: %d', [Checks]));
end.
