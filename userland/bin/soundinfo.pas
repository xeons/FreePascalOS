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
  soundinfo - describe the sound in WAV files

  soundinfo FILE...

  For each file prints its rate, channels, sample format and length,
  the peak level of its first channel (percent of full scale) and the
  frequency of that channel (from its zero crossings, to the nearest
  10 Hz), or "silent":

    t.wav: 48000 Hz, 2 channels, s16, 0.50 s, peak 50%, 440 Hz
}
program soundinfo;

{$mode objfpc}
{$pointermath on}

uses
  Sys.Format,
  Sys.Memory,
  Sys.Streams,
  Util.Messages,
  Util.Options,
  Audio.Formats,
  Audio.Wave;

const
  Usage: PChar = 'Usage: soundinfo FILE...'#10 +
    'Describe the sound in WAV files: format, length, level and frequency.'#10;
  ChunkFrames = 4096;
  { Under this the first channel counts as silent (and crossings are not
    counted while it is this quiet). }
  SilenceLevel = 0.01;

type
  TMeasure = record
    Frames: QWord;
    Peak: Single;
    Crossings: QWord;
    FirstCrossing: QWord;
    LastCrossing: QWord;
    WasNegative: Boolean;
  end;

procedure MeasureSample(var Measure: TMeasure; Value: Single);
begin
  if Abs(Value) > Measure.Peak then
    Measure.Peak := Abs(Value);
  if Value <= -SilenceLevel then
    Measure.WasNegative := True
  else if (Value >= SilenceLevel) and Measure.WasNegative then
  begin
    { A rising crossing. }
    if Measure.Crossings = 0 then
      Measure.FirstCrossing := Measure.Frames;
    Measure.LastCrossing := Measure.Frames;
    Inc(Measure.Crossings);
    Measure.WasNegative := False;
  end;
  Inc(Measure.Frames);
end;

function Describe(Path: PChar): Boolean;
var
  Wave: TWaveFile;
  Status: TWaveStatus;
  Buffer: PByte;
  FrameBytes: LongWord;
  Got: QWord;
  Frame: QWord;
  Measure: TMeasure;
  Hertz: QWord;
  Hundredths: QWord;
  Plural: PChar;
begin
  Status := OpenWaveFile(Path, Wave);
  if Status <> WaveOk then
  begin
    Report('%s: %s', [ArgumentText(Path), ArgumentText(WaveStatusText(Status))]);
    Exit(False);
  end;
  FrameBytes := Wave.Channels * BytesPerSample(Wave.Kind);
  Buffer := PByte(AllocateMemory(ChunkFrames * FrameBytes));
  FillChar(Measure, SizeOf(Measure), 0);
  repeat
    Got := ReadWaveSamples(Wave, Buffer, ChunkFrames * FrameBytes) div FrameBytes;
    if Got > 0 then
      for Frame := 0 to Got - 1 do
        MeasureSample(Measure, DecodeSample(Wave.Kind, Buffer + Frame * FrameBytes));
  until Got = 0;
  CloseWaveFile(Wave);
  FreeMemory(Buffer);

  Hundredths := (Measure.Frames * 100 + Wave.Rate div 2) div Wave.Rate;
  Plural := 's';
  if Wave.Channels = 1 then
    Plural := '';
  WriteFormatted(StandardOutput, '%s: %u Hz, %u channel%s, %s, %u.%u%u s, peak %u%%, ',
    [ArgumentText(Path), ArgumentUnsigned(Wave.Rate), ArgumentUnsigned(Wave.Channels), ArgumentText(Plural),
    ArgumentText(SampleKindName(Wave.Kind)), ArgumentUnsigned(Hundredths div 100),
    ArgumentUnsigned((Hundredths div 10) mod 10), ArgumentUnsigned(Hundredths mod 10),
    ArgumentUnsigned(Round(Measure.Peak * 100))]);
  if (Measure.Peak < SilenceLevel) or (Measure.Crossings < 2) then
    WriteFormatted(StandardOutput, 'silent'#10, [])
  else
  begin
    Hertz := Round((Measure.Crossings - 1) * Wave.Rate / (Measure.LastCrossing - Measure.FirstCrossing) / 10) * 10;
    WriteFormatted(StandardOutput, '%u Hz'#10, [ArgumentUnsigned(Hertz)]);
  end;
  Result := True;
end;

var
  Parser: TOptionParser;
  Index: Integer;
  Status: Integer;
begin
  ParseOperandsOnly(Parser, Usage);
  if Parser.OperandCount = 0 then
    FailWithUsageHint('no files given', []);
  Status := 0;
  for Index := 0 to Parser.OperandCount - 1 do
    if not Describe(Parser.Operands[Index]) then
      Status := 1;
  Halt(Status);
end.
