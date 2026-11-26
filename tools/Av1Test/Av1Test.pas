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
  Conformance test of libav1 on the host.

      Av1Test FIXTURES [--threads N] [--only NAME]

  FIXTURES/manifest.txt lists streams (made at build time by
  make-fixtures.py with the host's AV1 encoders) and the raw frames the
  reference decoder (aomdec) gives for them: "name stream.ivf
  frames.yuv count". Every frame the decoder shows must equal the
  reference frame sample for sample (the planes one after another,
  bytes for 8-bit streams and little-endian words otherwise, luma only
  for monochrome streams); the first difference is reported with its
  frame, plane and position.
}
program Av1Test;

{$mode objfpc}
{$H+}

uses
  {$ifdef UNIX}cthreads,{$endif}
  Classes, SysUtils, DateUtils, Media.Frames, Av1.Common, Av1.Decoder, Av1.ToolStatistics, Av1Test.Ivf, Av1Test.Fuzzing;

var
  FixtureDirectory: string;
  ThreadCount: Integer = 0;
  OnlyName: string = '';
  FuzzRounds: Integer = 0;
  Passed: Integer = 0;
  Failed: Integer = 0;
  TotalFrames: Int64 = 0;

function LoadFile(const FileName: string): TBytes;
var
  Stream: TFileStream;
begin
  Result := nil;
  Stream := TFileStream.Create(FileName, fmOpenRead or fmShareDenyWrite);
  try
    SetLength(Result, Stream.Size);
    if Length(Result) > 0 then
      Stream.ReadBuffer(Result[0], Length(Result));
  finally
    Stream.Free;
  end;
end;

{ Compares Frame with the reference bytes at Offset; returns '' or the first difference. }
function CompareFrame(const Frame: TVideoFrame; const Reference: TBytes; var Offset: Integer; FrameNumber: Integer): string;
var
  Plane, PlaneCount, BytesPerSample, Y, X, RowBytes, Got, Expected: Integer;
  Row: PByte;
begin
  Result := '';
  if Frame.Layout = plMonochrome then
    PlaneCount := 1
  else
    PlaneCount := 3;
  if Frame.BitDepth = 8 then
    BytesPerSample := 1
  else
    BytesPerSample := 2;
  for Plane := 0 to PlaneCount - 1 do
  begin
    RowBytes := Frame.Planes[Plane].Width * BytesPerSample;
    for Y := 0 to Frame.Planes[Plane].Height - 1 do
    begin
      if Offset + RowBytes > Length(Reference) then
        Exit(Format('frame %d: the reference has no more frames', [FrameNumber]));
      Row := @Frame.Planes[Plane].Data[Y * Frame.Planes[Plane].Stride];
      if CompareByte(Row^, Reference[Offset], RowBytes) <> 0 then
      begin
        for X := 0 to Frame.Planes[Plane].Width - 1 do
        begin
          if BytesPerSample = 1 then
          begin
            Got := Row[X];
            Expected := Reference[Offset + X];
          end
          else
          begin
            Got := Row[2 * X] or (Row[2 * X + 1] shl 8);
            Expected := Reference[Offset + 2 * X] or (Reference[Offset + 2 * X + 1] shl 8);
          end;
          if Got <> Expected then
            Exit(Format('frame %d plane %d at (%d, %d): %d, expected %d', [FrameNumber, Plane, X, Y, Got, Expected]));
        end;
      end;
      Inc(Offset, RowBytes);
    end;
  end;
end;

procedure RunCase(const Name, StreamFile, ReferenceFile: string; ExpectedFrames: Integer);
var
  Frames: TIvfFrames;
  Reference: TBytes;
  Decoder: TAv1Decoder;
  Frame: TVideoFrame;
  Width, Height, Index, Shown, Offset: Integer;
  Difference: string;
  Started: TDateTime;
