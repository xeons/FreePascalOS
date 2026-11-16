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

  Plays each WAV file (8, 16, 24 or 32-bit PCM or float, 1 to 8
  channels, 8000 to 192000 Hz) on the audio device, one after the
  other; the kernel converts it to what the hardware plays.
}
program play;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  Util.CommandLine,
  Util.Messages,
  Audio.Device,
  Audio.Wave;

const
  Usage = 'Usage: play FILE...'#10 +
    'Play WAV files (8 to 32-bit PCM or float, 1 to 8 channels, 8000 to 192000 Hz).'#10;
  ChunkBytes = 16384;

var
  CommandLine: TCommandLine;
  Operand: string;
  Wave: TWaveFile;
  Status: TWaveStatus;
  Device: Int64;
  AudioFormat: TAudioFormat;
  Buffer: array of Byte;
  Count: QWord;
  Error: LongInt;
  Failed: Boolean;
begin
  CommandLine := TCommandLine.Create([], Usage);
  CommandLine.ReadOperandsOnly;
  if CommandLine.OperandCount = 0 then
    FailWithUsageHint('no file to play');
  Device := OpenAudioOutput;
  if Device < 0 then
    FailWithError(1, LongInt(-Device), DefaultAudioDevice);
  SetLength(Buffer, ChunkBytes);
  Failed := False;
  for Operand in CommandLine.Operands do
  begin
    Status := OpenWaveFile(Operand, Wave);
    if Status <> WaveOk then
    begin
      Report(Operand + ': ' + WaveStatusText(Status));
      CloseWaveFile(Wave);
      Failed := True;
      Continue;
    end;
    AudioFormat.Rate := Wave.Rate;
    AudioFormat.Channels := Wave.Channels;
    AudioFormat.Kind := Wave.Kind;
    Error := SetAudioFormat(Device, AudioFormat);
    if Error <> 0 then
    begin
      ReportError(Error, Format('%s: %u Hz, %u channels', [Operand, Wave.Rate, Wave.Channels]));
      CloseWaveFile(Wave);
      Failed := True;
      Continue;
    end;
    repeat
      Count := ReadWaveSamples(Wave, @Buffer[0], ChunkBytes);
      if Count > 0 then
      begin
        Error := WriteAudio(Device, @Buffer[0], Count);
        if Error <> 0 then
          FailWithError(1, Error, 'writing to ' + DefaultAudioDevice);
      end;
    until Count = 0;
    CloseWaveFile(Wave);
    DrainAudio(Device);
  end;
  CloseAudioOutput(Device);
  if Failed then
    Halt(1);
end.
