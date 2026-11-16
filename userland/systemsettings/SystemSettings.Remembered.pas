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
  The machine's settings the service keeps for the next boot, in the
  system's settings (libconfiguration, /etc/settings):

    Time/Zone             the time zone's name (Europe/Berlin)
    Sound/N/Volume        output N's volume, 0-100
    Sound/N/Muted         whether output N is muted
    Sound/DefaultOutput   the default output's number

  At start the service gives the kernel what is kept (the kernel starts
  in UTC, every output at its driver's volume, the first output the
  default), and every change it makes is kept here as it is made.
}
unit SystemSettings.Remembered;

{$mode objfpc}
{$H+}

interface

{ Gives the kernel the kept zone, volumes, mutes and default output. }
procedure ApplyRememberedSettings;

{ Each returns the settings' write error (ErrorNone if kept). }
function RememberTimeZone(const Name: string): LongInt;
function RememberOutput(Output: Integer; Volume: LongWord; Muted: Boolean): LongInt;
function RememberDefaultOutput(Output: Integer): LongInt;

implementation

uses
  SysUtils,
  Abi.SystemCalls,
  Configuration.Settings,
  Configuration.Locations,
  Sys.LocalTime,
  Sys.TimeZones,
  Audio.Outputs,
  SystemSettings.Report;

const
  TimeZoneSetting = 'Time/Zone';
  DefaultOutputSetting = 'Sound/DefaultOutput';

function VolumeSetting(Output: Integer): string;
begin
  Result := Format('Sound/%d/Volume', [Output]);
end;

function MutedSetting(Output: Integer): string;
begin
  Result := Format('Sound/%d/Muted', [Output]);
end;

procedure ApplyTimeZone(Store: TSettings);
var
  Name: string;
begin
  Name := Store.ReadString(TimeZoneSetting, '');
  if Name = '' then
    Exit;
  if SetSystemTimeZone(PChar(Name)) = ErrorNone then
    Say('time zone ' + Name)
  else
    Say('the kept time zone ' + Name + ' is not known: staying in UTC');
end;

procedure ApplyOutputs(Store: TSettings);
var
  Output: Integer;
  State: TAudioOutputState;
  Volume: Int64;
  Muted: Boolean;
  DefaultOutput: Int64;
begin
  Output := 0;
  while DescribeAudioOutput(Output, State) do
  begin
    { A volume not kept (or out of range) leaves the driver's. }
    Volume := Store.ReadInteger(VolumeSetting(Output), -1);
    Muted := Store.ReadBoolean(MutedSetting(Output), False);
    if (Volume >= 0) and (Volume <= 100) then
    begin
      SetAudioOutputVolume(Output, LongWord(Volume));
      SetAudioOutputMuted(Output, Muted);
      Say(Format('sound output %d volume %d%s', [Output, Volume, BoolToStr(Muted, ', muted', '')]));
    end;
    Inc(Output);
  end;
  DefaultOutput := Store.ReadInteger(DefaultOutputSetting, -1);
  if (DefaultOutput >= 0) and (DefaultOutput < MaximumAudioOutputs) and
     (SetDefaultAudioOutput(Integer(DefaultOutput)) = ErrorNone) then
    Say(Format('default sound output %d', [DefaultOutput]));
end;

procedure ApplyRememberedSettings;
var
  Store: TSettings;
begin
  Store := OpenSystemSettings;
  ApplyTimeZone(Store);
  ApplyOutputs(Store);
  Store.Free;
end;

function Keep(Store: TSettings): LongInt;
begin
  Result := Store.Flush;
  Store.Free;
end;

function RememberTimeZone(const Name: string): LongInt;
var
  Store: TSettings;
begin
  Store := OpenSystemSettings;
  Store.WriteString(TimeZoneSetting, Name, ScopeSystem);
  Result := Keep(Store);
end;

function RememberOutput(Output: Integer; Volume: LongWord; Muted: Boolean): LongInt;
var
  Store: TSettings;
begin
  Store := OpenSystemSettings;
  Store.WriteInteger(VolumeSetting(Output), Volume, ScopeSystem);
  Store.WriteBoolean(MutedSetting(Output), Muted, ScopeSystem);
  Result := Keep(Store);
end;

function RememberDefaultOutput(Output: Integer): LongInt;
var
  Store: TSettings;
begin
  Store := OpenSystemSettings;
  Store.WriteInteger(DefaultOutputSetting, Output, ScopeSystem);
  Result := Keep(Store);
end;

end.
