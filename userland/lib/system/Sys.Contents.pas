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
  The contents of libsystem.so.

  Compiling this unit compiles every unit of the library; the resulting
  object files are linked into the shared library. Programs use the
  individual units, never this one.
}
unit Sys.Contents;

{$mode objfpc}

interface

uses
  Runtime.Memory,
  Runtime.Text,
  Runtime.Time,
  Abi.SystemCalls,
  Sys.Kernel,
  Sys.Errors,
  Sys.Locks,
  Sys.Memory,
  Sys.Threads,
  Sys.Exceptions,
  Sys.Text,
  Sys.Streams,
  Sys.Files,
  Sys.FileCopies,
  Sys.Environment,
  Sys.ProgramFolders,
  Sys.Processes,
  Sys.Processor,
  Sys.ProcessList,
  Sys.SystemUsage,
  Sys.Time,
  Sys.TimeZones,
  Sys.LocalTime,
  Sys.Keyboard,
  Sys.Libraries,
  Sys.Information,
  Sys.FileWatches,
  Sys.Volumes,
  Sys.Console,
  Sys.PseudoTerminals,
  Sys.Display,
  Sys.Objects,
  Sys.KernelOptions,
  Sys.ServiceControl,
  Sys.SystemSettings,
  Sys.Notifications,
  Sys.EndRequests,
  Sys.InternetAddresses,
  Sys.RandomNumbers,
  Sys.DnsNames,
  Sys.DnsMessages,
  Sys.DnsCache,
  Sys.DnsQueries,
  Sys.HostsFile,
  Sys.HostNames,
  Sys.Sockets,
  Sys.NetworkInterfaces,
  Sys.AddressText,
  Sys.InterfaceText,
  Sys.HostLookup;

implementation

end.
