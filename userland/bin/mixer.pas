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
  mixer - show or set the sound outputs' volumes, mutes and the default
  output

  mixer [-o N] [-m on|off] [-r] [VOLUME]
  mixer -l
  mixer -D N [-r]

  Without a change shows the output's volume (in percent): "volume 80%",
  with ", muted" after it when it is muted. The output is the default
  one unless -o names another (0 for /dev/audio, 1 for /dev/audio1...).
    VOLUME            sets the volume, 0 to 100
    -m, --mute on|off mutes the output or unmutes it
    -l, --list        every output: its number, what it is, volume, mute
                      and whether it is the default
    -D, --default N   makes output N the default: where programs play
                      that name no output
    -r, --remember    keeps the change for the next boot (in the
                      system's settings, Sound/N/Volume, Sound/N/Muted,
                      Sound/DefaultOutput), through the system settings
                      service, which applies it too
  The volume applies to everything played on the output.
}
program mixer;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Format,
  Sys.Streams,
  Sys.Text,
  Sys.SystemSettings,
  Util.Messages,
  Util.Options,
  Util.SystemRequests,
  Audio.Outputs;

const
  Usage: PChar = 'Usage: mixer [-o N] [-m on|off] [-r] [VOLUME]'#10 +
    '       mixer -l'#10 +
    '       mixer -D N [-r]'#10 +
    'Show or set the volume (percent) of a sound output, mute it, list the outputs'#10 +
    'or choose the default output; -r keeps the change for the next boot.'#10;

  OptionOutput = 1;
  OptionMute = 2;
  OptionList = 3;
  OptionDefault = 4;
  OptionRemember = 5;

procedure PrintText(const Text: string);
begin
  WriteText(StandardOutput, PChar(Text));
end;

function MutedSuffix(Muted: Boolean): string;
begin
  if Muted then
    Result := ', muted'
  else
    Result := '';
end;

procedure ListOutputs;
var
  Number: Integer;
  State: TAudioOutputState;
  Default: Integer;
  Mark: string;
begin
  Default := DefaultAudioOutput;
  Number := 0;
  while DescribeAudioOutput(Number, State) do
  begin
    if Number = Default then
      Mark := ', default'
    else
      Mark := '';
    PrintText(Format('%d %s %s: volume %d%%%s%s'#10, [Number, string(AudioOutputPath(Number)),
      string(AudioOutputKindName(State.Kind)), State.Volume, MutedSuffix(State.Muted), Mark]));
    Inc(Number);
  end;
end;

function NumberIn(const Text: string; Highest: Int64; const What: string): Integer;
var
  Value: Int64;
begin
  if not ParseInteger(PChar(Text), Value) or (Value < 0) or (Value > Highest) then
    FailWithUsageHint('%s must be a number from 0 to %d', [ArgumentText(PChar(What)), ArgumentNumber(Highest)]);
  Result := Integer(Value);
end;

procedure Check(Error: LongInt; const What: string);
begin
  if Error <> ErrorNone then
    FailWithError(1, Error, '%s', [ArgumentText(PChar(What))]);
end;

{ The volume and mute of Output through the service, which applies and
  remembers them. }
procedure RememberOutput(Output: Integer; Volume: LongWord; Muted: Boolean);
var
  Request: TSystemSettingsRequest;
begin
  Request := NewSystemSettingsRequest(SystemRequestSetVolume);
  Request.Output := LongWord(Output);
  Request.Volume := Volume;
  if Muted then
    Request.Flags := SystemFlagMuted;
  Check(SendSystemRequest(Request, False), 'remembering the volume');
end;

procedure RememberDefault(Output: Integer);
var
  Request: TSystemSettingsRequest;
begin
  Request := NewSystemSettingsRequest(SystemRequestSetDefaultOutput);
  Request.Output := LongWord(Output);
  Check(SendSystemRequest(Request, False), 'remembering the default output');
end;

var
  Parser: TOptionParser;
  Code: Integer;
  Value: PChar;
  Output: Integer;
  NewDefault: Integer;
  { 'on', 'off', or empty when -m was not given. }
  MuteText: string;
  List: Boolean;
  Remember: Boolean;
  State: TAudioOutputState;
  Changed: Boolean;
begin
  Output := -1;
  NewDefault := -1;
  MuteText := '';
  List := False;
  Remember := False;
  BeginOptions(Parser, [OptionDefinition('o', 'output', True, OptionOutput),
    OptionDefinition('m', 'mute', True, OptionMute),
    OptionDefinition('l', 'list', False, OptionList),
    OptionDefinition('D', 'default', True, OptionDefault),
    OptionDefinition('r', 'remember', False, OptionRemember)], Usage);
  while NextOption(Parser, Code, Value) do
    case Code of
      OptionOutput: Output := NumberIn(Value, MaximumAudioOutputs - 1, 'the output');
      OptionDefault: NewDefault := NumberIn(Value, MaximumAudioOutputs - 1, 'the output');
      OptionList: List := True;
      OptionRemember: Remember := True;
      OptionMute:
        begin
          MuteText := Value;
          if (MuteText <> 'on') and (MuteText <> 'off') then
            FailWithUsageHint('--mute takes on or off', []);
        end;
    end;
  if Parser.OperandCount > 1 then
    FailWithUsageHint('too many arguments', []);
  if List then
  begin
    ListOutputs;
    Halt(0);
  end;
  if NewDefault >= 0 then
  begin
    if Remember then
      RememberDefault(NewDefault)
    else
      Check(SetDefaultAudioOutput(NewDefault), 'choosing the default output');
    Halt(0);
  end;

  if Output < 0 then
    Output := DefaultAudioOutput;
  if not DescribeAudioOutput(Output, State) then
    Fail(1, 'there is no sound output %d', [ArgumentNumber(Output)]);
  Changed := False;
  if Parser.OperandCount = 1 then
  begin
    State.Volume := LongWord(NumberIn(Parser.Operands[0], 100, 'the volume'));
    Changed := True;
  end;
  if MuteText <> '' then
  begin
    State.Muted := MuteText = 'on';
    Changed := True;
  end;
  if Remember then
    RememberOutput(Output, State.Volume, State.Muted)
  else if Changed then
  begin
    Check(SetAudioOutputVolume(Output, State.Volume), 'setting the volume');
    Check(SetAudioOutputMuted(Output, State.Muted), 'muting');
  end;
  if Changed or Remember then
    Halt(0);
  PrintText(Format('volume %d%%%s'#10, [State.Volume, MutedSuffix(State.Muted)]));
end.
