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

  A recording of up to 64 MiB is kept in memory and written when it is
  complete: the input is read all the time, so writing the file (whose
  disk may make a write wait for its journal) never holds up the reading
  long enough for the input to drop samples. Longer ones are written as
  they come.
}
{ "record" is a reserved word: the program is named for what it does. }
program RecordSound;

{$mode objfpc}
{$H+}

uses
  Abi.SystemCalls,
  SysUtils,
  Sys.Files,
  Util.CommandLine,
  Util.Messages,
  Util.Numbers,
  Audio.Formats,
  Audio.Device,
  Audio.Wave;

const
  Usage = 'Usage: record [-d DEVICE] [-r RATE] [-f FORMAT] [-c CHANNELS] FILE SECONDS'#10 +
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
  MaximumBytesInMemory = 64 * 1024 * 1024;

var
  CommandLine: TCommandLine;
  Code: Integer;
  OptionValue: string;
  DevicePath: string;
  OutputPath: string;
  Rate: QWord;
  Channels: QWord;
  Kind: LongWord;
  Thousandths: QWord;
  BytesLeft: QWord;
  Wanted: QWord;
  Got: Int64;
  Buffer: array of Byte;
  Input: Int64;
  Output: Int64;
  Format: TAudioFormat;
  Header: array[0..WaveHeaderSize - 1] of Byte;
  Error: LongInt;
  Dropped: Int64;
  Recording: array of Byte;
  Recorded: QWord;
  KeptInMemory: Boolean;
begin
  DevicePath := DefaultAudioInput;
  Rate := 48000;
  Channels := 2;
  Kind := SampleSigned16;
  CommandLine := TCommandLine.Create([CommandOption('d', 'device', True, OptionDevice),
    CommandOption('r', 'rate', True, OptionRate),
    CommandOption('f', 'format', True, OptionFormat),
    CommandOption('c', 'channels', True, OptionChannels)], Usage);
  while CommandLine.NextOption(Code, OptionValue) do
    case Code of
      OptionDevice: DevicePath := OptionValue;
      OptionRate:
        if not ParseUnsignedDecimal(OptionValue, Rate) or (Rate < 8000) or (Rate > 192000) then
          FailWithUsageHint('the rate must be 8000 to 192000');
      OptionFormat:
        begin
          Kind := SampleKindOfName(OptionValue);
          if Kind = 0 then
            FailWithUsageHint(SysUtils.Format('unknown sample format ''%s''', [OptionValue]));
        end;
      OptionChannels:
        if not ParseUnsignedDecimal(OptionValue, Channels) or (Channels < 1) or (Channels > 8) then
          FailWithUsageHint('there can be 1 to 8 channels');
    end;
  if CommandLine.OperandCount <> 2 then
    FailWithUsageHint('a file and a length are needed');
  OutputPath := CommandLine.Operands[0];
  if not ParseThousandths(CommandLine.Operands[1], Thousandths) then
    FailWithUsageHint(SysUtils.Format('invalid length ''%s''', [CommandLine.Operands[1]]));

  Input := OpenAudioInput(DevicePath);
  if Input < 0 then
    FailWithError(1, LongInt(-Input), DevicePath);
  Format.Rate := LongWord(Rate);
  Format.Channels := LongWord(Channels);
  Format.Kind := Kind;
  Error := SetAudioFormat(Input, Format);
  if Error <> 0 then
    FailWithError(1, Error, 'setting the format');
  BytesLeft := (Rate * Thousandths div 1000) * Channels * BytesPerSample(Kind);

  Output := OpenFile(PChar(OutputPath), OpenWrite or OpenCreate or OpenTruncate);
  if Output < 0 then
    FailWithError(1, LongInt(-Output), OutputPath);
  MakeWaveHeader(@Header[0], LongWord(Rate), LongWord(Channels), Kind, LongWord(BytesLeft));
  WriteAll(Output, @Header[0], WaveHeaderSize);

  Recording := nil;
  Recorded := 0;
  KeptInMemory := BytesLeft <= MaximumBytesInMemory;
  if KeptInMemory then
    SetLength(Recording, BytesLeft);
  SetLength(Buffer, ChunkBytes);
  while BytesLeft > 0 do
  begin
    Wanted := BytesLeft;
    if Wanted > ChunkBytes then
      Wanted := ChunkBytes;
    Got := ReadAudio(Input, @Buffer[0], Wanted);
    if Got <= 0 then
      FailWithError(1, LongInt(-Got), 'reading ' + DevicePath);
    if KeptInMemory then
      Move(Buffer[0], Recording[Recorded], Got)
    else
    begin
      Error := WriteAll(Output, @Buffer[0], QWord(Got));
      if Error <> 0 then
        FailWithError(1, Error, OutputPath);
    end;
    Recorded := Recorded + QWord(Got);
    BytesLeft := BytesLeft - QWord(Got);
  end;
  if KeptInMemory and (Recorded > 0) then
  begin
    Error := WriteAll(Output, @Recording[0], Recorded);
    if Error <> 0 then
      FailWithError(1, Error, OutputPath);
  end;
  Dropped := DroppedAudioFrames(Input);
  if Dropped > 0 then
    Report(SysUtils.Format('%d frames were dropped (not read in time)', [Dropped]));
  CloseAudioOutput(Input);
  CloseFile(Output);
end.
