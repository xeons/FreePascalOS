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
  play - play WAV files

  play FILE...

  Plays each 16-bit PCM WAV file (mono or stereo, 44100 or 48000 Hz) on
  the audio device, one after the other.
}
program play;

{$mode objfpc}
{$pointermath on}

uses
  Runtime.Text,
  Sys.Format,
  Sys.Memory,
  Util.Messages,
  Util.Options,
  Audio.Device,
  Audio.Wave;

const
  Usage: PChar = 'Usage: play FILE...'#10 +
    'Play 16-bit PCM WAV files (mono or stereo, 44100 or 48000 Hz).'#10;
  ChunkBytes = 16384;

var
  Parser: TOptionParser;
  Index: Integer;
  Wave: TWaveFile;
  Status: TWaveStatus;
  Device: Int64;
  Format: TAudioFormat;
  Buffer: PByte;
  Count: QWord;
  Error: LongInt;
  Failed: Boolean;
begin
  ParseOperandsOnly(Parser, Usage);
  if Parser.OperandCount = 0 then
    FailWithUsageHint('no file to play', []);
  Device := OpenAudioOutput(nil);
  if Device < 0 then
    FailWithError(1, LongInt(-Device), '%s', [ArgumentText(DefaultAudioDevice)]);
  Buffer := PByte(AllocateMemory(ChunkBytes));
  Failed := False;
  for Index := 0 to Parser.OperandCount - 1 do
  begin
    Status := OpenWaveFile(Parser.Operands[Index], Wave);
    if Status <> WaveOk then
    begin
      Report('%s: %s', [ArgumentText(Parser.Operands[Index]), ArgumentText(WaveStatusText(Status))]);
      CloseWaveFile(Wave);
      Failed := True;
      Continue;
    end;
    Format.Rate := Wave.Rate;
    Format.Channels := Wave.Channels;
    Error := SetAudioFormat(Device, Format);
    if Error <> 0 then
    begin
      ReportError(Error, '%s: %u Hz, %u channels', [ArgumentText(Parser.Operands[Index]),
        ArgumentUnsigned(Wave.Rate), ArgumentUnsigned(Wave.Channels)]);
      CloseWaveFile(Wave);
      Failed := True;
      Continue;
    end;
    repeat
      Count := ReadWaveSamples(Wave, Buffer, ChunkBytes);
      if Count > 0 then
      begin
        Error := WriteAudio(Device, Buffer, Count);
        if Error <> 0 then
          FailWithError(1, Error, 'writing to %s', [ArgumentText(DefaultAudioDevice)]);
      end;
    until Count = 0;
    CloseWaveFile(Wave);
    DrainAudio(Device);
  end;
  CloseAudioOutput(Device);
  if Failed then
    Halt(1);
end.
