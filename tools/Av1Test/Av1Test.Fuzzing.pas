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
  Damaged streams: each test stream with a few bytes changed (in the
  headers and in the tile data), cut short, or with temporal units
  dropped. The decoder may decode them or refuse them with EAv1Error,
  but nothing else: with range checks on, an ERangeError or an access
  violation is an index the stream controls that the decoder did not
  check, which without range checks would read or write the wrong
  memory.
}
unit Av1Test.Fuzzing;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils, Media.Frames, Av1.Common, Av1.Decoder, Av1Test.Ivf;

{ Decodes Rounds damaged copies of the stream; returns '' or what went wrong. }
function FuzzStream(const FileName: string; Rounds: Integer; Seed: LongWord): string;

implementation

var
  RandomState: LongWord;

function NextRandom(Limit: LongWord): LongWord;
begin
  RandomState := LongWord((QWord(RandomState) * 1103515245 + 12345) and $FFFFFFFF);
  Result := (RandomState shr 8) mod Limit;
end;

function CopyFrames(const Frames: TIvfFrames): TIvfFrames;
var
  Index: Integer;
begin
  Result := nil;
  SetLength(Result, Length(Frames));
  for Index := 0 to High(Frames) do
  begin
    Result[Index].Timestamp := Frames[Index].Timestamp;
    Result[Index].Data := Copy(Frames[Index].Data);
  end;
end;

procedure Damage(var Frames: TIvfFrames);
var
  Kind, Changes, Index, FrameIndex, Position: Integer;
begin
  Kind := NextRandom(4);
  case Kind of
    0, 1:
      begin
        { Change bytes; kind 0 near the start of a temporal unit (the headers). }
        Changes := 1 + NextRandom(4);
        for Index := 1 to Changes do
        begin
          FrameIndex := NextRandom(Length(Frames));
          if Length(Frames[FrameIndex].Data) = 0 then
            Continue;
          if Kind = 0 then
            Position := NextRandom(Min(48, Length(Frames[FrameIndex].Data)))
          else
            Position := NextRandom(Length(Frames[FrameIndex].Data));
          Frames[FrameIndex].Data[Position] := Frames[FrameIndex].Data[Position] xor (1 + NextRandom(255));
        end;
      end;
    2:
      begin
        { Cut a temporal unit short. }
        FrameIndex := NextRandom(Length(Frames));
        SetLength(Frames[FrameIndex].Data, NextRandom(Length(Frames[FrameIndex].Data) + 1));
      end;
  else
    { Drop a temporal unit (its references go missing). }
    FrameIndex := NextRandom(Length(Frames));
    Frames[FrameIndex].Data := nil;
  end;
end;

function FuzzStream(const FileName: string; Rounds: Integer; Seed: LongWord): string;
var
  Original, Damaged: TIvfFrames;
  Width, Height, Round, Index: Integer;
  Decoder: TAv1Decoder;
  Frame: TVideoFrame;
begin
  Result := '';
  RandomState := Seed;
  Original := ReadIvfFile(FileName, Width, Height);
  for Round := 1 to Rounds do
  begin
    Damaged := CopyFrames(Original);
    Damage(Damaged);
    if NextRandom(2) = 0 then
      Damage(Damaged);
    Decoder := TAv1Decoder.Create(1);
    try
      for Index := 0 to High(Damaged) do
      begin
        try
          Decoder.DecodeBytes(Damaged[Index].Data, Index);
        except
          on EAv1Error do
            ;    { refused: fine }
          on Error: Exception do
          begin
            if GetEnvironmentVariable('AV1TEST_TRACE') <> '' then
              DumpExceptionBackTrace(Output);
            Exit(Format('round %d, temporal unit %d: %s: %s', [Round, Index, Error.ClassName, Error.Message]));
          end;
        end;
        while Decoder.TakeFrame(Frame) do
          ;
      end;
    finally
      Decoder.Free;
    end;
  end;
end;

end.
