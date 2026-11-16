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
  Firmware files for drivers: patches and microcode a device needs from
  the operating system, kept in /lib/firmware on the system volume
  (laid out like linux-firmware: rtl_nic/rtl8125b-2.fw and so on).

  Drivers start before any volume is mounted, so a driver asks for a
  file (RequestFirmware) and is called back with it once the volumes
  are (Io.Startup calls DeliverRequestedFirmware after mounting them);
  a request made after that is answered at once. The callback runs at
  passive level on the startup thread, and gets the file's contents in
  kernel memory, which become the driver's (FreeKernelMemory when done),
  or nil if there is no system volume or no such file - the driver then
  carries on without it.
}
unit Io.Firmware;

{$mode objfpc}

interface

type
  { Data is nil if the file could not be read. }
  TFirmwareArrived = procedure(Context: Pointer; Data: PByte; Size: QWord);

const
  { Larger files are refused (firmware files are a few KiB to a few
    hundred). }
  MaximumFirmwareBytes = 4 * 1024 * 1024;

{ Asks for /lib/firmware/Name (Name relative to it, e.g.
  "rtl_nic/rtl8125b-2.fw"). Passive level. Name must stay valid until
  the callback. }
procedure RequestFirmware(Name: PChar; Arrived: TFirmwareArrived; Context: Pointer);

{ Reads the requests made so far and calls back each driver; from now
  on requests are answered at once. Once the volumes are mounted. }
procedure DeliverRequestedFirmware;

implementation

uses
  Runtime.Text,
  Memory.KernelHeap,
  FileSystem.Types,
  FileSystem.Files,
  Processes.Process,
  Processes.Paths,
  Debug.Output;

const
  FirmwareDirectory = '/lib/firmware/';
  MaximumRequests = 32;
  PathCapacity = 256;

type
  TFirmwareRequest = record
    Name: PChar;
    Arrived: TFirmwareArrived;
    Context: Pointer;
  end;

var
  Requests: array[0..MaximumRequests - 1] of TFirmwareRequest;
  RequestCount: Integer;
  VolumesAreMounted: Boolean;

procedure Report(Name: PChar; Text: PChar);
begin
  DebugBeginMessage;
  DebugWriteTag('firmware');
  DebugWrite(FirmwareDirectory);
  DebugWrite(Name);
  DebugWrite(': ');
  DebugWriteLine(Text);
  DebugEndMessage;
end;

{ The file's contents in kernel memory, or nil. }
function ReadFirmwareFile(Name: PChar; out Size: QWord): PByte;
var
  RelativePath: array[0..PathCapacity - 1] of Char;
  KernelPath: array[0..ProcessPathCapacity - 1] of Char;
  OpenedFile: POpenFile;
  Information: TNodeInformation;
  BytesRead: QWord;
begin
  Result := nil;
  Size := 0;
  if not SelectSystemVolume then
  begin
    Report(Name, 'not loaded, there is no system volume');
    Exit;
  end;
  CopyText(@RelativePath[0], FirmwareDirectory, PathCapacity);
  CopyText(@RelativePath[TextLength(@RelativePath[0])], Name, PathCapacity - TextLength(@RelativePath[0]));
  SystemVolumePath(@RelativePath[0], @KernelPath[0], ProcessPathCapacity);
  if OpenPath(@KernelPath[0], OpenedFile) <> StatusSuccess then
  begin
    Report(Name, 'not found, going on without it');
    Exit;
  end;
  if (GetFileInformation(OpenedFile, Information) <> StatusSuccess) or (Information.SizeInBytes = 0) or
     (Information.SizeInBytes > MaximumFirmwareBytes) then
  begin
    Report(Name, 'empty or too large, not loaded');
    CloseFile(OpenedFile);
    Exit;
  end;
  Result := PByte(AllocateKernelMemory(Information.SizeInBytes));
  if Result <> nil then
    if (ReadFromFile(OpenedFile, Result, Information.SizeInBytes, BytesRead) <> StatusSuccess) or
       (BytesRead <> Information.SizeInBytes) then
    begin
      FreeKernelMemory(Result);
      Result := nil;
    end;
  CloseFile(OpenedFile);
  if Result = nil then
  begin
    Report(Name, 'could not be read');
    Exit;
  end;
  Size := Information.SizeInBytes;
  DebugBeginMessage;
  DebugWriteTag('firmware');
  DebugWrite('loaded ');
  DebugWrite(FirmwareDirectory);
  DebugWrite(Name);
  DebugWrite(', ');
  DebugWriteDecimal(Size);
  DebugWriteLine(' bytes');
  DebugEndMessage;
end;

procedure Deliver(const Request: TFirmwareRequest);
var
  Data: PByte;
  Size: QWord;
begin
  Data := ReadFirmwareFile(Request.Name, Size);
  Request.Arrived(Request.Context, Data, Size);
end;

procedure RequestFirmware(Name: PChar; Arrived: TFirmwareArrived; Context: Pointer);
var
  Request: TFirmwareRequest;
begin
  Request.Name := Name;
  Request.Arrived := Arrived;
  Request.Context := Context;
  if VolumesAreMounted then
  begin
    Deliver(Request);
    Exit;
  end;
  if RequestCount = MaximumRequests then
  begin
    Report(Name, 'too many firmware requests, not loaded');
    Arrived(Context, nil, 0);
    Exit;
  end;
  Requests[RequestCount] := Request;
  Inc(RequestCount);
end;

procedure DeliverRequestedFirmware;
var
  Index: Integer;
begin
  VolumesAreMounted := True;
  for Index := 0 to RequestCount - 1 do
    Deliver(Requests[Index]);
  RequestCount := 0;
end;

end.
