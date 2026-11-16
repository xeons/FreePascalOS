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
  The volume's notification icon: the default sound output's volume, as
  a loudspeaker (crossed out when muted) with the volume in its tooltip
  ("Volume: 80%", "Volume: muted"). The shell shows it through the same
  interface as any program (Windowing.Notifications), and looks at the
  output again every second (Refresh, from the taskbar's clock), so a
  change made anywhere (mixer, the Control Panel) shows. Without a sound
  output it says so.
}
unit Desktop.VolumeIndicator;

{$mode objfpc}
{$H+}

interface

type
  TVolumeIndicator = class
  private
    FShownTooltip: string;
    FShownPicture: LongWord;
  public
    { Shows the icon as the output is now, if that changed. }
    procedure Refresh;
  end;

implementation

uses
  SysUtils,
  Windowing.Protocol,
  Windowing.Notifications,
  Audio.Outputs;

const
  VolumeIconNumber = 1;

procedure TVolumeIndicator.Refresh;
var
  State: TAudioOutputState;
  Tooltip: string;
  Picture: LongWord;
begin
  Picture := NotificationPictureVolume;
  if not DescribeAudioOutput(DefaultAudioOutput, State) then
    Tooltip := 'Volume: no sound output'
  else if State.Muted then
  begin
    Tooltip := 'Volume: muted';
    Picture := NotificationPictureVolumeMuted;
  end
  else
    Tooltip := Format('Volume: %d%%', [State.Volume]);
  if (Tooltip = FShownTooltip) and (Picture = FShownPicture) then
    Exit;
  FShownTooltip := Tooltip;
  FShownPicture := Picture;
  ShowNotificationIcon(VolumeIconNumber, Picture, PChar(Tooltip));
end;

end.