begin
  Difference := '';
  Shown := 0;
  Offset := 0;
  Started := Now;
  try
    Frames := ReadIvfFile(FixtureDirectory + '/' + StreamFile, Width, Height);
    Reference := LoadFile(FixtureDirectory + '/' + ReferenceFile);
    Decoder := TAv1Decoder.Create(ThreadCount);
    try
      for Index := 0 to High(Frames) do
      begin
        Decoder.DecodeBytes(Frames[Index].Data, Frames[Index].Timestamp);
        while (Difference = '') and Decoder.TakeFrame(Frame) do
        begin
          Difference := CompareFrame(Frame, Reference, Offset, Shown);
          Inc(Shown);
        end;
        if Difference <> '' then
          Break;
      end;
    finally
      Decoder.Free;
    end;
    if (Difference = '') and (Shown <> ExpectedFrames) then
      Difference := Format('%d frames shown, expected %d', [Shown, ExpectedFrames]);
    if (Difference = '') and (Offset <> Length(Reference)) then
      Difference := 'the reference has more data than the frames shown';
  except
    on Error: Exception do
    begin
      Difference := Format('frame %d: %s: %s', [Shown, Error.ClassName, Error.Message]);
      if GetEnvironmentVariable('AV1TEST_TRACE') <> '' then
        DumpExceptionBackTrace(Output);
    end;
  end;
  Inc(TotalFrames, Shown);
  if Difference = '' then
  begin
    Inc(Passed);
    WriteLn(Format('ok   %s (%d frames, %d ms)', [Name, Shown, MilliSecondsBetween(Now, Started)]));
  end
  else
  begin
    Inc(Failed);
    WriteLn(Format('FAIL %s: %s', [Name, Difference]));
  end;
end;

{ Damaged copies of a stream: decoded or refused, never anything worse. }
procedure RunFuzzCase(const Name, StreamFile: string);
var
  Failure: string;
  Seed: LongWord;
  Index: Integer;
begin
  Seed := 2166136261;
  for Index := 1 to Length(Name) do
    Seed := LongWord((QWord(Seed xor Ord(Name[Index])) * 16777619) and $FFFFFFFF);
  Failure := FuzzStream(FixtureDirectory + '/' + StreamFile, FuzzRounds, Seed);
  if Failure = '' then
  begin
    Inc(Passed);
    WriteLn(Format('ok   %s (%d damaged copies)', [Name, FuzzRounds]));
  end
  else
  begin
    Inc(Failed);
    WriteLn(Format('FAIL %s: %s', [Name, Failure]));
  end;
end;

procedure ParseArguments;
var
  Index: Integer;
begin
  if ParamCount < 1 then
  begin
    WriteLn('usage: Av1Test FIXTURES [--threads N] [--only NAME] [--fuzz ROUNDS]');
    Halt(2);
  end;
  FixtureDirectory := ParamStr(1);
  Index := 2;
  while Index <= ParamCount do
  begin
    if (ParamStr(Index) = '--threads') and (Index < ParamCount) then
    begin
      ThreadCount := StrToInt(ParamStr(Index + 1));
      Inc(Index);
    end
    else if (ParamStr(Index) = '--fuzz') and (Index < ParamCount) then
    begin
      FuzzRounds := StrToInt(ParamStr(Index + 1));
      Inc(Index);
    end
    else if (ParamStr(Index) = '--only') and (Index < ParamCount) then
    begin
      OnlyName := ParamStr(Index + 1);
      Inc(Index);
    end;
    Inc(Index);
  end;
end;

procedure RunManifest;
var
  Lines, Fields: TStringList;
  Index: Integer;
begin
  Lines := TStringList.Create;
  Fields := TStringList.Create;
  try
    Lines.LoadFromFile(FixtureDirectory + '/manifest.txt');
    Fields.Delimiter := ' ';
    Fields.StrictDelimiter := True;
    for Index := 0 to Lines.Count - 1 do
    begin
      if (Trim(Lines[Index]) = '') or (Lines[Index][1] = '#') then
        Continue;
      Fields.DelimitedText := Lines[Index];
      if Fields.Count < 4 then
        Continue;
      if (OnlyName <> '') and (Fields[0] <> OnlyName) then
        Continue;
      if FuzzRounds > 0 then
        RunFuzzCase(Fields[0], Fields[1])
      else
        RunCase(Fields[0], Fields[1], Fields[2], StrToInt(Fields[3]));
    end;
  finally
    Fields.Free;
    Lines.Free;
  end;
end;

{ What the streams exercised: every tool and how often it was met. }
procedure ReportCoverage;
var
  Tool: TAv1Tool;
  Missing: string;
begin
  Missing := '';
  for Tool := Low(TAv1Tool) to High(TAv1Tool) do
  begin
    WriteLn(Format('tool %-30s %d', [ToolNames[Tool], ToolCounts[Tool]]));
    if ToolCounts[Tool] = 0 then
      Missing := Missing + ' [' + ToolNames[Tool] + ']';
  end;
  if (OnlyName = '') and (Missing <> '') then
    WriteLn('tools no stream exercised:', Missing);
end;

begin
  ParseArguments;
  RunManifest;
  ReportCoverage;
  WriteLn(Format('%d streams passed, %d failed, %d frames', [Passed, Failed, TotalFrames]));
  if Failed > 0 then
    Halt(1);
end.
