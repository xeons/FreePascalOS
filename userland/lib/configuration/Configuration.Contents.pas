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
  The contents of libconfiguration.so: settings kept per user and for
  the whole system.

  Compiling this unit compiles every unit of the library; programs use
  the individual units (usually Configuration.Locations to open the
  settings, Configuration.Settings to read and write them). Everything
  but the files (Configuration.FileStorage), their places
  (Configuration.Locations) and the network's status as the kernel and
  the network service tell it (Configuration.NetworkStatus) needs only
  the runtime library and libsystem's address parsing, so it builds
  and is tested on the host as well (tools/SettingsTest).
}
unit Configuration.Contents;

{$mode objfpc}

interface

uses
  Configuration.Names,
  Configuration.Values,
  Configuration.Documents,
  Configuration.Storage,
  Configuration.Scopes,
  Configuration.Settings,
  Configuration.FileStorage,
  Configuration.Locations,
  Configuration.NetworkSettings,
  Configuration.NetworkState,
  Configuration.NetworkStatus;

implementation

end.
