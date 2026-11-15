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

  Without an argument shows the output's volume (in percent); with one
  sets it. The volume applies to everything played on the output.
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
    'Show the volume (percent) of the audio output, or set it.'#10;

var
  Parser: TOptionParser;
  Device: Int64;
  Volume: QWord;
  Percent: LongWord;
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
    Error := SetMasterVolume(Device, LongWord(Volume));
    if Error <> 0 then
      FailWithError(1, Error, 'setting the volume', []);
  end
  else
  begin
    GetMasterVolume(Device, Percent);
    WriteFormatted(StandardOutput, 'volume %u%%'#10, [ArgumentUnsigned(Percent)]);
  end;
  CloseAudioOutput(Device);
end.
