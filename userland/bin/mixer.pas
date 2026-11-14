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
  mixer - show or set the volume of the audio device

  mixer [VOLUME]

  Without an argument shows the volume (in percent) and the format; with
  one sets the volume.
}
program mixer;

{$mode objfpc}
{$pointermath on}

uses
  Runtime.Text,
  Sys.Format,
  Sys.Streams,
  Sys.Text,
  Util.Messages,
  Util.Options,
  Audio.Device;

const
  Usage: PChar = 'Usage: mixer [VOLUME]'#10 +
    'Show the volume (percent) and format of the audio device, or set the volume.'#10;

var
  Parser: TOptionParser;
  Device: Int64;
  Volume: QWord;
  Percent: LongWord;
  Format: TAudioFormat;
  Error: LongInt;
begin
  ParseOperandsOnly(Parser, Usage);
  if Parser.OperandCount > 1 then
    FailWithUsageHint('too many arguments', []);
  Device := OpenAudioOutput(nil);
  if Device < 0 then
    FailWithError(1, LongInt(-Device), '%s', [ArgumentText(DefaultAudioDevice)]);
  if Parser.OperandCount = 1 then
  begin
    if not ParseUnsigned(Parser.Operands[0], Volume) or (Volume > 100) then
      FailWithUsageHint('the volume must be 0 to 100', []);
    Error := SetAudioVolume(Device, LongWord(Volume));
    if Error <> 0 then
      FailWithError(1, Error, 'setting the volume', []);
  end
  else
  begin
    GetAudioVolume(Device, Percent);
    GetAudioFormat(Device, Format);
    WriteFormatted(StandardOutput, 'volume %u%%, %u Hz, %u channels'#10,
      [ArgumentUnsigned(Percent), ArgumentUnsigned(Format.Rate), ArgumentUnsigned(Format.Channels)]);
  end;
  CloseAudioOutput(Device);
end.
