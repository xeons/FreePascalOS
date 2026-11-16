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
  What the parts of ImageTest share: counting checks, reading files,
  and comparing decoded pixels with references.

  A reference (name.rgba, written by fixturecommon.py from Pillow's
  decoding) is the width and height as little-endian 32-bit numbers,
  then a pixel at a time red, green, blue, alpha, line after line from
  the top.
}
unit ImageTest.Checks;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Classes,
  Image.Model;

var
  PassedChecks: Integer = 0;
  FailedChecks: Integer = 0;
  FixtureDirectory: string = '';

procedure Check(Condition: Boolean; const Name: string);
procedure Note(const Text: string);
function FixturePath(const Name: string): string;
function ReadFileBytes(const FileName: string): TBytes;
function FixtureBytes(const Name: string): TBytes;

{ Compares Image with the reference file ReferenceName (in the fixture
  directory): the same size, and no channel of any pixel further than
  Tolerance from it; with MeanTolerance >= 0 the mean difference of all
  channels must also be at most that. Prints the largest difference. }
procedure CheckImageMatchesReference(const Name: string; Image: TImage; const ReferenceName: string;
  Tolerance: LongInt; MeanTolerance: Double = -1);
{ The largest difference of any channel between two images of a size;
  -1 if their sizes differ. }
function LargestPixelDifference(First, Second: TImage): LongInt;

{ Prints the totals; the exit code is 1 if anything failed. }
procedure FinishChecks(const Title: string);

implementation

procedure Check(Condition: Boolean; const Name: string);
begin
  if Condition then
  begin
    Inc(PassedChecks);
    WriteLn('ok   ', Name);
  end
  else
  begin
    Inc(FailedChecks);
    WriteLn('FAIL ', Name);
  end;
end;

procedure Note(const Text: string);
begin
  WriteLn('     ', Text);
end;

function FixturePath(const Name: string): string;
begin
  Result := IncludeTrailingPathDelimiter(FixtureDirectory) + Name;
end;

function ReadFileBytes(const FileName: string): TBytes;
var
  Stream: TFileStream;
begin
  Result := nil;
  Stream := TFileStream.Create(FileName, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Result, Stream.Size);
    if Length(Result) > 0 then
      Stream.ReadBuffer(Result[0], Length(Result));
  finally
    Stream.Free;
  end;
end;

function FixtureBytes(const Name: string): TBytes;
begin
  Result := ReadFileBytes(FixturePath(Name));
end;

function Difference(First, Second: LongInt): LongInt;
begin
  Result := Abs(First - Second);
end;

procedure CheckImageMatchesReference(const Name: string; Image: TImage; const ReferenceName: string;
  Tolerance: LongInt; MeanTolerance: Double);
var
  Reference: TBytes;
  ReferenceWidth: LongInt;
  ReferenceHeight: LongInt;
  X: LongInt;
  Y: LongInt;
  Offset: PtrInt;
  Pixel: LongWord;
  Largest: LongInt;
  Total: Double;
  WorstX: LongInt;
  WorstY: LongInt;
  Channel: LongInt;
  Channels: array[0..3] of LongInt;
  ChannelDifference: LongInt;
  Mean: Double;
  Matches: Boolean;
begin
  if Image = nil then
  begin
    Check(False, Name + ' (no image)');
    Exit;
  end;
  Reference := FixtureBytes(ReferenceName);
  if Length(Reference) < 8 then
  begin
    Check(False, Name + ' (reference too short)');
    Exit;
  end;
  ReferenceWidth := Reference[0] or (Reference[1] shl 8) or (Reference[2] shl 16) or (Reference[3] shl 24);
  ReferenceHeight := Reference[4] or (Reference[5] shl 8) or (Reference[6] shl 16) or (Reference[7] shl 24);
  if (ReferenceWidth <> Image.Width) or (ReferenceHeight <> Image.Height) or
    (Length(Reference) < 8 + Int64(ReferenceWidth) * ReferenceHeight * 4) then
  begin
    Check(False, Name + ' (size ' + IntToStr(Image.Width) + 'x' + IntToStr(Image.Height) + ', reference ' +
      IntToStr(ReferenceWidth) + 'x' + IntToStr(ReferenceHeight) + ')');
    Exit;
  end;
  Largest := 0;
  Total := 0;
  WorstX := 0;
  WorstY := 0;
  for Y := 0 to Image.Height - 1 do
    for X := 0 to Image.Width - 1 do
    begin
      Offset := 8 + (PtrInt(Y) * Image.Width + X) * 4;
      Pixel := Image.Line(Y)[X];
      Channels[0] := (Pixel shr 16) and $FF;
      Channels[1] := (Pixel shr 8) and $FF;
      Channels[2] := Pixel and $FF;
      Channels[3] := Pixel shr 24;
      for Channel := 0 to 3 do
      begin
        ChannelDifference := Difference(Channels[Channel], Reference[Offset + Channel]);
        Total := Total + ChannelDifference;
        if ChannelDifference > Largest then
        begin
          Largest := ChannelDifference;
          WorstX := X;
          WorstY := Y;
        end;
      end;
    end;
  Mean := Total / (4.0 * Image.Width * Image.Height);
  Matches := Largest <= Tolerance;
  if MeanTolerance >= 0 then
    Matches := Matches and (Mean <= MeanTolerance);
  Check(Matches, Name);
  if (Largest > 0) or not Matches then
    Note(Format('largest difference %d at (%d, %d), mean %.3f', [Largest, WorstX, WorstY, Mean]));
end;

function LargestPixelDifference(First, Second: TImage): LongInt;
var
  X: LongInt;
  Y: LongInt;
  A: LongWord;
  B: LongWord;
  Shift: LongInt;
  ChannelDifference: LongInt;
begin
  if (First.Width <> Second.Width) or (First.Height <> Second.Height) then
    Exit(-1);
  Result := 0;
  for Y := 0 to First.Height - 1 do
    for X := 0 to First.Width - 1 do
    begin
      A := First.Line(Y)[X];
      B := Second.Line(Y)[X];
      Shift := 0;
      while Shift < 32 do
      begin
        ChannelDifference := Difference((A shr Shift) and $FF, (B shr Shift) and $FF);
        if ChannelDifference > Result then
          Result := ChannelDifference;
        Inc(Shift, 8);
      end;
    end;
end;

procedure FinishChecks(const Title: string);
begin
  WriteLn(Title, ': ', PassedChecks, ' passed, ', FailedChecks, ' failed');
  if FailedChecks > 0 then
    Halt(1);
end;

end.
