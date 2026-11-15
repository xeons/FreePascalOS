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
  tone - play a sine tone, or write it to a WAV file

  tone [-o FILE] [-r RATE] [-f FORMAT] [-c CHANNELS] [-a AMPLITUDE] FREQUENCY SECONDS

  Plays FREQUENCY Hz for SECONDS seconds (a fraction is allowed) on the
  audio device, or with -o writes it as a WAV file. RATE is 8000 to
  192000 (default 48000), FORMAT u8, s16 (the default), s24, s32 or
  float, CHANNELS 1 to 8 (default 2, all get the tone); AMPLITUDE is in
  percent (default 50).
}
program tone;

{$mode objfpc}
{$pointermath on}

uses
  Runtime.Text,
  Abi.SystemCalls,
  Sys.Files,
  Sys.Format,
  Sys.Memory,
  Sys.Text,
  Util.Messages,
  Util.Options,
  Audio.Formats,
  Audio.Device,
  Audio.Wave,
  Audio.Synthesis;

const
  Usage: PChar = 'Usage: tone [-o FILE] [-r RATE] [-f FORMAT] [-c CHANNELS] [-a AMPLITUDE] FREQUENCY SECONDS'#10 +
    'Play a sine tone of FREQUENCY Hz for SECONDS seconds, or write it to FILE'#10 +
    'as a WAV file.'#10 +
    '  -o FILE       write a WAV file instead of playing'#10 +
    '  -r RATE       8000 to 192000 samples a second (default 48000)'#10 +
    '  -f FORMAT     u8, s16 (default), s24, s32 or float samples'#10 +
    '  -c CHANNELS   1 to 8 channels (default 2)'#10 +
    '  -a AMPLITUDE  loudness in percent of full scale (default 50)'#10;
  OptionOutput = 1;
  OptionRate = 2;
  OptionAmplitude = 3;
  OptionFormat = 4;
  OptionChannels = 5;
  ChunkFrames = 1024;

{ "1.5" into thousandths. }
function ParseThousandths(Text: PChar; out Value: QWord): Boolean;
var
  Position: Integer;
  Scale: QWord;
begin
  Value := 0;
  Position := 0;
  if not IsDigit(Text[0]) then
    Exit(False);
  while IsDigit(Text[Position]) do
  begin
    Value := Value * 10 + QWord(Ord(Text[Position]) - Ord('0'));
    Inc(Position);
  end;
  Value := Value * 1000;
  if Text[Position] = '.' then
  begin
    Inc(Position);
    Scale := 100;
    while IsDigit(Text[Position]) do
    begin
      Value := Value + QWord(Ord(Text[Position]) - Ord('0')) * Scale;
      Scale := Scale div 10;
      Inc(Position);
    end;
  end;
  Result := Text[Position] = #0;
end;

var
  Parser: TOptionParser;
  Code: Integer;
  OptionValue: PChar;
  OutputPath: PChar;
  Rate: QWord;
  Amplitude: QWord;
  Frequency: QWord;
  Thousandths: QWord;
  FramesLeft: QWord;
  Frames: QWord;
  Generator: TToneGenerator;
  Samples: PByte;
  Kind: LongWord;
  Channels: QWord;
  SampleBytes: LongWord;
  Frame: QWord;
  Channel: QWord;
  Value: Single;
  Handle: Int64;
  Format: TAudioFormat;
  Header: array[0..WaveHeaderSize - 1] of Byte;
  Error: LongInt;
begin
  OutputPath := nil;
  Rate := 48000;
  Amplitude := 50;
  Kind := SampleSigned16;
  Channels := 2;
  BeginOptions(Parser, [OptionDefinition('o', 'output', True, OptionOutput),
    OptionDefinition('r', 'rate', True, OptionRate),
    OptionDefinition('f', 'format', True, OptionFormat),
    OptionDefinition('c', 'channels', True, OptionChannels),
    OptionDefinition('a', 'amplitude', True, OptionAmplitude)], Usage);
  while NextOption(Parser, Code, OptionValue) do
    case Code of
      OptionOutput: OutputPath := OptionValue;
      OptionRate:
        if not ParseUnsigned(OptionValue, Rate) or (Rate < 8000) or (Rate > 192000) then
          FailWithUsageHint('the rate must be 8000 to 192000', []);
      OptionFormat:
        begin
          Kind := SampleKindOfName(OptionValue);
          if Kind = 0 then
            FailWithUsageHint('unknown sample format ''%s''', [ArgumentText(OptionValue)]);
        end;
      OptionChannels:
        if not ParseUnsigned(OptionValue, Channels) or (Channels < 1) or (Channels > 8) then
          FailWithUsageHint('there can be 1 to 8 channels', []);
      OptionAmplitude:
        if not ParseUnsigned(OptionValue, Amplitude) or (Amplitude > 100) then
          FailWithUsageHint('the amplitude must be 0 to 100', []);
    end;
  if Parser.OperandCount <> 2 then
    FailWithUsageHint('a frequency and a length are needed', []);
  if not ParseUnsigned(Parser.Operands[0], Frequency) or (Frequency = 0) or (Frequency >= Rate div 2) then
    FailWithUsageHint('invalid frequency ''%s''', [ArgumentText(Parser.Operands[0])]);
  if not ParseThousandths(Parser.Operands[1], Thousandths) then
    FailWithUsageHint('invalid length ''%s''', [ArgumentText(Parser.Operands[1])]);

  FramesLeft := Rate * Thousandths div 1000;
  StartTone(Generator, LongWord(Frequency), LongWord(Rate), LongInt(Amplitude * 32767 div 100));
  SampleBytes := BytesPerSample(Kind);
  Samples := PByte(AllocateMemory(ChunkFrames * Channels * SampleBytes));

  if OutputPath <> nil then
  begin
    Handle := OpenFile(OutputPath, OpenWrite or OpenCreate or OpenTruncate);
    if Handle < 0 then
      FailWithError(1, LongInt(-Handle), '%s', [ArgumentText(OutputPath)]);
    MakeWaveHeader(@Header[0], LongWord(Rate), LongWord(Channels), Kind,
      LongWord(FramesLeft * Channels * SampleBytes));
    WriteAll(Handle, @Header[0], WaveHeaderSize);
  end
  else
  begin
    Handle := OpenAudioOutput(nil);
    if Handle < 0 then
      FailWithError(1, LongInt(-Handle), '%s', [ArgumentText(DefaultAudioDevice)]);
    Format.Rate := LongWord(Rate);
    Format.Channels := LongWord(Channels);
    Format.Kind := Kind;
    Error := SetAudioFormat(Handle, Format);
    if Error <> 0 then
      FailWithError(1, Error, 'setting the format', []);
  end;

  while FramesLeft > 0 do
  begin
    Frames := FramesLeft;
    if Frames > ChunkFrames then
      Frames := ChunkFrames;
    for Frame := 0 to Frames - 1 do
    begin
      Value := NextToneSample(Generator);
      for Channel := 0 to Channels - 1 do
        EncodeSample(Value, Kind, Samples + (Frame * Channels + Channel) * SampleBytes);
    end;
    Error := WriteAll(Handle, Samples, Frames * Channels * SampleBytes);
    if Error <> 0 then
      FailWithError(1, Error, 'writing', []);
    FramesLeft := FramesLeft - Frames;
  end;
  if OutputPath = nil then
    DrainAudio(Handle);
  CloseFile(Handle);
end.
