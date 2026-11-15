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
  record - record sound into a WAV file

  record [-d DEVICE] [-r RATE] [-f FORMAT] [-c CHANNELS] FILE SECONDS

  Records SECONDS seconds (a fraction is allowed) from the audio input
  DEVICE (by default /dev/audioin; /dev/audiomonitor records what
  /dev/audio plays) into FILE as a WAV file. RATE is 8000 to 192000
  (default 48000), FORMAT u8, s16 (the default), s24, s32 or float,
  CHANNELS 1 to 8 (default 2). If the input had to drop frames because
  they were not read in time, says so.
}
{ "record" is a reserved word: the program is named for what it does. }
program RecordSound;

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
  Audio.Wave;

const
  Usage: PChar = 'Usage: record [-d DEVICE] [-r RATE] [-f FORMAT] [-c CHANNELS] FILE SECONDS'#10 +
    'Record SECONDS seconds of sound from the audio input into FILE (WAV).'#10 +
    '  -d DEVICE     the input (default /dev/audioin)'#10 +
    '  -r RATE       8000 to 192000 samples a second (default 48000)'#10 +
    '  -f FORMAT     u8, s16 (default), s24, s32 or float samples'#10 +
    '  -c CHANNELS   1 to 8 channels (default 2)'#10;
  OptionDevice = 1;
  OptionRate = 2;
  OptionFormat = 3;
  OptionChannels = 4;
  ChunkBytes = 16384;

var
  Parser: TOptionParser;
  Code: Integer;
  OptionValue: PChar;
  DevicePath: PChar;
  OutputPath: PChar;
  Rate: QWord;
  Channels: QWord;
  Kind: LongWord;
  Thousandths: QWord;
  BytesLeft: QWord;
  Wanted: QWord;
  Got: Int64;
  Buffer: PByte;
  Input: Int64;
  Output: Int64;
  Format: TAudioFormat;
  Header: array[0..WaveHeaderSize - 1] of Byte;
  Error: LongInt;
  Dropped: Int64;
begin
  DevicePath := DefaultAudioInput;
  Rate := 48000;
  Channels := 2;
  Kind := SampleSigned16;
  BeginOptions(Parser, [OptionDefinition('d', 'device', True, OptionDevice),
    OptionDefinition('r', 'rate', True, OptionRate),
    OptionDefinition('f', 'format', True, OptionFormat),
    OptionDefinition('c', 'channels', True, OptionChannels)], Usage);
  while NextOption(Parser, Code, OptionValue) do
    case Code of
      OptionDevice: DevicePath := OptionValue;
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
    end;
  if Parser.OperandCount <> 2 then
    FailWithUsageHint('a file and a length are needed', []);
  OutputPath := Parser.Operands[0];
  if not ParseThousandths(Parser.Operands[1], Thousandths) then
    FailWithUsageHint('invalid length ''%s''', [ArgumentText(Parser.Operands[1])]);

  Input := OpenAudioInput(DevicePath);
  if Input < 0 then
    FailWithError(1, LongInt(-Input), '%s', [ArgumentText(DevicePath)]);
  Format.Rate := LongWord(Rate);
  Format.Channels := LongWord(Channels);
  Format.Kind := Kind;
  Error := SetAudioFormat(Input, Format);
  if Error <> 0 then
    FailWithError(1, Error, 'setting the format', []);
  BytesLeft := (Rate * Thousandths div 1000) * Channels * BytesPerSample(Kind);

  Output := OpenFile(OutputPath, OpenWrite or OpenCreate or OpenTruncate);
  if Output < 0 then
    FailWithError(1, LongInt(-Output), '%s', [ArgumentText(OutputPath)]);
  MakeWaveHeader(@Header[0], LongWord(Rate), LongWord(Channels), Kind, LongWord(BytesLeft));
  WriteAll(Output, @Header[0], WaveHeaderSize);

  Buffer := PByte(AllocateMemory(ChunkBytes));
  while BytesLeft > 0 do
  begin
    Wanted := BytesLeft;
    if Wanted > ChunkBytes then
      Wanted := ChunkBytes;
    Got := ReadAudio(Input, Buffer, Wanted);
    if Got <= 0 then
      FailWithError(1, LongInt(-Got), 'reading %s', [ArgumentText(DevicePath)]);
    Error := WriteAll(Output, Buffer, QWord(Got));
    if Error <> 0 then
      FailWithError(1, Error, '%s', [ArgumentText(OutputPath)]);
    BytesLeft := BytesLeft - QWord(Got);
  end;
  Dropped := DroppedAudioFrames(Input);
  if Dropped > 0 then
    Report('%d frames were dropped (not read in time)', [ArgumentNumber(Dropped)]);
  CloseAudioOutput(Input);
  CloseFile(Output);
end.
