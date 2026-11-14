{
  The null device: reading gives end of file at once, and anything
  written is thrown away. User programs open it as /dev/null.
}
unit Io.NullDevice;

{$mode objfpc}

interface

const
  NullDeviceUserPath = '/dev/null';

procedure InitializeNullDevice;

{ The object that null device handles refer to. }
function NullDeviceObject: Pointer;

implementation

uses
  Kernel.Panic,
  Objects.Manager;

type
  TNullDevice = record
    Unused: Byte;
  end;

var
  NullDeviceObjectType: TObjectType;
  TheNullDevice: Pointer;

procedure InitializeNullDevice;
begin
  RegisterObjectType(NullDeviceObjectType, 'NullDevice', SizeOf(TNullDevice), nil);
  TheNullDevice := CreateObject(NullDeviceObjectType, 'Null');
  if TheNullDevice = nil then
    KernelPanic('could not create the null device');
end;

function NullDeviceObject: Pointer;
begin
  Result := TheNullDevice;
end;

end.
