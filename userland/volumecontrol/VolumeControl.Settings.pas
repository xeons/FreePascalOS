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
  What the volume control remembers, in the user's settings
  (libconfiguration), group VolumeControl:

    PeakMeters = true | false   the meters shown (true unless set)

  The outputs' volumes, mutes and the default output are the system's
  (Sound/N/Volume, Sound/N/Muted, Sound/DefaultOutput), kept by the
  system settings service when changed here (KeepVolume,
  KeepDefaultOutput).
}
unit VolumeControl.Settings;

{$mode objfpc}
{$H+}

interface

const
  VolumeControlSettingsGroup = 'VolumeControl';
  { The system's settings of the sound, which the service writes. }
  SoundSettingsGroup = 'Sound';

function RememberedPeakMeters: Boolean;
procedure RememberPeakMeters(Shown: Boolean);
{ Asks the system settings service to keep output Number's volume and
  mute for the next boot (anyone may); True if it did. }
function KeepVolume(Number: LongInt; Volume: LongWord; Muted: Boolean): Boolean;
function KeepDefaultOutput(Number: LongInt): Boolean;

implementation

uses
  Abi.SystemCalls,
  Sys.SystemSettings,
  Configuration.Settings,
  Configuration.Locations;

const
  PeakMetersSetting = 'VolumeControl/PeakMeters';

function RememberedPeakMeters: Boolean;
var
  Store: TSettings;
begin
  Store := OpenSettings;
  try
    Result := Store.ReadBoolean(PeakMetersSetting, True);
  finally
    Store.Free;
  end;
end;

procedure RememberPeakMeters(Shown: Boolean);
var
  Store: TSettings;
begin
  Store := OpenSettings;
  try
    Store.WriteBoolean(PeakMetersSetting, Shown);
  finally
    Store.Free;
  end;
end;

function KeepVolume(Number: LongInt; Volume: LongWord; Muted: Boolean): Boolean;
var
  Request: TSystemSettingsRequest;
begin
  Request := NewSystemSettingsRequest(SystemRequestSetVolume);
  Request.Output := LongWord(Number);
  Request.Volume := Volume;
  if Muted then
    Request.Flags := SystemFlagMuted;
  Result := AskSystemSettings(Request) = ErrorNone;
end;

function KeepDefaultOutput(Number: LongInt): Boolean;
var
  Request: TSystemSettingsRequest;
begin
  Request := NewSystemSettingsRequest(SystemRequestSetDefaultOutput);
  Request.Output := LongWord(Number);
  Result := AskSystemSettings(Request) = ErrorNone;
end;

end.
