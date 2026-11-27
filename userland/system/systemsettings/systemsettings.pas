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
  systemsettings - the system settings service

  Runs as root (the service "systemsettings", in both boot modes). At
  start it gives the kernel the machine's remembered settings (the time
  zone, the sound outputs' volumes and mutes, the default output); then
  it serves the port "systemsettings", making the changes only root may
  make for the users who may ask for them (Sys.SystemSettings has the
  requests and who may make each). Units in userland/system/systemsettings.

  It holds nothing that needs tidying up: every change is written as it
  is made, so a service stop may end it at once.
}
program systemsettings;

{$mode objfpc}
{$H+}

uses
  Sys.ServiceControl,
  SystemSettings.Report,
  SystemSettings.Remembered,
  SystemSettings.Server;

begin
  ApplyRememberedSettings;
  if not OpenSettingsPort then
  begin
    Say('cannot create the port (is another system settings service running?)');
    Halt(1);
  end;
  Say('ready');
  NotifyServiceReady;
  ServeRequests;
end.
