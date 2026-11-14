{
  Information about the system: name, version, memory and volumes.
}
unit Sys.Information;

{$mode objfpc}

interface

uses
  Abi.SystemCalls;

type
  TSystemInformation = TAbiSystemInformation;
  TVolumeInformation = TAbiVolumeInformation;

function GetSystemInformation(out Information: TSystemInformation): LongInt;
{ Returns False when Index is past the last volume. }
function GetVolume(Index: Integer; out Information: TVolumeInformation): Boolean;

implementation

uses
  Sys.Kernel,
  Sys.Errors;

function GetSystemInformation(out Information: TSystemInformation): LongInt;
begin
  Result := ErrorCodeOf(KernelGetSystemInformation(Information));
end;

function GetVolume(Index: Integer; out Information: TVolumeInformation): Boolean;
begin
  Result := KernelListVolumes(QWord(Index), Information) > 0;
end;

end.
